#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Paired A/B measurement with a negative control and a contention record.

`bench/measure.py` is the historical instrument: it pairs goose-msgpack with the
Macho0x competitor inside one run and reports medians. This tool answers a
different question, the one a change has to answer: *did B get faster than A,
on the same work, by more than the noise?*

    # The negative control. A and B are the same binary, so the true ratio is
    # 1.0 on every row. If the design reports otherwise, the window is
    # contaminated and no comparison from it is valid.
    python3 bench/paired.py --a X --b X --label self-control --self-control

    # The comparison.
    python3 bench/paired.py --a old --b new --label old-vs-new --same-library

    # A third-party column.
    python3 bench/paired.py --a ours --b mpack --label ours-vs-mpack

Design
------

- **Paired.** A and B run alternately, and which one runs first alternates every
  sample, so a monotonic drift in the machine hits both columns equally. The
  ratio is computed from the paired samples, not from two independent medians.
- **Pinned.** Every child is pinned to one CPU, chosen explicitly and recorded,
  so a measurement cannot migrate between cores mid-run.
- **Checksums outside the loop.** `checksum` mode is run before and after the
  timing passes and must be identical. For `--same-library` the two binaries
  must also agree on every checksum, which is what makes "faster" mean "faster
  at the same answer". For a third-party column the encode checksums must agree
  (same workload) but the decode checksums cannot, because the token models
  differ; that is stated in the report rather than hidden.
- **Ratio interval.** A bootstrap over the paired samples gives a 95% interval
  for the ratio. A change whose interval straddles 1.0 is not a result.
- **Contention record.** `bench/contention.py` is run before and after and its
  verdict is recorded. When the host cannot give a quiet window the run is
  labelled `exploratory` and cannot support a ranking claim; the negative
  control is what still makes the *comparison* meaningful under steady load.
- **Peak RSS** per pass, from `os.wait4`, so it is attributed to that child.

Exit status is 0 when the run is admissible and every gate passed, 1 otherwise.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import random
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bench"))
sys.path.insert(0, str(ROOT / "tests"))
import fixtures  # noqa: E402
import provenance  # noqa: E402

MIN_SAMPLES = 20
MIN_WARMUP = 1
BOOTSTRAP = 4000


def cpu_model() -> str:
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return "unknown"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def run(binary: Path, *args: str, cpu: int | None = None) -> str:
    def pin() -> None:
        if cpu is not None:
            os.sched_setaffinity(0, {cpu})

    result = subprocess.run([str(binary), *args], capture_output=True, text=True,
                            preexec_fn=pin)
    if result.returncode != 0:
        raise SystemExit(f"{binary.name} {' '.join(args)} exited {result.returncode}\n{result.stderr}")
    return result.stdout


def run_measured(binary: Path, args: tuple[str, ...], cpu: int | None) -> tuple[str, int]:
    """Run the binary and return (stdout, peak RSS in KiB) for that child only."""
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:  # pragma: no cover - child
        try:
            os.close(read_fd)
            os.dup2(write_fd, 1)
            os.close(write_fd)
            if cpu is not None:
                os.sched_setaffinity(0, {cpu})
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


def parse_verify(text: str) -> dict[str, bytes]:
    """Parse `verify` rows into {key: bytes}.

    Two row shapes are accepted:

        fixture <name> bytes <n> hex <hex>
        invalid <name> <op> bytes <n> hex <hex>

    The invalid variants are published because a comparator that builds
    different invalid inputs is not measuring the same rows. A bit flip and the
    reserved marker 0xc1 are different documents: the first leaves a valid
    marker in place and the decoder walks the whole document, the second is
    refused at the first byte. Comparing those two as if they were one row would
    report a refusal against a traversal and call it a speed difference.
    """
    rows = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 6 and parts[0] == "fixture":
            key = parts[1]
            count, hexdigest = parts[3], parts[5]
            if parts[2] != "bytes" or parts[4] != "hex":
                raise SystemExit(f"unexpected verify row: {line!r}")
        elif len(parts) == 7 and parts[0] == "invalid":
            key = f"{parts[1]}/{parts[2]}"
            count, hexdigest = parts[4], parts[6]
            if parts[3] != "bytes" or parts[5] != "hex":
                raise SystemExit(f"unexpected verify row: {line!r}")
        else:
            raise SystemExit(f"unexpected verify row: {line!r}")
        data = bytes.fromhex(hexdigest)
        if len(data) != int(count):
            raise SystemExit(f"{key}: declared {count} bytes, got {len(data)}")
        rows[key] = data
    return rows


def parse_time(text: str) -> dict[tuple[str, str], float]:
    """Parse `time <fixture> <op> <n> <dt_ns>` into ns per call.

    The binary prints two totals, never a rate: `n` calls took `dt_ns`
    nanoseconds. The division happens here, exactly once. An earlier version of
    the harness printed a rate next to the batch size, and the reader divided by
    the batch again, which understated every row by the batch size. The
    `--selftest` control pins this contract.
    """
    rows: dict[tuple[str, str], float] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] == "na":
            continue
        if len(parts) != 5 or parts[0] != "time":
            raise SystemExit(f"unexpected time row: {line!r}")
        n, dt = int(parts[3]), int(parts[4])
        if n <= 0:
            raise SystemExit(f"time row with n={n}: {line!r}")
        rows[(parts[1], parts[2])] = dt / n
    return rows


NOISE_CEILING = 0.15   # above this the host cannot resolve the control
DELTA_FLOOR = 0.10     # a quiet host still gets a tight gate
FACTOR_ERROR = 0.50    # a factor-of-batch error is >= 100%; 50% is already wrong


def invariance_verdict(small: list[float], large: list[float]) -> dict:
    """Decide whether two batches of the same work cost the same per call.

    Three outcomes, because two would be dishonest:

    - `ok`: the between-batch difference is within the noise the run itself
      observed, so the instrument is invariant.
    - `fail`: the difference is larger than the noise explains, or is large
      enough to be a factor-of-batch error whatever the noise was.
    - `inconclusive`: the within-batch spread is so large that the host cannot
      resolve the question. This is **not** a pass. A noisy host makes the
      measurement unavailable; it does not make the instrument correct.

    The gate is calibrated against the noise it actually saw rather than a fixed
    percentage, because on a loaded host the between-batch difference reaches
    tens of percent on its own. But the calibration is only allowed to *excuse*
    a difference up to the point where the noise itself becomes the problem.
    """
    def spread(values: list[float]) -> float:
        mid = statistics.median(values)
        return (max(values) - min(values)) / mid if mid else 0.0

    a_mid, b_mid = statistics.median(small), statistics.median(large)
    if not a_mid:
        return {"small_ns": a_mid, "large_ns": b_mid, "delta": 0.0,
                "noise": 0.0, "allowed": 0.0, "status": "fail", "ok": False}
    delta = abs(b_mid - a_mid) / a_mid
    noise = max(spread(small), spread(large))
    allowed = max(DELTA_FLOOR, 2.0 * noise)
    if delta >= FACTOR_ERROR:
        status = "fail"
    elif noise > NOISE_CEILING:
        status = "inconclusive"
    elif delta <= allowed:
        status = "ok"
    else:
        status = "fail"
    return {"small_ns": a_mid, "large_ns": b_mid, "delta": delta,
            "noise": noise, "allowed": allowed, "status": status,
            "ok": status == "ok"}


def selftest() -> int:
    """Analytic controls for the output contract.

    A parser that divides twice, or not at all, still produces plausible
    numbers. These cases pin the arithmetic: 32 calls in 3200 ns is 100 ns per
    call, and the same rate expressed with a different batch must parse to the
    same value.
    """
    cases = [
        ("time f o 32 3200\n", {("f", "o"): 100.0}),
        ("time f o 64 6400\n", {("f", "o"): 100.0}),
        ("time f o 1 7\n", {("f", "o"): 7.0}),
        ("time f o 32 3200\ntime g p 8 96\n", {("f", "o"): 100.0, ("g", "p"): 12.0}),
        ("na f o\n", {}),
    ]
    failures = 0
    for text, expected in cases:
        got = parse_time(text)
        if got != expected:
            print(f"FAIL parse_time({text!r}) = {got}, expected {expected}")
            failures += 1
    # A zero-call row is a broken binary, not a fast one.
    for bad in ("time f o 0 0\n", "time f o 32\n", "time f o 32 3200 9\n"):
        try:
            parse_time(bad)
        except SystemExit:
            continue
        print(f"FAIL parse_time({bad!r}) was accepted")
        failures += 1
    if failures:
        print(f"{failures} parse self-check failure(s)")
        return 1
    print(f"parse self-check ok: {len(cases)} analytic cases, 3 malformed rows refused")

    # The batch-invariance rule must catch a factor error, must not refuse a
    # correct instrument on a mildly noisy host, and must report a host too noisy
    # to resolve the question as inconclusive rather than as a pass.
    invariance_cases = [
        # (small passes, large passes, expected status, why)
        ([100.0, 100.0, 100.0], [100.0, 100.0, 100.0], "ok", "identical"),
        ([100.0, 100.0, 100.0], [200.0, 200.0, 200.0], "fail", "factor-of-two error"),
        ([100.0, 100.0, 100.0], [3200.0, 3200.0, 3200.0], "fail", "factor-of-32 error"),
        ([100.0, 105.0, 95.0], [103.0, 100.0, 97.0], "ok", "5% noise, no real delta"),
        ([100.0, 130.0, 70.0], [130.0, 100.0, 70.0], "inconclusive",
         "30% noise: the host cannot resolve it, which is not a pass"),
        ([100.0, 130.0, 70.0], [200.0, 260.0, 140.0], "fail", "factor error under noise"),
        ([100.0, 100.0, 100.0], [140.0, 140.0, 140.0], "fail", "40% delta on a quiet host"),
    ]
    for small, large, expected, why in invariance_cases:
        got = invariance_verdict(small, large)["status"]
        if got != expected:
            print(f"FAIL invariance_verdict({small}, {large}) = {got}, expected {expected} ({why})")
            failures += 1
    if failures:
        print(f"{failures} invariance self-check failure(s)")
        return 1
    print(f"invariance self-check ok: {len(invariance_cases)} cases, "
          "factor errors refused, noise reported as inconclusive")

    # The identity gates must refuse a stale sidecar and a changed source. Both
    # are the failure modes a rebuild leaves behind: the binary is new, the
    # record is old, and the functional checksums still agree.
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "bin"
        binary.write_bytes(b"one")
        source = Path(tmp) / "src"
        source.write_bytes(b"source")
        good = {"binary_sha256": sha256_file(binary),
                "sources": [{"path": str(source), "sha256": sha256_file(source)}]}
        stale = {"binary_sha256": "0" * 64,
                 "sources": [{"path": str(source), "sha256": "0" * 64}]}
        identity_cases = [
            ("sidecar matches the binary", provenance.sidecar_matches(binary, good), True),
            ("stale sidecar refused", provenance.sidecar_matches(binary, stale), False),
            ("missing sidecar refused", provenance.sidecar_matches(binary, None), False),
            ("sources unchanged", provenance.sources_unchanged(good), True),
            ("changed source refused", provenance.sources_unchanged(stale), False),
        ]
        for why, got, expected in identity_cases:
            if got != expected:
                print(f"FAIL {why}: got {got}, expected {expected}")
                failures += 1
        # A rebuild after the record was written must be caught.
        binary.write_bytes(b"two")
        if provenance.sidecar_matches(binary, good):
            print("FAIL a rebuilt binary still matched its old sidecar")
            failures += 1
    if failures:
        print(f"{failures} identity self-check failure(s)")
        return 1
    print(f"identity self-check ok: {len(identity_cases) + 1} cases, "
          "stale sidecar and changed source refused")
    return 0


U64_MASK = (1 << 64) - 1


def parse_checksum(text: str) -> tuple[dict[tuple[str, str], int], set[tuple[str, str]]]:
    """Parse `sum <fixture> <op> <value>` rows.

    The value is normalised to an unsigned 64-bit integer. A checksum is a u64
    bit pattern, and a harness that formats it through a signed integer prints
    the same bits as a negative number. Normalising here means the comparison is
    about the bits, not about the sign convention of whoever printed them.
    """
    sums: dict[tuple[str, str], int] = {}
    na: set[tuple[str, str]] = set()
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[0] == "sum":
            sums[(parts[1], parts[2])] = int(parts[3]) & U64_MASK
        elif len(parts) == 3 and parts[0] == "na":
            na.add((parts[1], parts[2]))
        else:
            raise SystemExit(f"unexpected checksum row: {line!r}")
    return sums, na


def dispersion(values: list[float]) -> dict:
    ordered = sorted(values)
    n = len(ordered)
    median = statistics.median(ordered)
    deviations = sorted(abs(v - median) for v in ordered)

    def quantile(q: float) -> float:
        pos = q * (n - 1)
        low = int(pos)
        high = min(low + 1, n - 1)
        return ordered[low] + (ordered[high] - ordered[low]) * (pos - low)

    mad = statistics.median(deviations)
    # A sample further than 3 MAD from the median is reported, not removed: a
    # contaminated sample is evidence about the window, and hiding it would
    # make the negative control unable to fail.
    outliers = [i for i, v in enumerate(values) if mad and abs(v - median) > 3 * mad]
    return {
        "n": n,
        "median": median,
        "mean": statistics.fmean(ordered),
        "min": ordered[0],
        "max": ordered[-1],
        "p10": quantile(0.10),
        "p90": quantile(0.90),
        "iqr": quantile(0.75) - quantile(0.25),
        "mad": mad,
        "outliers": outliers,
        "stdev": statistics.stdev(ordered) if n > 1 else 0.0,
        "cv": (statistics.stdev(ordered) / statistics.fmean(ordered))
        if n > 1 and statistics.fmean(ordered) else 0.0,
        "raw": values,
    }


def bootstrap_ratio(a: list[float], b: list[float], seed: int) -> dict:
    """95% interval for median(b)/median(a), resampling the paired samples."""
    if len(a) != len(b):
        raise SystemExit("paired samples differ in length")
    rng = random.Random(seed)
    n = len(a)
    ratios = []
    for _ in range(BOOTSTRAP):
        idx = [rng.randrange(n) for _ in range(n)]
        ma = statistics.median(a[i] for i in idx)
        mb = statistics.median(b[i] for i in idx)
        if ma:
            ratios.append(mb / ma)
    ratios.sort()
    point = statistics.median(b) / statistics.median(a) if statistics.median(a) else 0.0
    return {
        "point": point,
        "low": ratios[int(0.025 * len(ratios))],
        "high": ratios[int(0.975 * len(ratios)) - 1],
        "bootstrap": BOOTSTRAP,
        "seed": seed,
    }


def contention(cpu: int | None, out: Path) -> dict:
    command = [sys.executable, str(ROOT / "bench" / "contention.py"), "--json", str(out)]
    if cpu is not None:
        command += ["--cpu", str(cpu)]
    result = subprocess.run(command, capture_output=True, text=True)
    if not out.exists():
        raise SystemExit(f"contention check failed:\n{result.stdout}\n{result.stderr}")
    return json.loads(out.read_text())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--a", type=Path, help="Binary A (the reference)")
    parser.add_argument("--b", type=Path, help="Binary B (the candidate)")
    parser.add_argument("--label", default="paired", help="Name recorded in the report")
    parser.add_argument("--samples", type=int, default=MIN_SAMPLES)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--batch", type=int, default=256, help="Iterations per timed batch")
    parser.add_argument("--ms", type=int, default=100, help="Minimum window per row, milliseconds")
    parser.add_argument("--cpu", type=int, default=None,
                        help="CPU to pin every child to (default: the least busy one)")
    parser.add_argument("--seed", type=int, default=20261107, help="Bootstrap seed")
    parser.add_argument("--same-library", action="store_true",
                        help="A and B are the same library: every checksum must match")
    parser.add_argument("--self-control", action="store_true",
                        help="A and B are the same binary: every ratio interval must contain 1.0")
    parser.add_argument("--allow-compiler-mismatch", action="store_true",
                        help="Proceed even when the two binaries were built by "
                             "different compilers. The run is then labelled "
                             "confounded and no difference may be attributed to "
                             "the library.")
    parser.add_argument("--skip-contention", action="store_true",
                        help="Do not run the contention check (the run is then exploratory)")
    parser.add_argument("--a-args", default="",
                        help="Extra arguments before <batch> <ms> for binary A, "
                             "e.g. 'contract' for a comparator with a mode switch")
    parser.add_argument("--b-args", default="",
                        help="Extra arguments before <batch> <ms> for binary B")
    parser.add_argument("--out", type=Path, help="Report path (default .build/bench/<label>.json)")
    parser.add_argument("--selftest", action="store_true",
                        help="Run the analytic parse controls and exit")
    parser.add_argument("--batch-invariance", action="store_true",
                        help="Also time binary A at twice the batch and require the "
                             "per-call cost to agree; catches a factor-of-batch error")
    parser.add_argument("--control-only", action="store_true",
                        help="Run the instrument controls (checksums, byte identity, "
                             "provenance, batch invariance) and skip the sample loop. "
                             "Implies --batch-invariance. Produces no timing table.")
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    if not args.a or not args.b:
        parser.error("--a and --b are required unless --selftest is given")
    if args.control_only:
        # A control run has no timing table, so the only thing it can assert is
        # the invariance of the instrument.
        args.batch_invariance = True

    if args.samples < MIN_SAMPLES:
        raise SystemExit(f"--samples must be at least {MIN_SAMPLES}; fewer is not a measurement")
    if args.warmup < MIN_WARMUP:
        raise SystemExit(f"--warmup must be at least {MIN_WARMUP}")

    a_bin = args.a.resolve()
    b_bin = args.b.resolve()
    # A comparator may need a mode word before the timing arguments. The two
    # binaries are allowed different ones so a contract-adapted column can be
    # measured against the same rows.
    a_prefix = tuple(args.a_args.split())
    b_prefix = tuple(args.b_args.split())
    for binary in (a_bin, b_bin):
        if not binary.exists():
            raise SystemExit(f"{binary} is missing")

    out = args.out or (ROOT / ".build" / "bench" / f"{args.label}.json")
    out.parent.mkdir(parents=True, exist_ok=True)

    # 0. Build provenance. A difference between two binaries built by different
    #    compilers is not a difference between libraries, so this is checked
    #    before any time is spent measuring.
    #
    #    The binary identity is captured *now* and again at the end. A rebuild
    #    during the run would otherwise be invisible: the functional checksums
    #    would still agree, because they describe the workload, not the code that
    #    ran it. The sidecar must also describe the binary on disk, or the
    #    provenance being reported belongs to some other build.
    a_sha_start = sha256_file(a_bin)
    b_sha_start = sha256_file(b_bin)
    a_record = provenance.read(a_bin)
    b_record = provenance.read(b_bin)
    build = provenance.compare(a_record, b_record)
    identity = {
        "a_start": a_sha_start,
        "b_start": b_sha_start,
        "a_sidecar_matches": provenance.sidecar_matches(a_bin, a_record),
        "b_sidecar_matches": provenance.sidecar_matches(b_bin, b_record),
        "a_sources_unchanged": provenance.sources_unchanged(a_record),
        "b_sources_unchanged": provenance.sources_unchanged(b_record),
    }
    if build.get("records_present") and not build["compiler_identical"]:
        message = (f"compiler mismatch: A was built by {build['compiler_a']['version']} "
                   f"({build['compiler_a']['path']}), B by "
                   f"{build['compiler_b']['version']} ({build['compiler_b']['path']}). "
                   f"A difference between these binaries cannot be attributed to the "
                   f"library.")
        if not args.allow_compiler_mismatch:
            raise SystemExit(message + " Pass --allow-compiler-mismatch to measure "
                                       "anyway, labelled confounded.")
        print("WARNING: " + message)
        print("WARNING: this run is confounded; it is not evidence about the library.")

    # 1. Contention, before anything is timed.
    before = None if args.skip_contention else contention(
        args.cpu, out.with_suffix(".contention-before.json"))
    if before and args.cpu is None:
        args.cpu = before["environment"]["chosen_cpu"]
    cpu = args.cpu

    # 2. Fixtures: both binaries must encode the same bytes, and those bytes
    #    must be the ones bench/fixtures.py predicts.
    expected = {row["name"]: row for row in fixtures.expected()}
    a_verify = parse_verify(run(a_bin, "verify", cpu=cpu))
    b_verify = parse_verify(run(b_bin, "verify", cpu=cpu))
    for label, rows in (("A", a_verify), ("B", b_verify)):
        valid = {k: v for k, v in rows.items() if "/" not in k}
        if set(valid) != set(expected):
            raise SystemExit(f"{label} fixture names differ: {sorted(valid)} vs {sorted(expected)}")
        for name, row in expected.items():
            if len(valid[name]) != row["bytes"] or hashlib.sha256(valid[name]).hexdigest() != row["sha256"]:
                raise SystemExit(f"{label} {name}: bytes disagree with bench/fixtures.py")
    if a_verify != b_verify:
        differing = sorted(k for k in set(a_verify) | set(b_verify)
                           if a_verify.get(k) != b_verify.get(k))
        raise SystemExit("A and B do not measure the same inputs; the workloads are not "
                         f"the same. Differing rows: {differing[:8]}")

    # 3. Checksums, before the timing passes.
    a_sums, a_na = parse_checksum(run(a_bin, "checksum", cpu=cpu))
    b_sums, b_na = parse_checksum(run(b_bin, "checksum", cpu=cpu))
    if args.same_library and a_sums != b_sums:
        differing = sorted(k for k in set(a_sums) | set(b_sums) if a_sums.get(k) != b_sums.get(k))
        raise SystemExit(f"--same-library but checksums differ on {differing[:8]}")

    # Across implementations the encode rows *should* agree, because the same
    # value encodes to the same bytes and both harnesses hash those bytes. But a
    # third-party harness may fold differently (a word-wise hash instead of a
    # byte-wise FNV), and then equal bytes produce unequal checksums. The hard
    # gate for "same workload" is the byte-identity check in step 2, which is
    # strictly stronger than a checksum comparison; this one is recorded, not
    # enforced, so a harness difference cannot masquerade as a workload
    # difference.
    encode_keys = [k for k in sorted(a_sums) if k[1].startswith("encode")]
    encode_disagreements = [k for k in encode_keys if a_sums.get(k) != b_sums.get(k)]

    # 4. Warmup, then paired samples with alternating order.
    for _ in range(args.warmup):
        run(a_bin, *a_prefix, str(args.batch), str(args.ms), cpu=cpu)
        run(b_bin, *b_prefix, str(args.batch), str(args.ms), cpu=cpu)

    # Batch invariance: the same work timed with twice the batch must cost the
    # same per call. A parser that divides by the batch, or a binary that prints
    # a rate next to the batch, breaks this by a factor of two or more.
    #
    # A fixed threshold is the wrong gate: on a loaded host the between-batch
    # difference reaches tens of percent on its own, so a 10% rule refuses a
    # correct instrument, and a loose rule would miss a real factor error. The
    # gate is therefore calibrated against the noise it actually saw: each batch
    # is timed PASSES times, the spread of those passes is the noise floor for
    # that row, and the between-batch difference must stay within a small
    # multiple of it. See `invariance_verdict` for the rule and its controls.
    invariance = None
    if args.batch_invariance:
        passes_per_batch = 5

        def passes_at(batch: int) -> dict[tuple[str, str], list[float]]:
            runs = [parse_time(run(a_bin, *a_prefix, str(batch), str(args.ms), cpu=cpu))
                    for _ in range(passes_per_batch)]
            keys = set(runs[0])
            return {k: [r[k] for r in runs] for k in keys if all(k in r for r in runs)}

        small = passes_at(args.batch)
        large = passes_at(args.batch * 2)

        rows = {}
        worst = 0.0
        worst_row = None
        for key in sorted(small):
            if key not in large:
                continue
            verdict = invariance_verdict(small[key], large[key])
            rows["/".join(key)] = verdict
            if verdict["delta"] > worst:
                worst, worst_row = verdict["delta"], key
        statuses = {r["status"] for r in rows.values()}
        if "fail" in statuses:
            overall = "fail"
        elif "inconclusive" in statuses:
            overall = "inconclusive"
        elif statuses == {"ok"}:
            overall = "ok"
        else:
            overall = "inconclusive"
        invariance = {
            "batch": args.batch,
            "batch_doubled": args.batch * 2,
            "passes_per_batch": passes_per_batch,
            "worst_relative_delta": worst,
            "worst_row": list(worst_row) if worst_row else None,
            "rule": ("fail if delta >= 0.50; inconclusive if within-batch spread > 0.15; "
                     "else ok if delta <= max(0.10, 2 * spread)"),
            "status": overall,
            "ok": overall == "ok",
            "rows": rows,
        }

    samples: dict[str, dict[tuple[str, str], list[float]]] = {"A": {}, "B": {}}
    rss: dict[str, list[int]] = {"A": [], "B": []}
    for index in range(0 if args.control_only else args.samples):
        order = (("A", a_bin), ("B", b_bin)) if index % 2 == 0 else (("B", b_bin), ("A", a_bin))
        for label, binary in order:
            prefix = a_prefix if binary == a_bin else b_prefix
            text, peak = run_measured(binary, (*prefix, str(args.batch), str(args.ms)), cpu)
            rss[label].append(peak)
            for key, ns_per_call in parse_time(text).items():
                samples[label].setdefault(key, []).append(ns_per_call)
        if (index + 1) % 5 == 0:
            print(f"  {index + 1}/{args.samples} samples")

    # 5. Checksums again: the numbers must describe the code that produced them.
    if parse_checksum(run(a_bin, "checksum", cpu=cpu)) != (a_sums, a_na):
        raise SystemExit("A: content checksums changed during the run")
    if parse_checksum(run(b_bin, "checksum", cpu=cpu)) != (b_sums, b_na):
        raise SystemExit("B: content checksums changed during the run")

    # 5b. The binaries and their sources must be the same files they were at the
    #     start. A rebuild mid-run would otherwise be invisible: the functional
    #     checksums describe the workload, not the code that produced the times.
    identity["a_end"] = sha256_file(a_bin)
    identity["b_end"] = sha256_file(b_bin)
    identity["a_unchanged"] = identity["a_end"] == a_sha_start
    identity["b_unchanged"] = identity["b_end"] == b_sha_start
    identity["a_sources_unchanged"] = provenance.sources_unchanged(a_record)
    identity["b_sources_unchanged"] = provenance.sources_unchanged(b_record)
    if not (identity["a_unchanged"] and identity["b_unchanged"]):
        raise SystemExit(
            "a binary changed during the run: "
            f"A {a_sha_start[:12]} -> {identity['a_end'][:12]}, "
            f"B {b_sha_start[:12]} -> {identity['b_end'][:12]}. "
            "The times do not describe one build.")

    after = None if args.skip_contention else contention(
        args.cpu, out.with_suffix(".contention-after.json"))

    # 6. Rows.
    a_keys = set(samples["A"])
    b_keys = set(samples["B"])
    if b_keys - a_keys:
        raise SystemExit(f"B timed rows A did not: {sorted(b_keys - a_keys)}")
    undeclared = (a_keys - b_keys) - b_na
    if undeclared:
        raise SystemExit(f"B silently omitted rows: {sorted(undeclared)}")
    for label in samples:
        for key, values in samples[label].items():
            if len(values) != args.samples:
                raise SystemExit(f"{label} {key}: {len(values)} samples, expected {args.samples}")

    rows = []
    for key in sorted(a_keys):
        a_values = samples["A"][key]
        applicable = key in b_keys
        b_values = samples["B"][key] if applicable else None
        row = {
            "fixture": key[0],
            "operation": key[1],
            "a": dispersion(a_values),
            "b": dispersion(b_values) if applicable else None,
            "b_applicable": applicable,
            "a_checksum": a_sums.get(key),
            "b_checksum": b_sums.get(key),
        }
        if applicable:
            row["ratio"] = bootstrap_ratio(a_values, b_values, args.seed)
        rows.append(row)

    # 7. Gates.
    gates = {}
    if before and after:
        gates["contention_before"] = before["verdict"]
        gates["contention_after"] = after["verdict"]
        gates["contention_admissible"] = (before["verdict"] == "admissible"
                                          and after["verdict"] == "admissible")
    else:
        gates["contention_admissible"] = False
    if args.same_library:
        gates["checksums_identical"] = a_sums == b_sums
    gates["fixtures_byte_identical"] = a_verify == b_verify
    # A run without build records cannot be attributed to anything, so it is not
    # admissible. The records must also describe the binaries that were measured,
    # and those binaries and their sources must not have changed mid-run.
    gates["records_present"] = bool(build.get("records_present"))
    gates["sidecar_matches_binary"] = bool(identity["a_sidecar_matches"]
                                           and identity["b_sidecar_matches"])
    gates["binary_unchanged"] = bool(identity["a_unchanged"] and identity["b_unchanged"])
    gates["sources_unchanged"] = bool(identity["a_sources_unchanged"]
                                      and identity["b_sources_unchanged"])
    if build.get("records_present"):
        gates["compiler_identical"] = build["compiler_identical"]
        gates["flags_identical"] = build["flags_identical"]
        gates["goose_identical"] = build["goose_identical"]
        gates["runtime_headers_identical"] = build["runtime_headers_identical"]
        gates["linked_libraries_identical"] = build["linked_libraries_identical"]
    gates["encode_checksums_agree"] = not encode_disagreements
    if invariance is not None:
        gates["batch_invariance"] = invariance["ok"]
    if args.self_control:
        straddling = [f"{r['fixture']}/{r['operation']}" for r in rows
                      if r["b_applicable"] and not (r["ratio"]["low"] <= 1.0 <= r["ratio"]["high"])]
        gates["self_control_ok"] = not straddling
        gates["self_control_failures"] = straddling
    # `encode_checksums_agree` is informational: a third-party harness that folds
    # differently reports unequal checksums over equal bytes, and the byte
    # identity gate above already covers the workload. It is excluded from the
    # pass/fail roll-up so a harness difference cannot fail the run.
    INFORMATIONAL = {"encode_checksums_agree"}
    gates["all_passed"] = all(v for k, v in gates.items()
                              if isinstance(v, bool) and k not in INFORMATIONAL)

    report = {
        "schema": 1,
        "label": args.label,
        "a": {"path": str(a_bin), "sha256": a_sha_start},
        "b": {"path": str(b_bin), "sha256": b_sha_start},
        "identity": identity,
        "samples": args.samples,
        "control_only": args.control_only,
        "warmup": args.warmup,
        "batch": args.batch,
        "window_ms": args.ms,
        "cpu": cpu,
        "same_library": args.same_library,
        "self_control": args.self_control,
        "fixtures": {"table_sha256": fixtures.table_digest(),
                     "rows": [{"name": n, "bytes": len(d), "sha256": hashlib.sha256(d).hexdigest()}
                              for n, d in a_verify.items()]},
        "peak_rss_kib": {label: ({"max": max(v), "min": min(v), "raw": v} if v else None)
                         for label, v in rss.items()},
        "batch_invariance": invariance,
        "contention_before": before,
        "contention_after": after,
        "gates": gates,
        "verdict": "admissible" if gates["all_passed"] else "exploratory",
        "rows": rows,
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "cpu_count": os.cpu_count(),
            "affinity": sorted(os.sched_getaffinity(0)),
            "kernel": platform.release(),
            "cpu_model": cpu_model(),
        },
        # The build provenance of both binaries: the compiler that compiled the
        # code under measurement, its version and hash, the flags, the source
        # hashes, the runtime headers and the linked libraries. A comparison
        # without this is a comparison of two opaque files.
        "build": build,
        "build_records": {"a": a_record, "b": b_record},
    }
    out.write_text(json.dumps(report, indent=2) + "\n")

    md = render(report)
    out.with_suffix(".md").write_text(md)
    print(md)
    print(f"wrote {out} and {out.with_suffix('.md')}")
    return 0 if gates["all_passed"] else 1


def render(report: dict) -> str:
    a_name = Path(report["a"]["path"]).name
    b_name = Path(report["b"]["path"]).name
    lines = [
        f"# Paired measurement — {report['label']}",
        "",
        f"A = `{a_name}` ({report['a']['sha256'][:16]}), "
        f"B = `{b_name}` ({report['b']['sha256'][:16]}).",
        f"{report['samples']} paired samples after {report['warmup']} discarded warmup passes, "
        f"batch {report['batch']}, window {report['window_ms']} ms, alternating order, "
        f"pinned to CPU {report['cpu']}. Values are ns/op.",
        "",
        f"Verdict: **{report['verdict']}**.",
        "",
        "| fixture | operation | A median | B median | B/A | 95% interval | A p90 | B p90 |",
        "|---|---|---:|---:|---:|---|---:|---:|",
    ]
    for row in report["rows"]:
        a = row["a"]
        if not row["b_applicable"]:
            lines.append(f"| {row['fixture']} | {row['operation']} | {a['median']:.1f} | n/a | n/a | n/a | {a['p90']:.1f} | n/a |")
            continue
        b = row["b"]
        ratio = row["ratio"]
        lines.append(
            f"| {row['fixture']} | {row['operation']} | {a['median']:.1f} | {b['median']:.1f} | "
            f"{ratio['point']:.3f} | [{ratio['low']:.3f}, {ratio['high']:.3f}] | "
            f"{a['p90']:.1f} | {b['p90']:.1f} |"
        )
    rss = report["peak_rss_kib"]
    noisy = [(r["fixture"], r["operation"], "A", r["a"]["outliers"]) for r in report["rows"] if r["a"]["outliers"]]
    noisy += [(r["fixture"], r["operation"], "B", r["b"]["outliers"])
              for r in report["rows"] if r["b_applicable"] and r["b"]["outliers"]]
    if rss["A"] and rss["B"]:
        lines += ["", f"Peak RSS: A {rss['A']['max']} KiB, B {rss['B']['max']} KiB.", ""]
    if noisy:
        lines += ["Samples more than 3 MAD from their own median (kept, not trimmed):", ""]
        for fixture, operation, side, indices in noisy:
            lines.append(f"- `{fixture}/{operation}` {side}: samples {indices}")
        lines.append("")
    lines += [
        "## Gates",
        "",
        "```json",
        json.dumps(report["gates"], indent=2),
        "```",
        "",
    ]
    inv = report.get("batch_invariance")
    if inv:
        lines += [
            "## Batch invariance",
            "",
            f"Batch {inv['batch']} vs {inv['batch_doubled']}, {inv['passes_per_batch']} passes each. "
            f"Status: **{inv['status']}**. Rule: `{inv['rule']}`.",
            "",
            "| Row | ns/call @small | ns/call @large | delta | noise | allowed | status |",
            "|---|---:|---:|---:|---:|---:|---|",
        ]
        for name, r in inv["rows"].items():
            lines.append(
                f"| {name} | {r['small_ns']:.1f} | {r['large_ns']:.1f} | "
                f"{r['delta']:.3f} | {r['noise']:.3f} | {r['allowed']:.3f} | "
                f"{r['status']} |"
            )
        lines.append("")
    lines += [
        "## Contention",
        "",
        "```json",
        json.dumps({
            "before": (report["contention_before"] or {}).get("verdict"),
            "after": (report["contention_after"] or {}).get("verdict"),
            "checks_before": (report["contention_before"] or {}).get("checks"),
            "legacy_gate_before": (report["contention_before"] or {}).get("legacy_gate"),
        }, indent=2),
        "```",
        "",
    ]
    return "\n".join(lines)


if __name__ == "__main__":
    sys.exit(main())
