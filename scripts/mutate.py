#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Mutation testing for goose-msgpack.

Each mutant changes one real guarantee from docs/api.md — a shortest-form
boundary, a budget comparison, a UTF-8 rule, a framing rule — and nothing else.
A mutant that the test suite still accepts is a hole in the suite, not a
passing mutant: the report names it and the suite is expected to grow.

    python3 scripts/mutate.py --goose /path/to/goose
    python3 scripts/mutate.py --goose /path/to/goose --only utf8-surrogate

The pristine tree must pass both suites first. Every mutant is built in its own
copy under .build/mutate/, so the working tree is never touched.
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
WORK = ROOT / ".build" / "mutate"

# name -> (guarantee, find, replace). Every anchor must occur exactly once.
MUTANTS = {
    "uint-shortest-form": (
        "a uint uses the shortest form: 255 is uint8, not uint16",
        "    let size = if v <= 0x7f { 1 } else if v <= 0xff { 2 } else if v <= 0xffff { 3 } else if v <= 0xffffffff { 5 } else { 9 };\n",
        "    let size = if v <= 0x7f { 1 } else if v <= 0xfe { 2 } else if v <= 0xffff { 3 } else if v <= 0xffffffff { 5 } else { 9 };\n",
    ),
    "int-negative-fixint": (
        "a negative int uses the negative fixint down to -32",
        "    let size = if v >= -32 { 1 } else if v >= -128 { 2 } else if v >= -32768 { 3 } else if v >= -2147483648 { 5 } else { 9 };\n",
        "    let size = if v >= -31 { 1 } else if v >= -128 { 2 } else if v >= -32768 { 3 } else if v >= -2147483648 { 5 } else { 9 };\n",
    ),
    "map-frame-counts-pairs": (
        "a map frame holds 2 * count elements, so the caller writes both halves",
        "    return open_w(writer, n * 2);\n",
        "    return open_w(writer, n);\n",
    ),
    "utf8-surrogate": (
        "a UTF-8 surrogate (U+D800..U+DFFF) is rejected",
        "            if b == 0xed && b1 > 0x9f { return false; }\n",
        "",
    ),
    "utf8-overlong-three": (
        "an overlong three-byte form (U+0800 written in two) is rejected",
        "            if b == 0xe0 && b1 < 0xa0 { return false; }\n",
        "",
    ),
    "utf8-above-max": (
        "a code point above U+10FFFF is rejected",
        "            if b == 0xf4 && b1 > 0x8f { return false; }\n",
        "",
    ),
    "depth-off-by-one": (
        "max_depth is exact: a chain of max_depth containers is accepted, one more is not",
        "        if reader._depth >= reader._limits.max_depth {\n",
        "        if reader._depth > reader._limits.max_depth {\n",
    ),
    "node-off-by-one": (
        "max_nodes is exact: the Nth value is accepted, the N+1th is not",
        "    if reader._nodes >= reader._limits.max_nodes { return Token.Nil, fail(reader, Error.NodeLimit, reader._at); }\n",
        "    if reader._nodes > reader._limits.max_nodes { return Token.Nil, fail(reader, Error.NodeLimit, reader._at); }\n",
    ),
    "trailing-bytes-accepted": (
        "finish rejects a second top-level value",
        "    if reader._at < reader._input.len { return Error.TrailingBytes; }\n",
        "",
    ),
    "sign-extension": (
        "a negative fixint decodes to a negative value",
        "        if raw >= 0x80 { return (raw as! i64) - 0x100; }\n",
        "        if raw >= 0x80 { return (raw as! i64); }\n",
    ),
    "float32-byte-order": (
        "float32 is written big-endian",
        "        var i: i64 = 3;\n",
        "        var i: i64 = 0;\n",
    ),
    "ext-fixed-sixteen": (
        "a 16-byte ext uses fixext16, not ext8",
        "    let fixed = v.len == 1 || v.len == 2 || v.len == 4 || v.len == 8 || v.len == 16;\n",
        "    let fixed = v.len == 1 || v.len == 2 || v.len == 4 || v.len == 8 || v.len == 15;\n",
    ),
    "output-budget-exclusive": (
        "max_output_bytes is inclusive: a value of exactly that size fits",
        "    if size > writer._limits.max_output_bytes - writer._out.len {\n",
        "    if size >= writer._limits.max_output_bytes - writer._out.len {\n",
    ),
    "input-budget-exclusive": (
        "max_input_bytes is inclusive: an input of exactly that size is accepted",
        "    if input.len > limits.max_input_bytes {\n",
        "    if input.len >= limits.max_input_bytes {\n",
    ),
    "skip-stops-early": (
        "skip consumes the whole value, including a nested last child",
        "    while reader._depth > base {\n",
        "    while reader._depth > base + 1 {\n",
    ),
    "str-budget-after-payload": (
        "a declared str length above max_str_bytes is rejected before the payload",
        "    if n > limit { return \"\", fail(reader, error, start); }\n    if !need(reader, n) { return \"\", fail(reader, Error.Truncated, start); }\n",
        "    if !need(reader, n) { return \"\", fail(reader, Error.Truncated, start); }\n    if n > limit { return \"\", fail(reader, error, start); }\n",
    ),
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], cwd: Path, env: dict, timeout: int = 900) -> subprocess.CompletedProcess:
    # A failing contract test prints the raw bytes it compared, which are not
    # UTF-8. Decode leniently so a kill is reported, not a traceback.
    return subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                          text=True, errors="replace", timeout=timeout)


def copy_library(target: Path) -> None:
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    for entry in ("msgpack.goose", "tests", "examples", "bench"):
        source = ROOT / entry
        if source.is_dir():
            shutil.copytree(source, target / entry,
                            ignore=shutil.ignore_patterns("__pycache__"))
        elif source.is_file():
            shutil.copy2(source, target / entry)


def suites(root: Path, goose: Path, env: dict, cases: int) -> dict:
    """Run both suites against `root` and report which one failed first."""
    api = run([str(goose), "run", "tests/api.goose"], root, env)
    oracle = run([sys.executable, "tests/oracle.py", "--goose", str(goose),
                  "--cases", str(cases)], root, env)
    return {
        "api": {"returncode": api.returncode,
                "stdout": api.stdout.strip()[-1500:],
                "stderr": api.stderr.strip()[-1500:]},
        "oracle": {"returncode": oracle.returncode,
                   "stdout": oracle.stdout.strip()[-1500:],
                   "stderr": oracle.stderr.strip()[-1500:]},
        "killed": api.returncode != 0 or oracle.returncode != 0,
        "killed_by": [name for name, row in
                      (("api", api), ("oracle", oracle)) if row.returncode != 0],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--goose", type=Path, required=True)
    parser.add_argument("--cases", type=int, default=20000,
                        help="oracle cases per mutant (default 20000)")
    parser.add_argument("--only", action="append", choices=sorted(MUTANTS),
                        help="run a subset; repeatable")
    parser.add_argument("--output", type=Path, default=WORK / "results.json")
    args = parser.parse_args()

    goose = args.goose.resolve()
    if not goose.is_file():
        raise SystemExit(f"compiler not found: {goose}")
    env = dict(os.environ)
    env.pop("LD_LIBRARY_PATH", None)
    WORK.mkdir(parents=True, exist_ok=True)

    # The pristine tree must pass both suites, or a kill means nothing.
    pristine_root = WORK / "pristine"
    copy_library(pristine_root)
    pristine = suites(pristine_root, goose, env, args.cases)
    print(f"pristine: api rc={pristine['api']['returncode']} "
          f"oracle rc={pristine['oracle']['returncode']}", flush=True)
    if pristine["killed"]:
        print(pristine["api"]["stderr"] or pristine["api"]["stdout"], file=sys.stderr)
        print(pristine["oracle"]["stderr"] or pristine["oracle"]["stdout"], file=sys.stderr)
        raise SystemExit("the pristine tree does not pass; fix that before mutating")

    results = {
        "schema": 1,
        "goose": {"path": str(goose), "sha256": sha256_file(goose)},
        "pristine": {"source_sha256": sha256_file(pristine_root / "msgpack.goose"),
                     "api": pristine["api"], "oracle": pristine["oracle"]},
        "cases": args.cases,
        "mutants": [],
    }

    names = args.only or sorted(MUTANTS)
    survivors = []
    for name in names:
        guarantee, find, replace = MUTANTS[name]
        root = WORK / name
        copy_library(root)
        path = root / "msgpack.goose"
        text = path.read_text()
        occurrences = text.count(find)
        if occurrences != 1:
            raise SystemExit(f"mutant {name}: anchor occurs {occurrences} times, expected 1")
        path.write_text(text.replace(find, replace, 1))
        row = suites(root, goose, env, args.cases)
        record = {
            "name": name, "guarantee": guarantee,
            "diff": {"find": find, "replace": replace},
            "source_sha256": sha256_file(path),
            "killed": row["killed"], "killed_by": row["killed_by"],
            "api": row["api"], "oracle": row["oracle"],
        }
        results["mutants"].append(record)
        status = "killed by " + "+".join(row["killed_by"]) if row["killed"] else "SURVIVED"
        print(f"  {name}: {status}", flush=True)
        if not row["killed"]:
            survivors.append(name)

    results["survivors"] = survivors
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2) + "\n")
    print(f"results: {args.output}")
    print(f"results sha256 {sha256_file(args.output)}")
    if survivors:
        print(f"SURVIVORS ({len(survivors)}): " + ", ".join(survivors), file=sys.stderr)
        return 1
    print(f"all {len(names)} mutants killed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
