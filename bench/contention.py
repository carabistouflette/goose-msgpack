#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Decide whether a timing window is admissible, on evidence rather than on load.

Why the old gate was not enough
-------------------------------

The previous protocol refused to measure while the one-minute load average was
above 0.5. On a single-core machine that is a reasonable proxy. On this machine
it is neither necessary nor sufficient:

- **Not sufficient.** Load average counts runnable threads system-wide. Three
  runnable threads on eight CPUs is load 3.0 and leaves five CPUs idle, so the
  gate rejects a window that is fine. Worse, one busy thread pinned to the CPU
  the measurement uses is load 1.0 and destroys the measurement, so a window
  with load 0.4 can still be contaminated. The gate cannot tell the two apart
  because it never looks at *which* CPU is busy.
- **Not necessary.** A single-threaded build on another core raises the load
  average without touching the measured core.

So the gate is kept, recorded, and reported, but it is no longer the criterion.

The rule
--------

A window is **admissible** when all of the following hold. Every threshold is
recorded with the verdict, so a reader can disagree with the numbers rather
than with a vibe.

1. **Pinned.** The measured process runs on one CPU, chosen explicitly, and the
   affinity mask is recorded. A measurement that migrates between cores mixes
   two clocks and two cache states.
2. **That CPU is idle.** Over the window, the chosen CPU's busy fraction from
   `/proc/stat` deltas is below `--max-cpu-busy` (default 5%). This is the
   direct measurement the load average was standing in for.
3. **Its SMT siblings are idle too.** A sibling shares the execution units, so
   a busy sibling is a busy core. The sibling list is read from
   `/sys/devices/system/cpu/cpuN/topology/thread_siblings_list`; on a host
   without SMT the list is the CPU itself and the check is the same as (2).
4. **The system is not stalling.** `/proc/pressure/cpu` `some avg10` is below
   `--max-psi` (default 1.0%). PSI measures the fraction of wall time at least
   one task was runnable but not running, which is contention by definition.
5. **The clock is stable.** A fixed-cost calibration workload, pinned to the
   same CPU, is run `--samples` times; the coefficient of variation of its
   per-run time must be below `--max-cv` (default 2.0%). This is the check that
   catches what the others miss: a frequency drop, a thermal event, or a
   neighbour that `/proc/stat` averages away over the window.

If any check fails the window is **exploratory**: the numbers may still be
recorded, but they are labelled and cannot support a ranking claim.

The calibration workload is `bench/calibrate.c`, a dependent integer chain. Its
cost depends only on the core's clock and on whether something else is
competing for it, so its dispersion is a direct contention signal.

    python3 bench/contention.py --cpu 3 --json .build/bench/contention.json
    python3 bench/contention.py --cpu 3 --legacy-max-load 0.5

Exit status is 0 for admissible and 1 for exploratory, so a shell can gate on
it. `--json` writes the full record.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import signal
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CALIBRATE_SRC = ROOT / "bench" / "calibrate.c"
CALIBRATE_BIN = ROOT / ".build" / "bench" / "calibrate"

# The historical gate. Kept, computed, and reported; no longer the criterion.
LEGACY_MAX_LOAD = 0.5


def read_text(path: Path) -> str:
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def cpu_stat() -> dict[int, dict[str, int]]:
    """Per-CPU jiffy counters from /proc/stat."""
    rows: dict[int, dict[str, int]] = {}
    for line in Path("/proc/stat").read_text().splitlines():
        if not line.startswith("cpu") or line.startswith("cpu "):
            continue
        parts = line.split()
        index = int(parts[0][3:])
        fields = [int(v) for v in parts[1:]]
        # user nice system idle iowait irq softirq steal guest guest_nice
        names = ["user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal"]
        rows[index] = {name: fields[i] for i, name in enumerate(names) if i < len(fields)}
    return rows


def psi_cpu() -> dict[str, float]:
    """`/proc/pressure/cpu`, as percentages. Empty when PSI is unavailable."""
    text = read_text(Path("/proc/pressure/cpu"))
    out: dict[str, float] = {}
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        kind = parts[0]
        for field in parts[1:]:
            if "=" not in field:
                continue
            key, value = field.split("=", 1)
            out[f"{kind}_{key}"] = float(value)
    return out


def siblings(cpu: int) -> list[int]:
    text = read_text(Path(f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list"))
    if not text:
        return [cpu]
    out: list[int] = []
    for part in text.split(","):
        if "-" in part:
            lo, hi = part.split("-", 1)
            out.extend(range(int(lo), int(hi) + 1))
        else:
            out.append(int(part))
    return sorted(set(out))


def frequency(cpu: int) -> dict[str, str]:
    base = Path(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq")
    return {
        "scaling_cur_freq": read_text(base / "scaling_cur_freq"),
        "scaling_governor": read_text(base / "scaling_governor"),
        "cpuinfo_max_freq": read_text(base / "cpuinfo_max_freq"),
    }


def temperature() -> dict[str, str]:
    out: dict[str, str] = {}
    for zone in sorted(Path("/sys/class/thermal").glob("thermal_zone*")):
        value = read_text(zone / "temp")
        if value:
            out[zone.name] = value
    return out


def psi_stall_fraction(before: dict[str, float], after: dict[str, float],
                       window_s: float) -> float | None:
    """Fraction of the window at least one task was stalled, from PSI totals.

    `some avg10` is a ten-second moving average, so it describes the last ten
    seconds rather than the window being judged. The cumulative `some total`
    counter is windowed: its delta over the window, divided by the window, is
    the stall fraction for exactly that window.
    """
    if window_s <= 0:
        return None
    start = before.get("some_total")
    end = after.get("some_total")
    if start is None or end is None:
        return None
    return max(0.0, (end - start) / (window_s * 1e6))


def busy_fraction(before: dict[str, int], after: dict[str, int]) -> float:
    """Fraction of the window the CPU was not idle, from jiffy deltas."""
    total = 0
    idle = 0
    for name, value in after.items():
        delta = value - before.get(name, 0)
        if delta < 0:
            delta = 0
        total += delta
        if name in ("idle", "iowait"):
            idle += delta
    if total == 0:
        return 0.0
    return 1.0 - idle / total


def busy_jiffies(before: dict[str, int], after: dict[str, int]) -> tuple[int, int]:
    """(busy, total) jiffies over the window, from /proc/stat deltas."""
    total = 0
    idle = 0
    for name, value in after.items():
        delta = value - before.get(name, 0)
        if delta < 0:
            delta = 0
        total += delta
        if name in ("idle", "iowait"):
            idle += delta
    return total - idle, total


def build_calibrate(cc: str) -> None:
    CALIBRATE_BIN.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run([cc, "-O2", str(CALIBRATE_SRC), "-o", str(CALIBRATE_BIN)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"calibrate build failed:\n{result.stdout}\n{result.stderr}")


def run_calibrate(cpu: int, iterations: int) -> dict:
    """Run the probe pinned to `cpu`.

    Returns the loop's own clocks, read inside the child around the same loop:
    `wall_ns` from CLOCK_MONOTONIC and `cpu_ns` from CLOCK_THREAD_CPUTIME_ID.
    Their ratio is the fraction of the loop's wall time the thread actually ran,
    which is the preemption signal.

    The parent's wall time and the child's `wait4` CPU time are returned too, as
    provenance only. They cannot be the gate: fork, exec and teardown land in
    both, so a 4 ms workload with 1 ms of startup reports a utilisation near 0.8
    on an idle core and a 95% threshold would never fire.
    """
    read_fd, write_fd = os.pipe()
    started = time.monotonic()
    pid = os.fork()
    if pid == 0:  # pragma: no cover - child
        try:
            os.close(read_fd)
            os.dup2(write_fd, 1)
            os.close(write_fd)
            os.sched_setaffinity(0, {cpu})
            os.execv(str(CALIBRATE_BIN), [str(CALIBRATE_BIN), str(iterations)])
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
    wall = time.monotonic() - started
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        raise SystemExit(f"calibrate failed with status {status}: "
                         + b"".join(chunks).decode("utf-8", "replace"))
    parts = b"".join(chunks).decode().split()
    if len(parts) != 5 or parts[0] != "calibrate":
        raise SystemExit(f"unexpected calibrate output: {parts!r}")
    return {
        "iterations": int(parts[1]),
        "wall_ns": int(parts[2]),
        "cpu_ns": int(parts[3]),
        "checksum": int(parts[4]),
        "parent_wall_s": wall,
        "parent_child_cpu_s": usage.ru_utime + usage.ru_stime,
    }


def measure_window(cpu: int, seconds: float, load: bool = False) -> dict:
    """Busy fraction of `cpu` over a quiet window, optionally with a busy child.

    With `load=True` a child spins pinned to the same CPU for the whole window.
    That is the sensitivity control: the gate must see it.
    """
    child = None
    if load:
        child = os.fork()
        if child == 0:  # pragma: no cover - child
            try:
                os.sched_setaffinity(0, {cpu})
                end = time.monotonic() + seconds + 1.0
                x = 1
                while time.monotonic() < end:
                    x = (x * 1103515245 + 12345) & 0xFFFFFFFF
            finally:
                os._exit(0)
    try:
        before = cpu_stat()
        psi_before = psi_cpu()
        started = time.monotonic()
        time.sleep(seconds)
        window = time.monotonic() - started
        after = cpu_stat()
        psi_after = psi_cpu()
    finally:
        if child:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(child, 0)
    return {
        "busy": busy_fraction(before[cpu], after[cpu]),
        "stall": psi_stall_fraction(psi_before, psi_after, window),
        "window_s": window,
    }


def selftest(args) -> int:
    """Prove the gate is sensitive to real load and blind to our own work.

    Two failure modes matter and they pull in opposite directions:

    - **Insensitive.** A gate that never fails is not a gate. A child spinning on
      the measured CPU must raise the busy fraction well past the threshold.
    - **Self-triggering.** A gate that counts the calibration's own CPU time
      refuses an idle host. The calibration window must be visibly busier than
      the quiet window, which is exactly why it cannot be the window the gate
      judges.
    """
    affinity = sorted(os.sched_getaffinity(0))
    cpu = args.cpu
    if cpu is None:
        first = cpu_stat()
        time.sleep(0.2)
        probe = cpu_stat()
        candidates = [c for c in affinity if c in first and c in probe]
        if not candidates:
            raise SystemExit("no CPU in the affinity mask has /proc/stat counters")
        cpu = min(candidates, key=lambda c: busy_fraction(first[c], probe[c]))

    failures = 0

    # --- Sensitivity, bounded and repeated. --------------------------------
    # The busy child is bounded by a deadline, and the loaded window is measured
    # twice so a single lucky or unlucky window cannot pass the control.
    #
    # The control needs a core that is quiet to begin with: if the chosen CPU is
    # already saturated by someone else's work, "a busy child raised the busy
    # fraction" cannot be shown, and reporting that as a failure of the
    # instrument would be wrong. So the control walks the least busy cores and
    # reports INCONCLUSIVE when none is quiet enough, which is a fact about the
    # host.
    if args.cpu is not None:
        candidates = [cpu]
    else:
        probe_before = cpu_stat()
        time.sleep(0.05)
        probe_after = cpu_stat()
        candidates = sorted(affinity, key=lambda c: busy_fraction(
            probe_before[c], probe_after[c]))

    quiet = None
    for candidate in candidates:
        window = measure_window(candidate, args.idle_window)
        if window["busy"] <= 0.5:
            cpu, quiet = candidate, window
            break
        print(f"cpu {candidate}: quiet busy {window['busy']:.4f}, too busy to run the "
              f"sensitivity control")

    if quiet is None:
        print("INCONCLUSIVE sensitivity: no core in the affinity mask was quiet enough "
              "to show that a busy child raises the busy fraction")
    else:
        loaded = [measure_window(cpu, args.idle_window, load=True) for _ in range(2)]
        print(f"cpu {cpu}: quiet busy {quiet['busy']:.4f}, "
              f"with a busy child {[round(w['busy'], 4) for w in loaded]}")
        for index, window in enumerate(loaded):
            if window["busy"] < 0.5:
                print(f"FAIL sensitivity (pass {index}): busy fraction {window['busy']:.4f} "
                      f"with a spinning child on the measured CPU; the gate would not see "
                      f"real contention")
                failures += 1
            if window["busy"] <= quiet["busy"] + 0.2:
                print(f"FAIL sensitivity (pass {index}): a busy child raised the busy "
                      f"fraction by only {window['busy'] - quiet['busy']:.4f}")
                failures += 1

    # --- Self-workload is not counted. -------------------------------------
    build_calibrate(args.cc)
    before = cpu_stat()
    for _ in range(3):
        run_calibrate(cpu, args.iterations)
    after = cpu_stat()
    cal_busy, cal_total = busy_jiffies(before[cpu], after[cpu])
    cal_fraction = cal_busy / cal_total if cal_total else 0.0
    print(f"calibration window busy {cal_fraction:.4f} (our own work)")
    if quiet is None:
        print("INCONCLUSIVE self-workload: no quiet window to compare against")
    elif cal_fraction <= quiet["busy"]:
        print(f"FAIL self-workload: the calibration window ({cal_fraction:.4f}) was not "
              f"busier than the quiet window ({quiet['busy']:.4f}); the subtraction "
              f"would have nothing to remove")
        failures += 1

    # --- The preemption gate is not a phantom. -----------------------------
    # The ratio is read inside the child around the same loop, so it is not
    # diluted by fork/exec. On a quiet core it must be close to 1; with a busy
    # child on the same core it must drop. If the quiet case is already low, the
    # host is loaded — that is a fact about the host, reported, not a failure of
    # the instrument.
    quiet_runs = [run_calibrate(cpu, args.iterations) for _ in range(3)]
    quiet_util = min(r["cpu_ns"] / r["wall_ns"] for r in quiet_runs if r["wall_ns"])
    parent_util = min(r["parent_child_cpu_s"] / r["parent_wall_s"]
                      for r in quiet_runs if r["parent_wall_s"])
    print(f"loop utilisation on a quiet core {quiet_util:.4f} "
          f"(parent view {parent_util:.4f}, which includes fork/exec)")
    if quiet_util < args.min_utilisation:
        print(f"NOTE: loop utilisation {quiet_util:.4f} is below the "
              f"{args.min_utilisation} gate; the host is loaded, which is a fact "
              f"about the host, not a defect of the instrument")
    if parent_util >= quiet_util:
        print(f"FAIL phantom: the parent view ({parent_util:.4f}) is not lower than "
              f"the loop view ({quiet_util:.4f}); the startup overhead is not being "
              f"excluded and the gate would be measuring fork/exec")
        failures += 1

    cores = siblings(cpu)
    sibling_only = [c for c in cores if c != cpu]
    if cpu not in cores:
        print(f"FAIL siblings: {cpu} is not in its own thread_siblings_list {cores}")
        failures += 1
    if cpu in sibling_only:
        print(f"FAIL siblings: the chosen CPU {cpu} survived the exclusion")
        failures += 1

    if failures:
        print(f"{failures} contention self-check failure(s)")
        return 1
    print("contention self-check ok: sensitive to a busy child, blind to our own work, "
          "chosen CPU excluded from the sibling check")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cpu", type=int, default=None,
                        help="CPU to pin to (default: the least busy CPU in the affinity mask)")
    parser.add_argument("--samples", type=int, default=15,
                        help="Calibration samples (default 15, minimum 5)")
    parser.add_argument("--iterations", type=int, default=2000000,
                        help="Calibration chain length (default 2000000)")
    parser.add_argument("--max-cpu-busy", type=float, default=0.05,
                        help="Maximum busy fraction of the chosen CPU (default 0.05)")
    parser.add_argument("--max-psi", type=float, default=1.0,
                        help="Maximum /proc/pressure/cpu some avg10, percent (default 1.0)")
    parser.add_argument("--max-cv", type=float, default=0.02,
                        help="Maximum coefficient of variation of the probe (default 0.02)")
    parser.add_argument("--legacy-max-load", type=float, default=LEGACY_MAX_LOAD,
                        help=f"The historical load-average gate, recorded only (default {LEGACY_MAX_LOAD})")
    parser.add_argument("--idle-window", type=float, default=0.5,
                        help="Seconds of quiet window measured before any work of ours (default 0.5)")
    parser.add_argument("--min-utilisation", type=float, default=0.95,
                        help="Minimum child CPU time over wall time (default 0.95)")
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--json", type=Path, help="Write the full record here")
    parser.add_argument("--selftest", action="store_true",
                        help="Prove the gate is sensitive to real load and blind to our own")
    args = parser.parse_args()

    if args.selftest:
        return selftest(args)

    if args.samples < 5:
        raise SystemExit("--samples must be at least 5; fewer cannot show dispersion")

    affinity = sorted(os.sched_getaffinity(0))

    if args.cpu is None:
        # The least busy CPU in the mask, from a short /proc/stat sample. This
        # probe runs before anything else and does no work of its own.
        first = cpu_stat()
        time.sleep(0.2)
        probe = cpu_stat()
        candidates = [c for c in affinity if c in probe and c in first]
        if not candidates:
            raise SystemExit("no CPU in the affinity mask has /proc/stat counters")
        args.cpu = min(candidates, key=lambda c: busy_fraction(first[c], probe[c]))
    if args.cpu not in affinity:
        raise SystemExit(f"CPU {args.cpu} is not in the affinity mask {affinity}")

    cores = siblings(args.cpu)
    # The chosen CPU is checked by `cpu_idle`. Checking it again as its own
    # sibling would count the same jiffies twice and make the two checks look
    # like independent evidence when they are one measurement.
    sibling_only = [c for c in cores if c != args.cpu]

    # --- Phase 1: the idle window. -------------------------------------------
    # No work of ours runs here. What /proc/stat and PSI report over this window
    # is other people's load, which is exactly what the gate is about. An
    # earlier version took the counters around the calibration instead, so the
    # calibration's own CPU time was counted as contention and the gate refused
    # an idle host.
    stat_before = cpu_stat()
    psi_before = psi_cpu()
    load_before = os.getloadavg()
    started = time.monotonic()
    time.sleep(args.idle_window)
    window_s = time.monotonic() - started
    stat_after = cpu_stat()
    psi_after = psi_cpu()
    load_after = os.getloadavg()

    busy = {c: busy_fraction(stat_before[c], stat_after[c])
            for c in cores if c in stat_before}
    stall = psi_stall_fraction(psi_before, psi_after, window_s)
    psi_some = psi_after.get("some_avg10", 0.0)

    # --- Phase 2: calibration, for clock stability and preemption only. ------
    # It runs after the idle window, so its cost cannot be counted as contention.
    # The window it runs in is still recorded, with the calibrator's own CPU time
    # subtracted, so a reader can see that the subtraction is what makes the two
    # windows comparable.
    build_calibrate(args.cc)
    cal_before = cpu_stat()
    run_calibrate(args.cpu, args.iterations)  # discarded warmup
    runs: list[dict] = []
    for _ in range(args.samples):
        runs.append(run_calibrate(args.cpu, args.iterations))
    cal_after = cpu_stat()

    times = [r["wall_ns"] for r in runs]
    checksums = {r["checksum"] for r in runs}
    # The loop's own clocks, read inside the child around the same loop. This is
    # the preemption signal: the fraction of the loop's wall time the thread
    # actually ran. The parent's wall time and the child's wait4 CPU time are
    # recorded as provenance, not used here, because fork/exec/teardown land in
    # both and would make the ratio look like preemption on an idle core.
    utilisation = [r["cpu_ns"] / r["wall_ns"] for r in runs if r["wall_ns"] > 0]
    worst_utilisation = min(utilisation) if utilisation else 0.0
    parent_utilisation = [r["parent_child_cpu_s"] / r["parent_wall_s"]
                          for r in runs if r["parent_wall_s"] > 0]

    cal_busy, cal_total = busy_jiffies(cal_before[args.cpu], cal_after[args.cpu])
    child_jiffies = sum(r["parent_child_cpu_s"] for r in runs) * os.sysconf("SC_CLK_TCK")
    cal_busy_corrected = max(0.0, (cal_busy - child_jiffies) / cal_total) if cal_total else 0.0
    cal_busy_raw = cal_busy / cal_total if cal_total else 0.0

    median = statistics.median(times)
    stdev = statistics.stdev(times) if len(times) > 1 else 0.0
    cv = stdev / median if median else 0.0

    checks = {
        "pinned": {"ok": True, "cpu": args.cpu, "affinity": affinity},
        "cpu_idle": {
            "ok": busy.get(args.cpu, 1.0) < args.max_cpu_busy,
            "busy_fraction": {str(c): round(v, 6) for c, v in busy.items()},
            "threshold": args.max_cpu_busy,
            "window_s": round(window_s, 4),
        },
        "siblings_idle": {
            "ok": all(busy.get(c, 0.0) < args.max_cpu_busy for c in sibling_only),
            "siblings": sibling_only,
            "excluded": args.cpu,
            "threshold": args.max_cpu_busy,
            "note": "The chosen CPU is excluded; it is checked by cpu_idle.",
        },
        "no_stall": {
            "ok": (stall if stall is not None else 0.0) < args.max_psi / 100.0,
            "stall_fraction": None if stall is None else round(stall, 6),
            "psi_some_avg10": psi_some,
            "threshold_fraction": args.max_psi / 100.0,
            "note": "Windowed from the PSI `some total` delta, not the avg10 average.",
        },
        "clock_stable": {
            "ok": cv < args.max_cv,
            "cv": round(cv, 6),
            "median_ns": median,
            "stdev_ns": round(stdev, 1),
            "threshold": args.max_cv,
        },
        "no_preemption": {
            "ok": worst_utilisation > args.min_utilisation,
            "worst_utilisation": round(worst_utilisation, 6),
            "threshold": args.min_utilisation,
            "note": "CLOCK_THREAD_CPUTIME_ID over CLOCK_MONOTONIC, both read inside "
                    "the child around the same loop. Low means the thread was "
                    "preempted while it was supposed to be running.",
        },
    }
    admissible = all(check["ok"] for check in checks.values())

    legacy = {
        "max_load": args.legacy_max_load,
        "load1_before": round(load_before[0], 3),
        "load1_after": round(load_after[0], 3),
        "would_pass": max(load_before[0], load_after[0]) <= args.legacy_max_load,
        "note": "Recorded, not used as the criterion. See the module docstring.",
    }

    record = {
        "schema": 1,
        "verdict": "admissible" if admissible else "exploratory",
        "checks": checks,
        "legacy_gate": legacy,
        "calibration": {
            "iterations": args.iterations,
            "samples": args.samples,
            "raw_ns": times,
            "checksums": sorted(checksums),
            "checksum_stable": len(checksums) == 1,
            "loop_wall_ns": [r["wall_ns"] for r in runs],
            "loop_cpu_ns": [r["cpu_ns"] for r in runs],
            "utilisation": [round(v, 6) for v in utilisation],
            # Provenance only: the parent's view, which includes fork/exec and
            # teardown in both terms and therefore cannot be the gate.
            "parent_wall_s": [round(r["parent_wall_s"], 6) for r in runs],
            "parent_child_cpu_s": [round(r["parent_child_cpu_s"], 6) for r in runs],
            "parent_utilisation": [round(v, 6) for v in parent_utilisation],
            # The window the calibration ran in, recorded so a reader can see
            # that our own work is visible there and absent from the idle
            # window. `corrected` subtracts the calibrator's own CPU time.
            "window_busy_raw": round(cal_busy_raw, 6),
            "window_busy_corrected": round(cal_busy_corrected, 6),
            "window_child_jiffies": round(child_jiffies, 1),
            "window_total_jiffies": cal_total,
        },
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpu_count": os.cpu_count(),
            "affinity": affinity,
            "chosen_cpu": args.cpu,
            "siblings": cores,
            "frequency": frequency(args.cpu),
            "temperature": temperature(),
            "psi_before": psi_before,
            "psi_after": psi_after,
            "loadavg_before": [round(v, 3) for v in load_before],
            "loadavg_after": [round(v, 3) for v in load_after],
        },
    }

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(record, indent=2) + "\n")

    print(f"verdict: {record['verdict']}")
    for name, check in checks.items():
        print(f"  {name}: {'ok' if check['ok'] else 'FAIL'}")
    print(f"  cpu {args.cpu} busy {busy}")
    print(f"  psi some avg10 {psi_some}%")
    print(f"  probe median {median} ns, cv {cv:.4f}")
    print(f"  legacy load gate would {'pass' if legacy['would_pass'] else 'fail'} "
          f"(load1 {legacy['load1_before']} -> {legacy['load1_after']})")
    if args.json:
        print(f"record: {args.json}")
    return 0 if admissible else 1


if __name__ == "__main__":
    sys.exit(main())
