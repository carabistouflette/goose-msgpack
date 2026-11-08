#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run the goose-msgpack benchmark and record provenance.

NOT RUN YET. The benchmark operator serialises the measurements so no other
process competes for the CPU; this script exists so a run is one command and the
result is auditable.

    python3 bench/measure.py --label baseline --out .build/bench/baseline.json
    python3 bench/measure.py --label optimised --out .build/bench/optimised.json
    python3 bench/measure.py --compare .build/bench/baseline.json \
                                     .build/bench/optimised.json

What a run does, in order:

1. `verify` on both binaries and compare every valid fixture against
   bench/fixtures.py, which encodes the same value with the independent encoder
   in tests/oracle.py. It also checks that both binaries publish the same six
   invalid-input variants per fixture. A missing or differing byte aborts the run.
2. Check the two binaries agree on both valid fixtures and invalid input bytes,
   so the paired rows really do measure the same workload.
3. `checksum` on both binaries: the content checksum each row folds, computed
   once. These are re-checked after the timing passes, so a run whose numbers
   came from different work than the checksums describe is rejected.
4. `--warmup` discarded passes, then `--samples` measured passes per binary.
   The order alternates every sample, so a monotonic drift in the machine hits
   both sides equally instead of favouring whichever ran first.
5. Write the JSON with every raw per-sample value, the dispersion and tail
   statistics, the peak RSS of each pass, and the provenance block hashed
   before and after the run.

`--compare` pairs two runs by (fixture, operation) and refuses to compare runs
whose content checksums differ: a speed-up that changes a checksum is a wrong
answer, not a faster one.

The competitor column is NOT an equal-contract comparison and the report says
so. Macho0x/goose-msgpack has no input, output, node, depth, str, bin or
container budget, no full-input `finish`, and no UTF-8 validation, and its
decoder is a typed schema walk rather than a token stream. Its `value::decode`
DOM builder is deliberately excluded: comparing a token reader to a tree
builder measures the data structure, not the parser. The column is a maintained
reference point, not a gate.
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

MIN_SAMPLES = 20
MIN_WARMUP = 1
INVALID_OPS = (
    "truncated-end",
    "truncated-start",
    "truncated-middle",
    "corrupt-start",
    "corrupt-middle",
    "corrupt-end",
)

NOT_CLASSIFIABLE = (
    "The competitor column is not an equal-contract comparison. "
    "Macho0x/goose-msgpack has no input, output, node, depth, str, bin or "
    "container budget, no full-input `finish`, and no UTF-8 validation, and its "
    "decoder is a typed schema walk rather than a token stream. Its "
    "`value::decode` DOM builder is excluded because comparing a token reader "
    "to a tree builder measures the data structure. Treat the column as a "
    "maintained reference point, not a gate."
)


def rel(path: Path) -> str:
    """Path relative to the repo when it is inside it, absolute otherwise."""
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path.resolve())


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


def run_measured(binary: Path, *args: str) -> tuple[str, int]:
    """Run the binary and return (stdout, peak RSS in KiB) for that child only.

    `resource.getrusage(RUSAGE_CHILDREN)` is a high-water mark across every
    child the process ever waited for, so it cannot attribute memory to one
    binary. `os.wait4` returns the rusage of the specific child.
    """
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:  # pragma: no cover - child
        try:
            os.close(read_fd)
            os.dup2(write_fd, 1)
            os.close(write_fd)
            os.execv(str(binary), [str(binary), *args])
        finally:
            os._exit(127)
    os.close(write_fd)
    chunks = []
    while True:
        block = os.read(read_fd, 1 << 16)
        if not block:
            break
        chunks.append(block)
    os.close(read_fd)
    _, status, usage = os.wait4(pid, 0)
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        raise SystemExit(f"{binary.name} {' '.join(args)} exited {status}\n"
                         + b"".join(chunks).decode("utf-8", "replace"))
    return b"".join(chunks).decode(), usage.ru_maxrss


def parse_verify(text: str) -> tuple[dict[str, bytes], dict[tuple[str, str], bytes]]:
    fixtures_by_name: dict[str, bytes] = {}
    invalid_by_case: dict[tuple[str, str], bytes] = {}
    for line in text.splitlines():
        prefix, separator, hex_data = line.rpartition(" hex ")
        if not separator:
            raise SystemExit(f"unexpected verify row: {line!r}")
        parts = prefix.split()
        if len(parts) == 4 and parts[0] == "fixture" and parts[2] == "bytes":
            key = parts[1]
            rows = fixtures_by_name
            declared = parts[3]
        elif len(parts) == 5 and parts[0] == "invalid" and parts[3] == "bytes":
            key = (parts[1], parts[2])
            rows = invalid_by_case
            declared = parts[4]
        else:
            raise SystemExit(f"unexpected verify row: {line!r}")
        data = bytes.fromhex(hex_data)
        if len(data) != int(declared):
            raise SystemExit(f"{key}: declared {declared} bytes, got {len(data)}")
        if key in rows:
            raise SystemExit(f"duplicate verify row: {key}")
        rows[key] = data
    return fixtures_by_name, invalid_by_case


def parse_time(text: str) -> dict[tuple[str, str], float]:
    """Parse `time <fixture> <op> <n> <dt_ns>` into ns per call.

    The binary prints two totals, never a rate: `n` calls took `dt_ns`
    nanoseconds. The division happens here, exactly once. An earlier version of
    the harness printed a rate next to the batch size and this reader divided by
    the batch again, which understated every row by the batch size. Reports
    produced before that fix are labelled `invalid-unit` and must not be
    compared with anything.
    """
    rows: dict[tuple[str, str], float] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] == "na":
            continue  # not applicable for this binary; paired from the other side
        if len(parts) != 5 or parts[0] != "time":
            raise SystemExit(f"unexpected time row: {line!r}")
        n, dt = int(parts[3]), int(parts[4])
        if n <= 0:
            raise SystemExit(f"time row with n={n}: {line!r}")
        rows[(parts[1], parts[2])] = dt / n
    return rows


def parse_checksum(text: str) -> tuple[dict[tuple[str, str], int], set[tuple[str, str]]]:
    sums: dict[tuple[str, str], int] = {}
    na: set[tuple[str, str]] = set()
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[0] == "sum":
            sums[(parts[1], parts[2])] = int(parts[3])
        elif len(parts) == 3 and parts[0] == "na":
            na.add((parts[1], parts[2]))
        else:
            raise SystemExit(f"unexpected checksum row: {line!r}")
    return sums, na


def verify(bench: Path) -> dict:
    expected = {row["name"]: row for row in fixtures.expected()}
    mine, mine_invalid = parse_verify(run(bench, "verify"))
    theirs, theirs_invalid = parse_verify(run(COMPETITOR, "verify"))
    if set(mine) != set(expected):
        raise SystemExit(f"fixture names differ: {sorted(mine)} vs {sorted(expected)}")
    if set(theirs) != set(expected):
        raise SystemExit(f"competitor fixture names differ: {sorted(theirs)} vs {sorted(expected)}")
    expected_invalid = {(name, op) for name in expected for op in INVALID_OPS}
    for label, rows in (("goose-msgpack", mine_invalid), ("competitor", theirs_invalid)):
        if set(rows) != expected_invalid:
            raise SystemExit(
                f"{label} invalid cases differ: missing {sorted(expected_invalid - set(rows))}, "
                f"extra {sorted(set(rows) - expected_invalid)}")
    for name, row in expected.items():
        for label, data in (("goose-msgpack", mine[name]), ("competitor", theirs[name])):
            if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
                raise SystemExit(f"{label} {name}: bytes disagree with bench/fixtures.py")
        if mine[name] != theirs[name]:
            raise SystemExit(f"{name}: the two libraries encode different bytes")
    for key in sorted(expected_invalid):
        if mine_invalid[key] != theirs_invalid[key]:
            raise SystemExit(f"{key}: the two libraries publish different invalid input bytes")
    return {"table_sha256": fixtures.table_digest(),
            "rows": [{"name": name, "bytes": len(mine[name]),
                      "sha256": hashlib.sha256(mine[name]).hexdigest()}
                     for name in expected],
            "invalid_rows": [{"fixture": name, "operation": op,
                              "bytes": len(mine_invalid[(name, op)]),
                              "sha256": hashlib.sha256(mine_invalid[(name, op)]).hexdigest()}
                             for name, op in sorted(expected_invalid)]}


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
        "bench_binary_sha256": sha256_file(Path(os.environ["BENCH_BINARY"]))
        if os.environ.get("BENCH_BINARY") and Path(os.environ["BENCH_BINARY"]).exists() else "",
        "competitor_sha256": sha256_file(ROOT / "bench" / "bench-competitor.goose"),
        "competitor_commit": "a3d08d25f0260a964f795008ac79468f728a1388",
        "competitor_version": "v0.2.1-1-ga3d08d2",
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


def dispersion(values: list[float]) -> dict:
    ordered = sorted(values)
    median = statistics.median(ordered)
    deviations = sorted(abs(v - median) for v in ordered)
    n = len(ordered)

    def quantile(q: float) -> float:
        # Linear interpolation between order statistics; n >= 20 so this is
        # never degenerate.
        pos = q * (n - 1)
        low = int(pos)
        high = min(low + 1, n - 1)
        return ordered[low] + (ordered[high] - ordered[low]) * (pos - low)

    return {
        "n": n,
        "median": median,
        "mean": statistics.fmean(ordered),
        "min": ordered[0],
        "max": ordered[-1],
        "p10": quantile(0.10),
        "p90": quantile(0.90),
        "iqr": quantile(0.75) - quantile(0.25),
        "mad": statistics.median(deviations),
        "stdev": statistics.stdev(ordered) if n > 1 else 0.0,
        "raw": values,
    }


def measure(args) -> dict:
    bench = args.bench.resolve()
    for binary in (bench, COMPETITOR):
        if not binary.exists():
            raise SystemExit(f"{binary} is missing; run `make bench-build` first")

    before = provenance()
    checked = verify(bench)
    print(f"verify: {len(checked['rows'])} fixtures, {len(checked['invalid_rows'])} invalid inputs, "
          "both libraries byte-identical")

    sums = {"goose-msgpack": parse_checksum(run(bench, "checksum")),
            "competitor": parse_checksum(run(COMPETITOR, "checksum"))}
    for label, (rows, na) in sums.items():
        print(f"checksum: {label} {len(rows)} rows, {len(na)} not applicable")

    binaries = (("goose-msgpack", bench), ("competitor", COMPETITOR))
    samples: dict[str, dict[tuple[str, str], list[float]]] = {"goose-msgpack": {}, "competitor": {}}
    rss: dict[str, list[int]] = {"goose-msgpack": [], "competitor": []}

    for _ in range(args.warmup):
        for _, binary in binaries:
            run(binary, str(args.batch), str(args.ms))
    print(f"warmup: {args.warmup} discarded passes per binary")

    for index in range(args.samples):
        # Alternate which side runs first so a monotonic drift in the machine
        # does not systematically favour one of them.
        order = binaries if index % 2 == 0 else tuple(reversed(binaries))
        for label, binary in order:
            text, peak_kib = run_measured(binary, str(args.batch), str(args.ms))
            rss[label].append(peak_kib)
            for key, ns_per_call in parse_time(text).items():
                samples[label].setdefault(key, []).append(ns_per_call)
        if (index + 1) % 5 == 0:
            print(f"  {index + 1}/{args.samples} samples")

    after = provenance()
    for field in ("library_sha256", "bench_sha256", "competitor_sha256", "goose_binary_sha256"):
        if before[field] != after[field]:
            raise SystemExit(f"{field} changed during the run: {before[field]} -> {after[field]}")

    # The checksums must still describe the code that produced the timings.
    for label, binary in binaries:
        if parse_checksum(run(binary, "checksum")) != sums[label]:
            raise SystemExit(f"{label}: content checksums changed during the run")

    mine_keys = set(samples["goose-msgpack"])
    theirs_keys = set(samples["competitor"])
    if theirs_keys - mine_keys:
        raise SystemExit(f"competitor timed rows we did not: {sorted(theirs_keys - mine_keys)}")
    # A row the competitor did not time is only acceptable if it declared the
    # cell not applicable. Anything else is a silent omission.
    undeclared = (mine_keys - theirs_keys) - sums["competitor"][1]
    if undeclared:
        raise SystemExit(f"competitor silently omitted rows: {sorted(undeclared)}")
    for label in samples:
        for key, values in samples[label].items():
            if len(values) != args.samples:
                raise SystemExit(f"{label} {key}: {len(values)} samples, expected {args.samples}")

    rows = []
    for key in sorted(mine_keys):
        mine = dispersion(samples["goose-msgpack"][key])
        applicable = key in theirs_keys
        theirs = dispersion(samples["competitor"][key]) if applicable else None
        rows.append({
            "fixture": key[0],
            "operation": key[1],
            "goose_msgpack": mine,
            "competitor": theirs,
            "ratio_median": (mine["median"] / theirs["median"]) if applicable and theirs["median"] else None,
            "goose_msgpack_checksum": sums["goose-msgpack"][0].get(key),
            "competitor_checksum": sums["competitor"][0].get(key),
            "competitor_applicable": applicable,
        })

    return {
        "label": args.label,
        "provenance_before": before,
        "provenance_after": after,
        "fixtures": checked,
        "samples": args.samples,
        "warmup": args.warmup,
        "batch": args.batch,
        "window_ms": args.ms,
        "peak_rss_kib": {label: {"max": max(v), "min": min(v), "raw": v} for label, v in rss.items()},
        "not_classifiable": NOT_CLASSIFIABLE,
        "rows": rows,
    }


def render(report: dict) -> str:
    lines = [
        f"# goose-msgpack benchmark — {report['label']}",
        "",
        f"{report['samples']} measured samples after {report['warmup']} discarded warmup "
        f"passes, batch {report['batch']}, window {report['window_ms']} ms, "
        "alternating order. Values are ns/op.",
        "",
        "| fixture | operation | goose-msgpack median | p10 | p90 | MAD | competitor median | ratio |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in report["rows"]:
        mine = row["goose_msgpack"]
        theirs = row["competitor"]
        ratio = f"{row['ratio_median']:.3f}" if row["ratio_median"] else "n/a"
        competitor = f"{theirs['median']:.1f}" if row["competitor_applicable"] else "n/a"
        lines.append(
            f"| {row['fixture']} | {row['operation']} | {mine['median']:.1f} | "
            f"{mine['p10']:.1f} | {mine['p90']:.1f} | {mine['mad']:.1f} | "
            f"{competitor} | {ratio} |"
        )
    rss = report["peak_rss_kib"]
    lines += [
        "",
        f"Peak RSS: goose-msgpack {rss['goose-msgpack']['max']} KiB, "
        f"competitor {rss['competitor']['max']} KiB.",
        "",
        "## Not classifiable",
        "",
        report["not_classifiable"],
        "",
        "## Provenance",
        "",
        "```json",
        json.dumps(report["provenance_before"], indent=2),
        "```",
        "",
    ]
    return "\n".join(lines)


def compare(paths: list[Path]) -> int:
    if len(paths) != 2:
        raise SystemExit("--compare takes exactly two report files: baseline then optimised")
    base, opt = (json.loads(p.read_text()) for p in paths)
    for report, path in ((base, paths[0]), (opt, paths[1])):
        if report["samples"] < MIN_SAMPLES:
            raise SystemExit(f"{path}: {report['samples']} samples, need at least {MIN_SAMPLES}")

    base_rows = {(r["fixture"], r["operation"]): r for r in base["rows"]}
    opt_rows = {(r["fixture"], r["operation"]): r for r in opt["rows"]}
    if set(base_rows) != set(opt_rows):
        raise SystemExit(f"row sets differ: {sorted(set(base_rows) ^ set(opt_rows))}")

    # The load-bearing gate: the optimised side must compute the same content
    # checksum as the baseline. A faster wrong answer is not a result.
    for key in sorted(base_rows):
        a = base_rows[key]["goose_msgpack_checksum"]
        b = opt_rows[key]["goose_msgpack_checksum"]
        if a != b:
            raise SystemExit(f"{key}: content checksum changed {a} -> {b}; refusing to compare")

    lines = [
        f"# goose-msgpack: {base['label']} vs {opt['label']}",
        "",
        f"{base['samples']} vs {opt['samples']} samples, "
        f"batch {base['batch']}/{opt['batch']}, window {base['window_ms']}/{opt['window_ms']} ms.",
        "Content checksums identical on every row.",
        "",
        "| fixture | operation | baseline median | optimised median | change | baseline p90 | optimised p90 |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for key in sorted(base_rows):
        a = base_rows[key]["goose_msgpack"]
        b = opt_rows[key]["goose_msgpack"]
        change = (b["median"] - a["median"]) / a["median"] * 100 if a["median"] else 0.0
        lines.append(
            f"| {key[0]} | {key[1]} | {a['median']:.1f} | {b['median']:.1f} | "
            f"{change:+.1f}% | {a['p90']:.1f} | {b['p90']:.1f} |"
        )
    lines += ["", "## Provenance", "", "```json",
              json.dumps({"baseline": base["provenance_before"],
                          "optimised": opt["provenance_before"]}, indent=2), "```", ""]
    text = "\n".join(lines)
    out = ROOT / ".build" / "bench" / "compare.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(text)
    print(f"wrote {rel(out)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--samples", type=int, default=MIN_SAMPLES,
                        help=f"Measured passes per binary (default and minimum {MIN_SAMPLES})")
    parser.add_argument("--warmup", type=int, default=2,
                        help=f"Discarded passes per binary before measuring (minimum {MIN_WARMUP})")
    parser.add_argument("--batch", type=int, default=64, help="Iterations per timed batch")
    parser.add_argument("--ms", type=int, default=200, help="Minimum window per row, milliseconds")
    parser.add_argument("--label", default="run", help="Name recorded in the report")
    parser.add_argument("--bench", type=Path, default=BENCH,
                        help="goose-msgpack benchmark binary (default .build/bench/msgpack-bench)")
    parser.add_argument("--out", type=Path, help="Report path (default .build/bench/<label>.json)")
    parser.add_argument("--compare", type=Path, nargs="+", metavar="REPORT",
                        help="Pair two reports instead of measuring")
    args = parser.parse_args()

    if args.compare:
        return compare(args.compare)
    if args.samples < MIN_SAMPLES:
        raise SystemExit(f"--samples must be at least {MIN_SAMPLES}; fewer is not a measurement")
    if args.warmup < MIN_WARMUP:
        raise SystemExit(f"--warmup must be at least {MIN_WARMUP}")

    os.environ["BENCH_BINARY"] = str(args.bench.resolve())
    report = measure(args)
    out = args.out or (ROOT / ".build" / "bench" / f"{args.label}.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n")
    md = out.with_suffix(".md")
    md.write_text(render(report))
    print(f"wrote {rel(out)} and {rel(md)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
