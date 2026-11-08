#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Vendor the third-party references at pinned commits, for triangulation only.

Two independent implementations are used, for two different jobs:

- **msgpack-c** (the C library maintained by the official msgpack
  organisation) is the correctness oracle. `tests/triangulate.py` decodes the
  same corpus with it and with this library and compares the canonical token
  form. It exists to break the correlated-defect risk of a single model: the
  differential oracle in `tests/oracle.py` was written for this library and can
  share a misreading of the specification with it.

- **MPack** (a maintained zero-allocation C token reader) is the performance
  reference. `bench/bench-mpack.c` builds the same fixtures with it and times
  the same rows, so the comparison is against a real implementation and not
  only against our own standard library.

Nothing here is vendored into the repository: `.build/` is ignored, and the
checkouts are read-only inputs. `--check` verifies an existing checkout without
touching the network.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / ".build" / "thirdparty"

# name, repository, commit, what the commit is
REFERENCES = [
    ("msgpack-c", "https://github.com/msgpack/msgpack-c",
     "f3f796bbe6a2dd0414520f187cec2e4bd41766bf",
     "c_master, version 7.0.3, 2026-11-06"),
    ("mpack", "https://github.com/ludocode/mpack",
     "c9d1820ecfdbc3954c60a218492251e457cc1f86",
     "version 1.1.1, 2026-08-07"),
]


def git(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True,
                          capture_output=True, text=True).stdout.strip()


def head(path: Path) -> str:
    return git("rev-parse", "HEAD", cwd=path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true",
                        help="Verify the checkouts without touching the network")
    parser.add_argument("--force", action="store_true", help="Re-clone even if the commit matches")
    args = parser.parse_args()

    DEST.mkdir(parents=True, exist_ok=True)
    failed = False
    for name, repo, commit, what in REFERENCES:
        path = DEST / name
        if path.exists() and not args.force:
            try:
                if head(path) == commit:
                    print(f"{name}: {path} at {commit} ({what})")
                    continue
            except subprocess.CalledProcessError:
                pass
            if args.check:
                print(f"{name}: {path} is not at {commit}", file=sys.stderr)
                failed = True
                continue
            print(f"{name}: {path} is not at {commit}; re-cloning", file=sys.stderr)
        if args.check:
            print(f"{name}: {path} is missing", file=sys.stderr)
            failed = True
            continue
        if path.exists():
            subprocess.run(["rm", "-rf", str(path)], check=True)
        git("clone", "--quiet", repo, str(path))
        # msgpack-c keeps the C library on `c_master`; the default branch is the
        # C++ one. Fetch the commit directly so the pin is what is checked out.
        try:
            git("checkout", "--quiet", commit, cwd=path)
        except subprocess.CalledProcessError:
            git("fetch", "--quiet", "--depth", "1", "origin", commit, cwd=path)
            git("checkout", "--quiet", "FETCH_HEAD", cwd=path)
        found = head(path)
        if found != commit:
            print(f"{name}: HEAD is {found}, expected {commit}", file=sys.stderr)
            failed = True
            continue
        print(f"{name}: {path} at {found} ({what})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
