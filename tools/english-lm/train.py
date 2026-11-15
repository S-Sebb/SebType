"""Trains SebType's English model from scratch on pack.py's tokens, on one GPU.

  train.py RUN_DIR CONFIG.json

CONFIG (config.json) sets the model's shape and the schedule. Writes RUN_DIR/ckpt/NAME/: the model in
Hugging Face's Llama format with the tokenizer (export.sh converts it to GGUF), and train.log. Each eval
prints PROGRESS step/steps and the dev loss: over all tokens, and over the first piece of the word after <S>
(the correction examples).
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


def windows(data, n, length, gen):
    i = torch.randint(0, len(data) - length - 1, (n,), generator=gen).numpy()
    x = np.stack([data[j : j + length + 1] for j in i]).astype(np.int64)
    return torch.from_numpy(x).pin_memory().cuda(non_blocking=True)


def labels(x, t, s):
    """Next-token labels for X, with the correction examples' own tokens (<T>, the letters, <S>) left out."""
    c = (x == t).cumsum(1) - (x == s).cumsum(1)
    inside = (c > 0) | (x == s)
    y = x[:, 1:].clone()
    y[inside[:, 1:]] = -100
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
            return cfg["lr"] * step / cfg["warmup"]
        p = (step - cfg["warmup"]) / max(1, steps - cfg["warmup"])
        return cfg["lr"] * (0.1 + 0.9 * 0.5 * (1 + math.cos(math.pi * p)))

    @torch.no_grad()
    def evaluate():
        model.eval()
        g = torch.Generator().manual_seed(0)
        total = n = hint = nh = 0.0
        for _ in range(20):
            x = windows(dev, micro, length, g)
            inp, y = labels(x, t, s)
            loss = losses(inp, y)
            mask = y != -100
            total += loss[mask].sum().item()
            n += mask.sum().item()
            after = inp == s
            hint += loss[after].sum().item()
            nh += after.sum().item()
        model.train()
        return total / n, hint / max(1, nh)

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
        for g in opt.param_groups:
            g["lr"] = lr_at(step)
        for _ in range(accum):
            inp, y = labels(windows(train, micro, length, gen), t, s)
            loss = losses(inp, y)
            (loss.sum() / (y != -100).sum() / accum).backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        opt.zero_grad(set_to_none=True)

    model.save_pretrained(out, safe_serialization=True)
    shutil.copy(run / "data/tokenizer.model", out / "tokenizer.model")
    (out / "config.train.json").write_text(json.dumps(cfg, indent=1))


if __name__ == "__main__":
    main(*sys.argv[1:3])
