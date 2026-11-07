#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build and run a bounded Clang/libFuzzer + ASan/UBSan campaign over the real
goose-msgpack API.

The target is tests/fuzz.goose: it calls msgpack::Reader and msgpack::Writer
and asserts the guarantees in docs/api.md. This script builds it, proves the
Goose assertion path reaches libFuzzer, then runs the campaign.

    python3 scripts/fuzz.py --goose /path/to/goose --seconds 120 --runs 100000

Everything it produces stays under .build/fuzz/: the generated C, the seeds,
the writable corpus, the logs, the coverage summary and any crash artifact.

Two negative controls are available and are part of the evidence, not of the
campaign:

    --self-test          the assertion bridge keeps the exact input
    --defect NAME        a defect injected into msgpack.goose is caught by the
                         sanitizer, or by a Goose assertion, and retained

`--defect` never touches the working tree: it copies the library into
.build/fuzz/defect-<name>/ and builds there.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".build" / "fuzz"

# Reproducible seeds. Each is a distinct libFuzzer -seed, so the two campaigns
# explore different orders over the same corpus.
SEEDS = [20261107, 20261108]

# Seed inputs: every marker family, the boundaries, and the malformed shapes
# the contract rejects. Written by content hash so the corpus is reproducible.
SAMPLES = [
    b"",
    b"\xc0",
    b"\x00",
    b"\x7f",
    b"\xff",
    b"\xcc\x80",
    b"\xcd\x01\x00",
    b"\xce\x00\x01\x00\x00",
    b"\xcf\xff\xff\xff\xff\xff\xff\xff\xff",
    b"\xd0\x80",
    b"\xd1\x80\x00",
    b"\xd2\x80\x00\x00\x00",
    b"\xd3\x80\x00\x00\x00\x00\x00\x00\x00",
    b"\xca\x3f\xc0\x00\x00",
    b"\xcb\x3f\xf8\x00\x00\x00\x00\x00\x00",
    b"\xcb\x7f\xf8\x00\x00\x00\x00\x00\x00",
    b"\xcb\xff\xf0\x00\x00\x00\x00\x00\x00",
    b"\xcb\x80\x00\x00\x00\x00\x00\x00\x00",
    b"\xa1a",
    b"\xa2\xc3\xa9",
    b"\xa1\xff",
    b"\xd9\x01a",
    b"\xda\x00\x01a",
    b"\xdb\x00\x00\x00\x01a",
    b"\xc4\x00",
    b"\xc4\x02\x00\xff",
    b"\xc5\x00\x02\x00\xff",
    b"\xc6\x00\x00\x00\x02\x00\xff",
    b"\xd4\x01\x7f",
    b"\xd5\xff\x01\x02",
    b"\xd6\x01\x01\x02\x03\x04",
    b"\xd7\x01\x01\x02\x03\x04\x05\x06\x07\x08",
    b"\xd8\x01" + bytes(range(16)),
    b"\xc7\x03\x05\x01\x02\x03",
    b"\xc8\x00\x03\x05\x01\x02\x03",
    b"\xc9\x00\x00\x00\x03\x05\x01\x02\x03",
    b"\x90",
    b"\x80",
    b"\x91\x01",
    b"\x92\x01\x02",
    b"\x81\xa1a\x01",
    b"\x91\x90",
    b"\x91\x91\x01",
    b"\xdc\x00\x02\x01\x02",
    b"\xdd\x00\x00\x00\x02\x01\x02",
    b"\xde\x00\x01\xa1a\x01",
    b"\xdf\x00\x00\x00\x01\xa1a\x01",
    b"\xc1",
    b"\x92\x01",
    b"\x01\x02",
    b"\xdd\xff\xff\xff\xff",
    b"\xdf\xff\xff\xff\xff",
    b"\xdb\xff\xff\xff\xff",
    b"\xc6\xff\xff\xff\xff",
    b"\xc9\xff\xff\xff\xff",
    b"\x91" * 40 + b"\x01",
    b"\x81" * 40 + b"\x01\x01",
    b"\xa0" * 8,
    b"\x92\xa1a\x92\x01\x02",
]

# Defects injected to prove the harness catches them. Each names the guarantee
# it breaks and what the run must produce. A defect that survives is a hole in
# the target, not a pass.
#
# `patches` are applied in order. A "goose" patch edits a copy of
# msgpack.goose; a "c" patch edits the generated C, which is the code the
# sanitizers actually instrument. `debug` selects the Goose build: with debug
# checks on, Goose's own bounds and overflow checks fire first, which is the
# configuration the campaign uses; a sanitizer control that Goose would catch
# itself is built without them so the sanitizer is the only thing left.
DEFECTS = {
    # The input budget is checked before any token is decoded.
    "no-input-budget": {
        "patches": [{"stage": "goose",
                     "find": "    if input.len > limits.max_input_bytes {\n        reader._error = Error.InputLimit;\n        return Error.InputLimit;\n    }\n",
                     "replace": ""}],
        "expect": "assert",
        "guarantee": "init rejects input.len > max_input_bytes",
    },
    # A str payload is validated before it becomes a token.
    "no-utf8-check": {
        "patches": [{"stage": "goose",
                     "find": "    if !valid_utf8(view) { return Token.Nil, fail(reader, Error.InvalidUtf8, start); }\n",
                     "replace": ""}],
        "expect": "assert",
        "guarantee": "the reader rejects a str payload that is not UTF-8",
    },
    # The output budget is checked before a byte is appended.
    "no-output-budget": {
        "patches": [{"stage": "goose",
                     "find": "    if size > writer._limits.max_output_bytes - writer._out.len {\n        return fail_w(writer, Error.OutputLimit);\n    }\n",
                     "replace": ""}],
        "expect": "assert",
        "guarantee": "the writer never appends past max_output_bytes",
    },
    # A declared container length is checked against the bytes that remain.
    "no-array-truncation": {
        "patches": [{"stage": "goose",
                     "find": "    if n > reader._input.len - reader._at { return Token.Nil, fail(reader, Error.Truncated, start); }\n",
                     "replace": ""}],
        "expect": "assert",
        "guarantee": "an array count the input cannot hold is Truncated, not a loop",
    },
    # The node budget is checked before every value.
    "no-node-budget": {
        "patches": [{"stage": "goose",
                     "find": "    if reader._nodes >= reader._limits.max_nodes { return Token.Nil, fail(reader, Error.NodeLimit, reader._at); }\n",
                     "replace": ""}],
        "expect": "assert",
        "guarantee": "the reader stops at max_nodes",
    },
    # The depth budget is checked before a container opens.
    "no-depth-budget": {
        "patches": [{"stage": "goose",
                     "find": "        if reader._depth >= reader._limits.max_depth {\n            return Token.Nil, fail(reader, Error.DepthLimit, start);\n        }\n",
                     "replace": ""}],
        "expect": "assert",
        "guarantee": "the reader stops at max_depth",
    },
    # The str budget is checked against the declared length before the payload.
    "no-str-budget": {
        "patches": [{"stage": "goose",
                     "find": "    if n > limit { return \"\", fail(reader, error, start); }\n",
                     "replace": ""}],
        "expect": "assert",
        "guarantee": "a declared str/bin length above its budget is rejected first",
    },
    # ASan control: remove the explicit length check *and* the bounds check the
    # compiler emitted, so the generated Goose code reads past the fuzzer's
    # heap buffer. Proves ASan instruments the generated code and that the
    # input is a real allocation with redzones.
    "asan-overread": {
        "patches": [
            {"stage": "goose",
             "find": "    if !need(reader, width) { return \"\", fail(reader, Error.Truncated, start); }\n",
             "replace": ""},
            {"stage": "c",
             "find": ("#define GS_IDX(i, n, f, l) \\\n"
                      "    ((uint64_t)(i) < (uint64_t)(n) ? (i) \\\n"
                      "                                   : (gs_idxfail((int64_t)(i), (n), (f), (l)), (int64_t)0))\n"),
             "replace": "#define GS_IDX(i, n, f, l) (i)\n"},
        ],
        "expect": "sanitizer",
        "guarantee": "a multi-byte field is read only inside the input",
    },
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], cwd: Path, env: dict, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, **kwargs)


def must(command: list[str], cwd: Path, env: dict) -> str:
    result = run(command, cwd, env)
    if result.returncode != 0:
        raise SystemExit("command failed: " + " ".join(command) + "\n" + result.stdout + result.stderr)
    return result.stdout


def write_seeds(directory: Path) -> list[dict]:
    directory.mkdir(parents=True, exist_ok=True)
    rows = []
    for data in SAMPLES:
        name = hashlib.sha256(data).hexdigest()
        path = directory / name
        path.write_bytes(data)
        rows.append({"name": name, "bytes": len(data), "sha256": name})
    return rows


def build(goose: Path, cc: str, env: dict, source_root: Path, work: Path,
          self_test: bool, patches: list[dict] | None = None, debug: bool = True) -> dict:
    """Generate the C for `source_root/tests/fuzz.goose` and link the fuzzer."""
    work.mkdir(parents=True, exist_ok=True)
    header = work / "msgpack-fuzz.h"
    generated = work / "msgpack-fuzz.c"
    flags = ["--standalone", "--no-bce"]
    if debug:
        flags.append("--debug")
    must([str(goose), str(source_root / "tests" / "fuzz.goose"), *flags,
          "--header", str(header), "-o", str(generated)], cwd=source_root, env=env)
    applied = []
    for patch in patches or []:
        if patch["stage"] != "c":
            continue
        text = generated.read_text()
        if patch["find"] not in text:
            raise SystemExit("generated-C defect anchor not found")
        generated.write_text(text.replace(patch["find"], patch["replace"], 1))
        applied.append(patch)
    instrument = ["-O1", "-g", "-fsanitize=fuzzer-no-link,address,undefined",
                  "-fno-sanitize-recover=all", "-fno-omit-frame-pointer"]
    obj = work / "msgpack-fuzz.o"
    must([cc, *instrument, "-D_Exit=goose_fuzz_exit", "-c", str(generated),
          "-o", str(obj)], cwd=source_root, env=env)
    link = [cc, "-O1", "-g", "-fsanitize=fuzzer,address,undefined",
            "-fno-sanitize-recover=all", "-fno-omit-frame-pointer",
            str(obj), str(source_root / "tests" / "fuzz.c"), "-I" + str(work),
            "-lm", "-ldl", "-lpthread"]
    binary = work / "msgpack-fuzzer"
    must([*link, "-o", str(binary)], cwd=source_root, env=env)
    result = {"binary": str(binary), "binary_sha256": sha256_file(binary),
              "generated_c": str(generated), "generated_c_sha256": sha256_file(generated),
              "header_sha256": sha256_file(header),
              "source_sha256": sha256_file(source_root / "msgpack.goose"),
              "target_sha256": sha256_file(source_root / "tests" / "fuzz.goose"),
              "driver_sha256": sha256_file(source_root / "tests" / "fuzz.c"),
              "debug": debug, "c_patches": len(applied),
              "sanitizers": "fuzzer,address,undefined",
              "instrument_flags": instrument,
              "link_flags": link[:-1],
              "cc": must([cc, "--version"], source_root, env).splitlines()[0]}
    if self_test:
        probe = work / "self-test"
        must([*link, "-DGOOSE_FUZZ_SELF_TEST=1", "-o", str(probe)], cwd=source_root, env=env)
        result["self_test_binary"] = str(probe)
        result["self_test_sha256"] = sha256_file(probe)
    return result


def assertion_self_test(work: Path, env: dict, binary: Path) -> dict:
    """Prove a Goose assertion becomes a libFuzzer crash with the input kept."""
    seeds = work / "self-test-seeds"
    seeds.mkdir(exist_ok=True)
    expected = b"libFuzzer Goose assertion bridge probe"
    (seeds / "input").write_bytes(expected)
    crash = work / "self-test-crash"
    crash.unlink(missing_ok=True)
    log = work / "self-test.log"
    with log.open("wb") as handle:
        result = subprocess.run([str(binary), str(seeds), "-runs=10", "-seed=1",
                                 "-exact_artifact_path=" + str(crash)],
                                cwd=ROOT, env=env, stdout=handle,
                                stderr=subprocess.STDOUT, timeout=120)
    text = log.read_text(errors="replace")
    kept = crash.is_file() and crash.read_bytes() == expected
    ok = result.returncode != 0 and kept and "assert failed" in text
    return {"ok": ok, "returncode": result.returncode, "artifact_kept": kept,
            "artifact_sha256": sha256_file(crash) if crash.is_file() else None,
            "expected_sha256": hashlib.sha256(expected).hexdigest(),
            "log": str(log), "log_tail": text[-2000:]}


def inject(source_root: Path, work: Path, name: str, defect: dict) -> Path:
    """Copy the library and apply the defect's Goose-source patches."""
    target = work / f"defect-{name}"
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    for entry in ("msgpack.goose", "tests", "examples", "bench"):
        source = source_root / entry
        if source.is_dir():
            shutil.copytree(source, target / entry,
                            ignore=shutil.ignore_patterns("__pycache__"))
        elif source.is_file():
            shutil.copy2(source, target / entry)
    path = target / "msgpack.goose"
    text = path.read_text()
    for patch in defect["patches"]:
        if patch["stage"] != "goose":
            continue
        if patch["find"] not in text:
            raise SystemExit(f"defect {name}: Goose anchor not found in msgpack.goose")
        text = text.replace(patch["find"], patch["replace"], 1)
    path.write_text(text)
    return target


def defect_control(goose: Path, cc: str, env: dict, name: str, defect: dict,
                   seconds: int, runs: int, seed: int, max_len: int) -> dict:
    """Build the defective library and show the campaign catches it."""
    work = WORK / "defects" / name
    work.mkdir(parents=True, exist_ok=True)
    root = inject(ROOT, work, name, defect)
    build_info = build(goose, cc, env, root, work, self_test=False,
                       patches=defect["patches"], debug=defect.get("debug", True))
    corpus = work / "corpus"
    corpus.mkdir(exist_ok=True)
    seeds = work / "seeds"
    write_seeds(seeds)
    artifacts = work / "artifacts"
    artifacts.mkdir(exist_ok=True)
    log = work / "run.log"
    command = [build_info["binary"], str(corpus), str(seeds),
               f"-max_len={max_len}", f"-max_total_time={seconds}",
               f"-runs={runs}", f"-seed={seed}", "-timeout=5",
               "-rss_limit_mb=1024", "-artifact_prefix=" + str(artifacts) + "/"]
    with log.open("wb") as handle:
        result = subprocess.run(command, cwd=root, env=env, stdout=handle,
                                stderr=subprocess.STDOUT, timeout=seconds + 300)
    text = log.read_text(errors="replace")
    # Goose prints "goose runtime error: assert failed"; UBSan prints
    # "<file>:<line>:<col>: runtime error: ...". Match the sanitizer form only,
    # so a Goose assertion is never counted as a sanitizer report.
    sanitizer = ("ERROR: AddressSanitizer" in text or "SUMMARY: AddressSanitizer" in text
                 or "UndefinedBehaviorSanitizer" in text
                 or re.search(r"\.(?:c|h):\d+:\d+: runtime error:", text) is not None)
    assertion = "assert failed" in text
    caught = sanitizer if defect["expect"] == "sanitizer" else assertion
    kept = sorted(p.name for p in artifacts.iterdir() if p.is_file())
    return {
        "name": name, "guarantee": defect["guarantee"], "expect": defect["expect"],
        "caught": caught, "sanitizer_report": sanitizer, "goose_assertion": assertion,
        "returncode": result.returncode, "artifacts": kept,
        "artifact_sha256": {p.name: sha256_file(p) for p in artifacts.iterdir() if p.is_file()},
        "command": command, "log": str(log), "log_tail": text[-4000:],
        "source_sha256": build_info["source_sha256"],
        "binary_sha256": build_info["binary_sha256"],
        "debug": build_info["debug"],
        "patches": [{"stage": patch["stage"], "find": patch["find"],
                     "replace": patch["replace"]} for patch in defect["patches"]],
    }


def campaign(binary: Path, corpus: Path, seeds: Path, artifacts: Path, log: Path,
             env: dict, seconds: int, runs: int, seed: int, max_len: int,
             timeout: int, rss_mb: int) -> dict:
    command = [str(binary), str(corpus), str(seeds),
               f"-max_len={max_len}", f"-max_total_time={seconds}",
               f"-runs={runs}", f"-seed={seed}", f"-timeout={timeout}",
               f"-rss_limit_mb={rss_mb}", "-artifact_prefix=" + str(artifacts) + "/"]
    with log.open("wb") as handle:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=handle,
                                stderr=subprocess.STDOUT, timeout=seconds + 300)
    text = log.read_text(errors="replace")
    done = [line for line in text.splitlines() if line.startswith("Done ")]
    executed = int(done[-1].split()[1]) if done else 0
    coverage = re.findall(r"cov: (\d+) ft: (\d+)", text)
    corpus_files = sorted(p.name for p in corpus.iterdir() if p.is_file())
    return {
        "seed": seed, "seconds": seconds, "runs_requested": runs,
        "executed": executed, "returncode": result.returncode,
        "coverage_last": {"cov": int(coverage[-1][0]), "ft": int(coverage[-1][1])} if coverage else None,
        "corpus_files": len(corpus_files),
        "corpus_sha256": hashlib.sha256("".join(corpus_files).encode()).hexdigest(),
        "artifacts": sorted(p.name for p in artifacts.iterdir() if p.is_file()),
        "command": command, "log": str(log),
        "log_tail": text[-3000:],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--goose", type=Path, required=True)
    parser.add_argument("--cc", default="clang")
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument("--runs", type=int, default=100000)
    parser.add_argument("--seed", type=int, action="append",
                        help=f"repeatable; default {SEEDS}")
    parser.add_argument("--max-len", type=int, default=4096)
    parser.add_argument("--timeout", type=int, default=5)
    parser.add_argument("--rss-mb", type=int, default=1024)
    parser.add_argument("--self-test", action="store_true",
                        help="only prove the assertion bridge keeps the input")
    parser.add_argument("--defect", action="append", choices=sorted(DEFECTS),
                        help="run a negative control; repeatable")
    parser.add_argument("--defect-seconds", type=int, default=60)
    parser.add_argument("--defect-runs", type=int, default=200000)
    parser.add_argument("--output", type=Path, default=WORK / "results.json")
    args = parser.parse_args()

    if not 1 <= args.seconds <= 3600:
        parser.error("seconds must be 1..3600")
    if not 1 <= args.runs <= 100000000:
        parser.error("runs must be 1..100000000")
    if not 1 <= args.max_len <= 1 << 20:
        parser.error("max-len must be 1..1048576")

    goose = args.goose.resolve()
    if not goose.is_file():
        raise SystemExit(f"compiler not found: {goose}")
    env = dict(os.environ)
    env.pop("LD_LIBRARY_PATH", None)

    WORK.mkdir(parents=True, exist_ok=True)
    seeds = WORK / "seeds"
    seed_rows = write_seeds(seeds)
    build_info = build(goose, args.cc, env, ROOT, WORK, self_test=True)

    results: dict = {
        "schema": 1,
        "goose": {"path": str(goose), "sha256": sha256_file(goose),
                  "version": must([str(goose), "--version"], ROOT, env).strip()},
        "build": build_info,
        "seeds": {"count": len(seed_rows), "rows": seed_rows,
                  "sha256": hashlib.sha256(
                      json.dumps(seed_rows, sort_keys=True).encode()).hexdigest()},
        "limits": {"max_len": args.max_len, "timeout_s": args.timeout,
                   "rss_limit_mb": args.rss_mb},
        "campaigns": [],
        "defects": [],
    }

    print("Verifying the Goose assertion bridge keeps the exact input", flush=True)
    self_test = assertion_self_test(WORK, env, Path(build_info["self_test_binary"]))
    results["assertion_bridge"] = self_test
    if not self_test["ok"]:
        print(self_test["log_tail"], file=sys.stderr)
        raise SystemExit("Goose assertion bridge self-test failed")
    print("  ok: assertion aborts, libFuzzer keeps the input", flush=True)

    if args.self_test:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(results, indent=2) + "\n")
        print(f"results: {args.output}")
        return 0

    for seed in (args.seed or SEEDS):
        corpus = WORK / f"corpus-{seed}"
        artifacts = WORK / f"artifacts-{seed}"
        corpus.mkdir(exist_ok=True)
        artifacts.mkdir(exist_ok=True)
        log = WORK / f"run-{seed}.log"
        print(f"Campaign seed {seed}: {args.seconds}s, {args.runs} runs, "
              f"max_len {args.max_len}, timeout {args.timeout}s, rss {args.rss_mb}MB", flush=True)
        row = campaign(Path(build_info["binary"]), corpus, seeds, artifacts, log, env,
                       args.seconds, args.runs, seed, args.max_len,
                       args.timeout, args.rss_mb)
        results["campaigns"].append(row)
        print(f"  executed {row['executed']}, corpus {row['corpus_files']}, "
              f"coverage {row['coverage_last']}, artifacts {row['artifacts']}", flush=True)
        if row["returncode"] != 0 or row["artifacts"]:
            print(row["log_tail"], file=sys.stderr)
            raise SystemExit(f"campaign seed {seed} failed; see {log}")

    for name in args.defect or []:
        defect = DEFECTS[name]
        print(f"Negative control {name}: {defect['guarantee']}", flush=True)
        row = defect_control(goose, args.cc, env, name, defect,
                             args.defect_seconds, args.defect_runs,
                             SEEDS[0], args.max_len)
        results["defects"].append(row)
        print(f"  caught={row['caught']} sanitizer={row['sanitizer_report']} "
              f"assertion={row['goose_assertion']} artifacts={row['artifacts']}", flush=True)
        if not row["caught"]:
            print(row["log_tail"], file=sys.stderr)
            raise SystemExit(f"negative control {name} was not caught; the target has a hole")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2) + "\n")
    print(f"results: {args.output}")
    print(f"results sha256 {sha256_file(args.output)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
