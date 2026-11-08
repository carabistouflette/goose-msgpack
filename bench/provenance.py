#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build provenance for a benchmark binary.

A comparison between two binaries is only a comparison of the library if
everything else is held fixed. The compiler is part of "everything else": a
baseline built with clang and a candidate built with gcc differ by the compiler
as well as by the library, and any speed difference is then unattributable.

This module records, for one binary, the facts needed to check that:

  - the exact build command, as an argument vector;
  - the compiler: the name asked for, the path it resolved to, its version
    string and the SHA-256 of the compiler binary itself;
  - the optimisation flags;
  - the SHA-256 of every source file that went into it;
  - the SHA-256 of the binary;
  - the runtime headers the compiler used, hashed;
  - the shared libraries the binary links, resolved and hashed.

The record is written next to the binary as `<binary>.json`. `paired.py` reads
both records and refuses to attribute a difference to the library when the
compiler identity differs.

Why not read the compiler from the ELF `.comment` section: the Goose compiler
links a GCC-compiled startup/runtime object into every binary, so a
clang-compiled program still carries a `GCC:` line. `.comment` cannot tell you
which compiler compiled the code under measurement. The build command can.

    python3 bench/provenance.py record --binary .build/bench/msgpack-bench \\
        --cc cc --command "goose build ..." --source msgpack.goose \\
        --source bench/bench.goose
    python3 bench/provenance.py show --binary .build/bench/msgpack-bench
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
SCHEMA = 1


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compiler_identity(cc: str) -> dict:
    """Resolve a compiler name and record what it actually is.

    The version string is the first line of `--version`, which is what both gcc
    and clang print. The binary hash is what makes "the same compiler" checkable
    rather than a claim about a name.
    """
    resolved = shutil.which(cc)
    if resolved is None:
        raise SystemExit(f"compiler {cc!r} is not on PATH")
    path = Path(resolved).resolve()
    try:
        version = subprocess.run([str(path), "--version"], capture_output=True,
                                 text=True, check=True).stdout.splitlines()[0].strip()
    except (subprocess.CalledProcessError, IndexError):
        version = "unknown"
    return {
        "requested": cc,
        "path": str(path),
        "version": version,
        "sha256": sha256_file(path),
    }


def runtime_headers(goose: str | None) -> list[dict]:
    """The Goose runtime headers the compiler used, hashed.

    The compiler ships its runtime next to the binary; the headers are what the
    generated C includes. If they change, the binary changed for a reason that
    has nothing to do with the library.
    """
    if not goose:
        return []
    base = Path(goose).resolve().parent
    found = []
    for candidate in sorted(base.rglob("*.h")):
        found.append({"path": str(candidate), "sha256": sha256_file(candidate)})
    return found


def linked_libraries(binary: Path) -> list[dict]:
    """The shared libraries the binary links, resolved and hashed."""
    try:
        text = subprocess.run(["ldd", str(binary)], capture_output=True,
                              text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    deps = []
    for line in text.splitlines():
        line = line.strip()
        if "=>" not in line:
            continue
        name, rest = line.split("=>", 1)
        target = rest.strip().split(" (")[0].strip()
        if not target or target == "not found":
            deps.append({"name": name.strip(), "path": None, "sha256": None})
            continue
        path = Path(target)
        deps.append({
            "name": name.strip(),
            "path": str(path),
            "sha256": sha256_file(path) if path.exists() else None,
        })
    return deps


def record(binary: Path, cc: str, command: list[str], flags: list[str],
           sources: list[Path], goose: str | None) -> dict:
    if not binary.exists():
        raise SystemExit(f"{binary} does not exist; build it first")
    return {
        "schema": SCHEMA,
        "binary": str(binary),
        "binary_sha256": sha256_file(binary),
        "binary_bytes": binary.stat().st_size,
        "command": command,
        "flags": flags,
        "compiler": compiler_identity(cc),
        "sources": [{"path": str(p), "sha256": sha256_file(p)}
                    for p in sources if p.exists()],
        "runtime_headers": runtime_headers(goose),
        "linked_libraries": linked_libraries(binary),
        "goose": goose,
        "goose_sha256": sha256_file(Path(goose)) if goose and Path(goose).exists() else None,
    }


def sidecar(binary: Path) -> Path:
    return binary.with_suffix(".json")


def write(binary: Path, data: dict) -> Path:
    path = sidecar(binary)
    path.write_text(json.dumps(data, indent=2) + "\n")
    return path


def read(binary: Path) -> dict | None:
    path = sidecar(binary)
    if not path.exists():
        return None
    return json.loads(path.read_text())


def sidecar_matches(binary: Path, record: dict | None) -> bool:
    """The sidecar must describe the binary that is on disk right now.

    A rebuild replaces the binary but leaves the old sidecar in place, so a
    record that is merely *present* proves nothing. Without this check a run
    could report the provenance of a binary it did not measure.
    """
    if record is None:
        return False
    return record.get("binary_sha256") == sha256_file(binary)


def sources_unchanged(record: dict | None) -> bool:
    """Every source the record names must still hash to what it recorded."""
    if record is None:
        return False
    for entry in record.get("sources") or []:
        path = Path(entry["path"])
        if not path.exists() or sha256_file(path) != entry["sha256"]:
            return False
    return True


def compare(a: dict | None, b: dict | None) -> dict:
    """Compare two build records on the axes that must be held fixed.

    Returns a dict of checks. `compiler_identical` is the one that decides
    whether a difference may be attributed to the library.
    """
    if a is None or b is None:
        return {
            "records_present": False,
            "note": "at least one binary has no build record; run "
                    "`python3 bench/provenance.py record` for it",
        }
    ca, cb = a["compiler"], b["compiler"]
    return {
        "records_present": True,
        "compiler_identical": ca["sha256"] == cb["sha256"],
        "compiler_a": ca,
        "compiler_b": cb,
        "flags_identical": a["flags"] == b["flags"],
        "flags_a": a["flags"],
        "flags_b": b["flags"],
        "goose_identical": a.get("goose_sha256") == b.get("goose_sha256"),
        "runtime_headers_identical": a["runtime_headers"] == b["runtime_headers"],
        "linked_libraries_identical": a["linked_libraries"] == b["linked_libraries"],
        "sources_a": a["sources"],
        "sources_b": b["sources"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)

    rec = sub.add_parser("record", help="Record the build provenance of a binary")
    rec.add_argument("--binary", type=Path, required=True)
    rec.add_argument("--cc", required=True, help="The compiler that was used")
    rec.add_argument("--command", default="", help="The build command, for the record")
    rec.add_argument("--flags", default="", help="Optimisation flags, space separated")
    rec.add_argument("--source", type=Path, action="append", default=[],
                     help="A source file that went into the binary; repeatable")
    rec.add_argument("--goose", default=os.environ.get("GOOSE", ""))

    show = sub.add_parser("show", help="Print the build record of a binary")
    show.add_argument("--binary", type=Path, required=True)

    cmp_ = sub.add_parser("compare", help="Compare two build records")
    cmp_.add_argument("--a", type=Path, required=True)
    cmp_.add_argument("--b", type=Path, required=True)

    args = parser.parse_args()

    if args.action == "record":
        data = record(args.binary, args.cc, args.command.split() if args.command else [],
                      args.flags.split(), args.source, args.goose or None)
        path = write(args.binary, data)
        print(f"wrote {path}")
        print(f"  compiler {data['compiler']['version']} ({data['compiler']['path']})")
        print(f"  binary   {data['binary_sha256']}")
        return 0

    if args.action == "show":
        data = read(args.binary)
        if data is None:
            raise SystemExit(f"{args.binary} has no build record")
        print(json.dumps(data, indent=2))
        return 0

    result = compare(read(args.a), read(args.b))
    print(json.dumps(result, indent=2))
    if result.get("records_present") and not result["compiler_identical"]:
        print("\nCOMPILER MISMATCH: a difference between these binaries cannot be "
              "attributed to the library.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
