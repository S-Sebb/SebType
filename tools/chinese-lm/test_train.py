"""train.py's labels: the typed letters stay out of the loss wherever the window starts (#502).

python tools/chinese-lm/test_train.py
"""

import torch
from train import between, labels

T, S, E = 1, 2, 3
L = 10  # a letter
H = 20  # a Han character


def check(x, expected):
    _, y = labels(torch.tensor([x]), T, S)
    got = [int(v != -100) for v in y[0]]
    assert got == expected, f"{x}: {got} != {expected}"


# A window from the text before an example: the letters, <T> and <S> aren't targets.
check([H, T, L, L, S, H, E, H, T, L, S, H], [0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1])
# A window that starts among the letters: they and the next example's letters aren't targets either.
check([L, L, S, H, E, H, T, L, S, H], [0, 0, 1, 1, 1, 0, 0, 0, 1])
# The spans, also from a window that starts inside one.
assert between(torch.tensor([[H, E, H, S, H, H, E]]), S, E).int().tolist() == [
    [1, 0, 0, 1, 1, 1, 0]
]
print("PASS labels")
