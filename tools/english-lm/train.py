"""Trains SebType's English model from scratch on pack.py's tokens, on one GPU.

  train.py RUN_DIR CONFIG.json

CONFIG (config.json) sets the model's shape and the schedule. Writes RUN_DIR/ckpt/NAME/: the model in
Hugging Face's Llama format with the tokenizer (export.sh converts it to GGUF), and train.log; every
save_every steps a checkpoint in ckpt/NAME/step-N/ too, for select.sh to choose from on the dev sets. Each eval
prints PROGRESS step/steps and the dev loss: over all tokens, and over the first piece of the word after <S>
(the correction examples).

A training window starts at a segment's <s>, as the phone's context does: the window's first segment is what
the phone gives the model, at most 300 characters of a line. The window holds the segments after it too,
which see the ones before them across their <s> (ordinary packing); their own context is longer than the
phone's. A window starts at the <s> at or before a uniformly drawn token, so each source is trained in
proportion to its tokens, as MIX says, however short its segments.
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


def window_starts(starts, n, gen):
    """N window offsets: the <s> at or before a uniform token, so a segment is drawn by its length."""
    pos = torch.randint(
        int(starts[0]), int(starts[-1]) + 1, (n,), generator=gen
    ).numpy()
    return starts[np.searchsorted(starts, pos, side="right") - 1]


def windows(data, starts, n, length, gen):
    i = window_starts(starts, n, gen)
    x = np.stack([data[j : j + length + 1] for j in i]).astype(np.int64)
    return torch.from_numpy(x).pin_memory().cuda(non_blocking=True)


def segment_starts(data, bos, length):
    """The offsets of DATA's <s> tokens that a whole window fits after, read in chunks."""
    step = 1 << 28
    out = [
        np.flatnonzero(data[k : k + step] == bos) + k for k in range(0, len(data), step)
    ]
    out = np.concatenate(out)
    return out[out < len(data) - length - 1]


def labels(x, t, s, bos):
    """Next-token labels for X, with the correction examples' own tokens (<T>, the letters, <S>) and <s> left
    out. A window that starts inside an example (dev loss's random windows can) has its letters up to the
    first <S> left out too, and no example after it is taken for text."""
    tc, sc = (x == t).cumsum(1), (x == s).cumsum(1)
    c = tc - sc
    # An unmatched <S> takes c below 0; measured from the lowest c so far, an example is still depth 1.
    depth = c - torch.minimum(c.cummin(1).values, torch.zeros_like(c))
    control = (x == t) | (x == s)
    first = control.int().argmax(1)
    starts_inside = control.any(1) & (x.gather(1, first[:, None])[:, 0] == s)
    inside = (depth > 0) | (x == s) | (starts_inside[:, None] & (tc == 0) & (sc == 0))
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
    t, s = sp.piece_to_id("<T>"), sp.piece_to_id("<S>")
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
    def losses(inp, y):
        """Per-token cross entropy, in one compiled graph with the model so the logits aren't kept."""
        with torch.autocast("cuda", dtype=torch.bfloat16):
            logits = model(inp).logits
        return torch.nn.functional.cross_entropy(
            logits.float().transpose(1, 2), y, ignore_index=-100, reduction="none"
        )

    # Each training set is one pass of pack.py with its own seed (its own correction examples).
    train = np.concatenate(
        [np.memmap(run / "data" / f, dtype=np.uint16, mode="r") for f in cfg["train"]]
    )
    dev = np.memmap(run / "data/dev.0.bin", dtype=np.uint16, mode="r")
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
        total = n = hint = nh = 0.0
        for _ in range(20):
            x = windows(dev, dev_starts, micro, length, g)
            inp, y = labels(x, t, s, sp.bos_id())
            loss = losses(inp, y)
            mask = y != -100
            total += loss[mask].sum().item()
            n += mask.sum().item()
            after = inp == s
            hint += loss[after].sum().item()
            nh += after.sum().item()
        model.train()
        return total / n, hint / max(1, nh)

    def save(d):
        d.mkdir(parents=True, exist_ok=True)
        model.save_pretrained(d, safe_serialization=True)
        shutil.copy(run / "data/tokenizer.model", d / "tokenizer.model")
        (d / "config.train.json").write_text(json.dumps(cfg, indent=1))

    log = open(out / "train.log", "a")
    start = time.time()
    for step in range(steps + 1):
        if step % cfg["eval_every"] == 0 or step == steps:
            dev_loss, hint_loss = evaluate()
            msg = (
                f"PROGRESS {step}/{steps} dev_loss {dev_loss:.4f} correction_loss {hint_loss:.4f} "
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
            inp, y = labels(
                windows(train, train_starts, micro, length, gen), t, s, sp.bos_id()
            )
            loss = losses(inp, y)
            (loss.sum() / (y != -100).sum() / accum).backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        opt.zero_grad(set_to_none=True)

    save(out)


if __name__ == "__main__":
    main(*sys.argv[1:3])
