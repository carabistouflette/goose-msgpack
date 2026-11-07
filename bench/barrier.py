#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Negative control for the benchmark's anti-elimination barrier.

The barrier is what stops the compiler from deleting the work being measured,
and it is also what makes "faster" mean "faster at the same answer". A barrier
that folds only the token kind and the wire span is not enough: a reader that
returns the right token type at the right offset with the **wrong value**
consumes the same bytes and reports the same kind, so its checksum would agree
with a correct reader's and a broken decoder would benchmark as a fast one.

`checksum-mutant` is the same walk with every decoded value zeroed before it is
folded. If the checksum does not depend on the values, the two modes agree and
this control fails.

    python3 bench/barrier.py --binary .build/bench/msgpack-bench

The rows that refuse before decoding a single token are allowed to be unchanged:
`decode-corrupt-start` puts the reserved marker `0xc1` at offset 0, so no value
is ever produced and there is nothing for the mutant to zero. Every other decode
row must differ, and `decode-fresh` / `decode-reused` must differ unconditionally
because they always walk the whole document.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

U64 = (1 << 64) - 1

# Rows that must change: they always decode the whole document, so they always
# produce values for the mutant to zero.
MUST_CHANGE = {"decode-fresh", "decode-reused"}

# A refusal row may be unchanged when the decoder refuses before producing a
# single token, because then there is no value to zero. Which refusal rows those
# are depends on the decoder: a token reader walks the `truncated-start` document
# far enough to decode a value, while a schema-driven decoder refuses at the
# first byte. So the rule is not a fixed list; it is "only refusal rows may be
# unchanged", and the report names them.
REFUSAL_PREFIXES = ("decode-truncated-", "decode-corrupt-")


def parse(text: str) -> dict[tuple[str, str], int]:
    rows = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[0] == "sum":
            rows[(parts[1], parts[2])] = int(parts[3]) & U64
        elif len(parts) == 3 and parts[0] == "na":
            continue
        else:
            raise SystemExit(f"unexpected checksum row: {line!r}")
    return rows


def run(binary: Path, mode: str) -> str:
    result = subprocess.run([str(binary), mode], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"{binary.name} {mode} exited {result.returncode}\n{result.stderr}")
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()

    if not args.binary.exists():
        raise SystemExit(f"{args.binary} is missing; build it first")

    real = parse(run(args.binary, "checksum"))
    mutant = parse(run(args.binary, "checksum-mutant"))

    if set(real) != set(mutant):
        raise SystemExit(f"the two modes report different rows: "
                         f"{sorted(set(real) ^ set(mutant))[:8]}")

    decode = [k for k in real if k[1].startswith("decode")]
    if not decode:
        raise SystemExit("no decode rows; the control would prove nothing")

    unchanged = [k for k in decode if real[k] == mutant[k]]
    failures = []

    for key in unchanged:
        if not key[1].startswith(REFUSAL_PREFIXES):
            failures.append(f"{key[0]}/{key[1]}: unchanged under the value-zeroing "
                            f"mutant, so the checksum does not depend on the decoded value")

    for key in decode:
        if key[1] in MUST_CHANGE and real[key] == mutant[key]:
            failures.append(f"{key[0]}/{key[1]}: must change under the mutant")

    names = sorted({k[1] for k in unchanged})
    print(f"barrier self-check: {len(decode)} decode rows, "
          f"{len(decode) - len(unchanged)} change under the value-zeroing mutant, "
          f"{len(unchanged)} unchanged (refusal rows only: {names})")
    for failure in failures:
        print(f"FAIL {failure}")
    if failures:
        print(f"barrier self-check FAILED: {len(failures)} failures")
        return 1
    print("barrier self-check ok: the checksum depends on the decoded values")
    return 0


if __name__ == "__main__":
    sys.exit(main())
