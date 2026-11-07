#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run the goose-msgpack benchmark and record provenance.

NOT RUN YET. The benchmark operator serialises the measurements so no other process
competes for the CPU; this script exists so the run is one command and the
result is auditable.

    python3 bench/measure.py --samples 7 --batch 64 --ms 200

What it does, in order:

1. `verify` on both binaries and compare every fixture against
   bench/fixtures.py, which encodes the same value with the independent
   encoder in tests/oracle.py. A single differing byte aborts the run.
2. Check the two binaries agree with each other, so the paired rows really do
   measure the same workload.
3. Run `--samples` timing passes per binary, alternating them so a slow drift
   in the machine hits both equally.
4. Write `.build/bench/measure.json` and `.build/bench/measure.md` with the
   per-row median, min, max and the provenance block.

The rows are paired by (fixture, operation). A row present in one binary and
missing from the other is an error, not a silent omission.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bench"))
sys.path.insert(0, str(ROOT / "tests"))
import fixtures  # noqa: E402

BENCH = ROOT / ".build" / "bench" / "msgpack-bench"
COMPETITOR = ROOT / ".build" / "bench" / "msgpack-bench-competitor"
OUT_JSON = ROOT / ".build" / "bench" / "measure.json"
OUT_MD = ROOT / ".build" / "bench" / "measure.md"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def run(binary: Path, *args: str) -> str:
    result = subprocess.run([str(binary), *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"{binary.name} {' '.join(args)} exited {result.returncode}\n{result.stderr}")
    return result.stdout


def parse_verify(text: str) -> dict[str, bytes]:
    rows = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 6 or parts[0] != "fixture" or parts[2] != "bytes" or parts[4] != "hex":
            raise SystemExit(f"unexpected verify row: {line!r}")
        data = bytes.fromhex(parts[5])
        if len(data) != int(parts[3]):
            raise SystemExit(f"{parts[1]}: declared {parts[3]} bytes, got {len(data)}")
        rows[parts[1]] = data
    return rows


def parse_time(text: str) -> dict[tuple[str, str], tuple[int, int]]:
    rows = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 5 or parts[0] != "time":
            raise SystemExit(f"unexpected time row: {line!r}")
        rows[(parts[1], parts[2])] = (int(parts[3]), int(parts[4]))
    return rows


def verify() -> dict:
    expected = {row["name"]: row for row in fixtures.expected()}
    mine = parse_verify(run(BENCH, "verify"))
    theirs = parse_verify(run(COMPETITOR, "verify"))
    if set(mine) != set(expected):
        raise SystemExit(f"fixture names differ: {sorted(mine)} vs {sorted(expected)}")
    if set(theirs) != set(expected):
        raise SystemExit(f"competitor fixture names differ: {sorted(theirs)} vs {sorted(expected)}")
    for name, row in expected.items():
        for label, data in (("goose-msgpack", mine[name]), ("competitor", theirs[name])):
            if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
                raise SystemExit(f"{label} {name}: bytes disagree with bench/fixtures.py")
        if mine[name] != theirs[name]:
            raise SystemExit(f"{name}: the two libraries encode different bytes")
    return {"table_sha256": fixtures.table_digest(),
            "rows": [{"name": name, "bytes": len(mine[name]),
                      "sha256": hashlib.sha256(mine[name]).hexdigest()}
                     for name in expected]}


def provenance() -> dict:
    goose = os.environ.get("GOOSE", "")
    revision = (ROOT / "GOOSE_REVISION").read_text().strip()
    version = ""
    if goose and Path(goose).exists():
        version = subprocess.run([goose, "--version"], capture_output=True, text=True).stdout.strip()
    return {
        "goose_revision": revision,
        "goose_binary": goose,
        "goose_version": version,
        "goose_binary_sha256": sha256_file(Path(goose)) if goose and Path(goose).exists() else "",
        "library_sha256": sha256_file(ROOT / "msgpack.goose"),
        "bench_sha256": sha256_file(ROOT / "bench" / "bench.goose"),
        "competitor_sha256": sha256_file(ROOT / "bench" / "bench-competitor.goose"),
        "competitor_commit": "a3d08d25f0260a964f795008ac79468f728a1388",
        "competitor_version": "v0.2.2",
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else [],
        "cc": shutil.which("clang") or "",
        "cc_version": subprocess.run(["clang", "--version"], capture_output=True, text=True).stdout.splitlines()[0]
        if shutil.which("clang") else "",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=7, help="Timing passes per binary")
    parser.add_argument("--batch", type=int, default=64, help="Iterations per timed batch")
    parser.add_argument("--ms", type=int, default=200, help="Minimum window per row, milliseconds")
    args = parser.parse_args()
    if args.samples < 3:
        raise SystemExit("--samples must be at least 3; a single pass is not a measurement")
    for binary in (BENCH, COMPETITOR):
        if not binary.exists():
            raise SystemExit(f"{binary} is missing; run `make bench-build` first")

    checked = verify()
    print(f"verify: {len(checked['rows'])} fixtures, both libraries byte-identical")

    samples: dict[str, dict[tuple[str, str], list[int]]] = {"goose-msgpack": {}, "competitor": {}}
    for _ in range(args.samples):
        for label, binary in (("goose-msgpack", BENCH), ("competitor", COMPETITOR)):
            for key, (batch, ns) in parse_time(run(binary, str(args.batch), str(args.ms))).items():
                samples[label].setdefault(key, []).append(ns / batch)

    keys = set(samples["goose-msgpack"]) | set(samples["competitor"])
    missing = [k for k in keys if k not in samples["goose-msgpack"] or k not in samples["competitor"]]
    if missing:
        raise SystemExit(f"unpaired rows: {sorted(missing)}")

    rows = []
    for key in sorted(keys):
        mine = samples["goose-msgpack"][key]
        theirs = samples["competitor"][key]
        rows.append({
            "fixture": key[0], "operation": key[1],
            "goose_msgpack_ns": statistics.median(mine),
            "goose_msgpack_min_ns": min(mine), "goose_msgpack_max_ns": max(mine),
            "competitor_ns": statistics.median(theirs),
            "competitor_min_ns": min(theirs), "competitor_max_ns": max(theirs),
            "ratio": statistics.median(mine) / statistics.median(theirs) if statistics.median(theirs) else None,
        })

    report = {"provenance": provenance(), "fixtures": checked, "samples": args.samples,
              "batch": args.batch, "window_ms": args.ms, "rows": rows}
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps(report, indent=2) + "\n")

    lines = ["# goose-msgpack benchmark", "",
             f"{args.samples} samples, batch {args.batch}, window {args.ms} ms, median ns/op.", "",
             "| fixture | operation | goose-msgpack | competitor | ratio |",
             "|---|---|---:|---:|---:|"]
    for row in rows:
        ratio = f"{row['ratio']:.3f}" if row["ratio"] else "n/a"
        lines.append(f"| {row['fixture']} | {row['operation']} | "
                     f"{row['goose_msgpack_ns']:.1f} | {row['competitor_ns']:.1f} | {ratio} |")
    lines += ["", "## Provenance", "", "```json",
              json.dumps(report["provenance"], indent=2), "```", ""]
    OUT_MD.write_text("\n".join(lines))
    print(f"wrote {OUT_JSON.relative_to(ROOT)} and {OUT_MD.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
