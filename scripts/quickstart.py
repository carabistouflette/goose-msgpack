#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run the README quickstart, so it cannot rot.

The first ```goose block in README.md is the quickstart. It imports the
published revision; this script rewrites that one line to the local package
to test the current source, and runs the result with the pinned
compiler. Any other edit to the block is executed verbatim.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLISHED = re.compile(r'^import msgpack from "[^"]*";$', re.M)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--goose", required=True)
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    readme = (ROOT / "README.md").read_text()
    match = re.search(r"```goose\n(.*?)```", readme, re.S)
    if match is None:
        print("README.md has no ```goose quickstart block", file=sys.stderr)
        return 1
    block = match.group(1)
    if not PUBLISHED.search(block):
        print("quickstart does not import the package", file=sys.stderr)
        return 1
    local = PUBLISHED.sub('import msgpack from "..";', block, count=1)

    target = ROOT / ".build" / "quickstart.goose"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(local)

    command = [args.goose, "run", str(target.relative_to(ROOT))]
    if args.debug:
        command.append("--debug")
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"README quickstart failed: exit {result.returncode}", file=sys.stderr)
        print(result.stdout, file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        return result.returncode
    print("README quickstart ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
