#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build the baseline benchmark binary from a frozen tree.

The harness is the measurement instrument, so both sides must use the same
`bench/bench.goose`. Only `msgpack.goose` may differ. This script assembles a
scratch tree containing the frozen library and the current harness, builds it,
and refuses to continue if the frozen library changed while it was building.

    python3 bench/build-baseline.py --tree .build/baseline/18c968bcf2d9-v2/tree
    python3 bench/build-baseline.py --tree <frozen tree> --out .build/bench/msgpack-bench-baseline

The frozen tree is read, never written. The scratch tree is rebuilt from it on
every run, so a stale copy cannot be measured by accident.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tree", type=Path, required=True,
                        help="Frozen tree containing msgpack.goose")
    parser.add_argument("--out", type=Path,
                        default=ROOT / ".build" / "bench" / "msgpack-bench-baseline")
    parser.add_argument("--scratch", type=Path,
                        default=ROOT / ".build" / "bench" / "baseline-tree")
    parser.add_argument("--cc", default="clang")
    args = parser.parse_args()

    goose = os.environ.get("GOOSE", "")
    if not goose or not Path(goose).exists():
        raise SystemExit("set GOOSE to the pinned compiler binary")

    library = args.tree / "msgpack.goose"
    if not library.exists():
        raise SystemExit(f"{library} is missing; is --tree a frozen tree?")
    before = sha256_file(library)

    if args.scratch.exists():
        shutil.rmtree(args.scratch)
    (args.scratch / "bench").mkdir(parents=True)
    shutil.copy2(library, args.scratch / "msgpack.goose")
    shutil.copy2(ROOT / "bench" / "bench.goose", args.scratch / "bench" / "bench.goose")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    command = [goose, "build", "-o", str(args.out),
               str(args.scratch / "bench" / "bench.goose"),
               "--standalone", "--cc", args.cc, "-O2"]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"build failed:\n{result.stdout}\n{result.stderr}")

    after = sha256_file(library)
    if before != after:
        raise SystemExit(f"frozen library changed during the build: {before} -> {after}")

    record = {
        "baseline_tree": str(args.tree),
        "library_sha256": before,
        "harness_sha256": sha256_file(ROOT / "bench" / "bench.goose"),
        "binary": str(args.out),
        "binary_sha256": sha256_file(args.out),
        "command": command,
        "cc": args.cc,
    }
    sidecar = args.out.with_suffix(".json")
    sidecar.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
