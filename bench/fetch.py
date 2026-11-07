#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Vendor the competitor at its pinned commit, for the benchmark only.

Macho0x/goose-msgpack is a maintained third-party library. The benchmark must
compare against a fixed revision, so this script clones it into
`.build/competitor/goose-msgpack` and refuses to continue unless HEAD is the
recorded commit. Nothing here is vendored into the repository: `.build/` is
ignored, and `make bench-build` is the only target that calls this.

The competitor's source is not modified. Its entry file is `msgpack.goose`,
which is why bench/bench-competitor.goose is a separate program: a Goose import
alias must equal the entry file's basename, so one program cannot import both
this package and goose-msgpack.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / ".build" / "competitor" / "goose-msgpack"
REPO = "https://github.com/Macho0x/goose-msgpack"
COMMIT = "a3d08d25f0260a964f795008ac79468f728a1388"
VERSION = "v0.2.2"


def git(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True,
                          capture_output=True, text=True).stdout.strip()


def head(path: Path) -> str:
    return git("rev-parse", "HEAD", cwd=path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="Re-clone even if the commit matches")
    args = parser.parse_args()

    if DEST.exists() and not args.force:
        try:
            if head(DEST) == COMMIT:
                print(f"competitor: {DEST} at {COMMIT} ({VERSION})")
                return 0
        except subprocess.CalledProcessError:
            pass
        print(f"competitor: {DEST} is not at {COMMIT}; re-cloning", file=sys.stderr)

    DEST.parent.mkdir(parents=True, exist_ok=True)
    if DEST.exists():
        subprocess.run(["rm", "-rf", str(DEST)], check=True)
    git("clone", "--quiet", REPO, str(DEST))
    git("checkout", "--quiet", COMMIT, cwd=DEST)
    found = head(DEST)
    if found != COMMIT:
        print(f"competitor: HEAD is {found}, expected {COMMIT}", file=sys.stderr)
        return 1
    print(f"competitor: {DEST} at {found} ({VERSION})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
