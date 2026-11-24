"""Trains SebType's Chinese model from scratch on pack.py's tokens, on one GPU.

  train.py RUN_DIR CONFIG.json

CONFIG (config.json) sets the model's shape and the schedule. Writes RUN_DIR/ckpt/NAME/: the model in
Hugging Face's Llama format with the tokenizer (export.sh converts it to GGUF), and train.log; every
save_every steps a checkpoint in ckpt/NAME/step-N/ too, for select.sh to choose from on the dev sets. Each eval
prints PROGRESS step/steps and the dev losses: over the text, over the spans after <S> (the pinyin examples,
with their <E>), and the word boundaries' (the <B> logit's binary cross entropy).

The model is a plain Llama, so llama.cpp runs it as it is. Its <B> row is never an input: the softmax over the
next token leaves it out, and its logit alone, through a sigmoid, is the chance that a word ends at the token
just read.

A window starts at a segment's <s>, as the loader's context does (#557), and <s> is never a target.
"""

import json
import math
import shutil
import sys
import time
from pathlib import Path

import numpy as np
import torch
from transformers import LlamaConfig, LlamaForCausalLM


def windows(data, wb, starts, n, length, gen):
    i = starts[torch.randint(0, len(starts), (n,), generator=gen).numpy()]
    x = np.stack([data[j : j + length + 1] for j in i]).astype(np.int64)
    b = np.stack([wb[j : j + length] for j in i]).astype(np.int64)
    return (
        torch.from_numpy(x).pin_memory().cuda(non_blocking=True),
        torch.from_numpy(b).pin_memory().cuda(non_blocking=True),
    )


def segment_starts(data, bos, length):
    """The offsets of DATA's <s> tokens that a whole window fits after, read in chunks."""
    step = 1 << 28
    out = np.concatenate(
        [
            np.flatnonzero(data[k : k + step] == bos) + k
            for k in range(0, len(data), step)
        ]
    )
    return out[out < len(data) - length - 1]


def between(x, start, stop):
    """Where X is after a START and before its STOP (or at it), also when the window began between them."""
    c = (x == start).cumsum(1) - (x == stop).cumsum(1)
    # A window that began between them reaches -1 at the STOP: counted from there, it is 1 between them too.
    return c - c.min(1, keepdim=True).values > 0


def labels(x, t, s, bos):
    """Next-token labels for X, with the examples' typed part (<T>, the letters, <S>) and <s> left out."""
    inside = between(x, t, s) | (x == s)
    y = x[:, 1:].clone()
    y[inside[:, 1:] | (y == bos)] = -100
    return x[:, :-1], y


def main(run, config_path):
    cfg = json.loads(Path(config_path).read_text())
    run = Path(run)
    out = run / "ckpt" / cfg["name"]
    out.mkdir(parents=True, exist_ok=True)
    torch.manual_seed(cfg["seed"])
    gen = torch.Generator().manual_seed(cfg["seed"])

    import sentencepiece as spm

    sp = spm.SentencePieceProcessor(model_file=str(run / "data/tokenizer.model"))
    t, s, e, B = (sp.piece_to_id(p) for p in ("<T>", "<S>", "<E>", "<B>"))
    model_cfg = LlamaConfig(
        vocab_size=sp.get_piece_size(),
        bos_token_id=sp.bos_id(),
        eos_token_id=sp.eos_id(),
        pad_token_id=None,
        tie_word_embeddings=True,
        max_position_embeddings=cfg["context"],
        **cfg["model"],
    )
    model = LlamaForCausalLM(model_cfg).cuda()
    print(
        f"parameters: {sum(p.numel() for p in model.parameters()) / 1e6:.1f}M",
        flush=True,
    )

    @torch.compile
    def losses(inp, y, b):
        """Per-token cross entropy and word-boundary loss (0 where B is 2), in one compiled graph with the
        model so the logits aren't kept."""
        with torch.autocast("cuda", dtype=torch.bfloat16):
            logits = model(inp).logits.float()
        boundary = logits[..., B]
        logits = logits.index_fill(
            -1, torch.tensor([B], device=logits.device), float("-inf")
        )
        ce = torch.nn.functional.cross_entropy(
            logits.transpose(1, 2), y, ignore_index=-100, reduction="none"
        )
        bce = torch.nn.functional.binary_cross_entropy_with_logits(
            boundary, b.clamp(max=1).float(), reduction="none"
        ) * (b < 2)
        return ce, bce

    # Each training set is one pass of pack.py with its own seed (its own correction examples).
    data = run / "data"
    train = np.concatenate(
        [np.memmap(data / f"{f}.bin", dtype=np.uint16, mode="r") for f in cfg["train"]]
    )
    train_wb = np.concatenate(
        [np.memmap(data / f"{f}.wb", dtype=np.uint8, mode="r") for f in cfg["train"]]
    )
    dev = np.memmap(data / "dev.0.bin", dtype=np.uint16, mode="r")
    dev_wb = np.memmap(data / "dev.0.wb", dtype=np.uint8, mode="r")
    length, micro, accum = cfg["context"], cfg["micro_batch"], cfg["accum"]
    train_starts = segment_starts(train, sp.bos_id(), length)
    dev_starts = segment_starts(dev, sp.bos_id(), length)
    steps = int(cfg["tokens"] / (length * micro * accum))
    print(f"train tokens available {len(train) / 1e9:.2f}B, steps {steps}", flush=True)

    decay = [p for n, p in model.named_parameters() if p.dim() >= 2]
    rest = [p for n, p in model.named_parameters() if p.dim() < 2]
    opt = torch.optim.AdamW(
        [
            {"params": decay, "weight_decay": cfg["weight_decay"]},
            {"params": rest, "weight_decay": 0.0},
        ],
        lr=cfg["lr"],
        betas=(0.9, 0.95),
        fused=True,
    )

    def lr_at(step):
        if step < cfg["warmup"]:
            return cfg["lr"] * (step + 1) / cfg["warmup"]
        p = (step - cfg["warmup"]) / max(1, steps - cfg["warmup"])
        return cfg["lr"] * (0.1 + 0.9 * 0.5 * (1 + math.cos(math.pi * p)))

    @torch.no_grad()
    def evaluate():
        model.eval()
        g = torch.Generator().manual_seed(0)
        total = n = span = ns = bnd = nb = 0.0
        for _ in range(20):
            x, b = windows(dev, dev_wb, dev_starts, micro, length, g)
            inp, y = labels(x, t, s, sp.bos_id())
            loss, bl = losses(inp, y, b)
            # The spans: from <S> up to the <E> after it.
            in_span = between(inp, s, e) & (y != -100)
            text = (y != -100) & ~in_span
            total += loss[text].sum().item()
            n += text.sum().item()
            span += loss[in_span].sum().item()
            ns += in_span.sum().item()
            bnd += bl.sum().item()
            nb += (b < 2).sum().item()
        model.train()
        return total / n, span / max(1, ns), bnd / max(1, nb)

    def save(d):
        d.mkdir(parents=True, exist_ok=True)
        model.save_pretrained(d, safe_serialization=True)
        shutil.copy(run / "data/tokenizer.model", d / "tokenizer.model")
        (d / "config.train.json").write_text(json.dumps(cfg, indent=1))

    log = open(out / "train.log", "a")
    start = time.time()
    for step in range(steps + 1):
        if step % cfg["eval_every"] == 0 or step == steps:
            dev_loss, span_loss, boundary_loss = evaluate()
            msg = (
                f"PROGRESS {step}/{steps} dev_loss {dev_loss:.4f} span_loss {span_loss:.4f} "
                f"boundary_loss {boundary_loss:.4f} "
                f"lr {lr_at(step):.2e} elapsed {time.time() - start:.0f}s"
            )
            print(msg, flush=True)
            log.write(msg + "\n")
            log.flush()
        if step == steps:
            break
        if step and step % cfg["save_every"] == 0:
            save(out / f"step-{step}")
        for g in opt.param_groups:
            g["lr"] = lr_at(step)
        for _ in range(accum):
            x, b = windows(train, train_wb, train_starts, micro, length, gen)
            inp, y = labels(x, t, s, sp.bos_id())
            loss, bl = losses(inp, y, b)
            (
                (loss.sum() / (y != -100).sum() + bl.sum() / (b < 2).sum().clamp(min=1))
                / accum
            ).backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        opt.zero_grad(set_to_none=True)

    save(out)


if __name__ == "__main__":
    main(*sys.argv[1:3])
