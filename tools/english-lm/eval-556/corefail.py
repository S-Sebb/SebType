"""#556 eval: corefail.py LOG — #539's rows a space commits wrongly, as "typed (model) → committed", and the
tests that failed."""

import re
import sys

text = open(sys.argv[1]).read()
for block in text.split("Failure")[1:]:
    block = block.split("\n[ ")[0].split("\n/")[0]
    if "takeCommit" not in block:
        continue
    lines = [l.strip() for l in block.splitlines() if l.strip()]
    actual = next(
        (l[len("Which is: ") :] for l in lines if l.startswith("Which is:")), None
    )
    if actual is None:  # EXPECT_NE: "actual: X vs Y"
        actual = next(
            (
                re.sub(r" vs .*", "", l.split("actual: ", 1)[1])
                for l in lines
                if "actual: " in l
            ),
            "?",
        )
    msg = lines[-1]
    print(f"{msg} -> {actual}")
print("tests:", *re.findall(r"\[  FAILED  \] (\S+)\n", text) or ["all passed"])
