#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Freeze a commit into an immutable, auditable baseline.

The point is to make a later claim checkable. Every byte that a measurement or
a regression report depends on is hashed here, and the baseline binaries are
built from the *archived tree*, not from the working tree, so a later edit
cannot silently change what "before" meant.

    python3 scripts/freeze.py --goose /path/to/goose --rev 18c968b
    python3 scripts/freeze.py --check --output .build/baseline/18c968bcf2d9

A baseline directory is write-once. `freeze.py` refuses to write into an
existing one: a rebuild is a new identity, never an overwrite. `--check`
verifies an existing baseline and modifies nothing.

Writes, under --output (default .build/baseline/<rev>/):

    tree.tar            git archive of the commit
    tree/               the same archive, extracted, used for the builds
    tree/.build/competitor/goose-msgpack/
                        a read-only copy of the pinned competitor, so the
                        baseline does not depend on a mutable checkout
    bin/                the baseline binaries
    manifest.json       every hash, every build command, every dependency
    manifest.sha256     sha256 of manifest.json, so the manifest is pinned too

Nothing here is committed to the repository; .build/ is ignored on purpose.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Built from the archived tree. Each entry is (name, source, extra flags).
BINARIES = [
    ("api", "tests/api.goose", ["--standalone", "--cc", "cc", "-O2"]),
    ("api-debug", "tests/api.goose", ["--standalone", "--debug", "--cc", "cc"]),
    ("oracle", "tests/oracle.goose", ["--standalone", "--cc", "cc", "-O2"]),
    ("plan", "examples/plan.goose", ["--standalone", "--cc", "cc", "-O2"]),
    ("bench", "bench/bench.goose", ["--standalone", "--cc", "cc", "-O2"]),
    ("bench-competitor", "bench/bench-competitor.goose", ["--standalone", "--cc", "cc", "-O2"]),
]

COMPETITOR = ROOT / ".build" / "competitor" / "goose-msgpack"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], cwd: Path, env: dict | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise SystemExit(
            "command failed: " + " ".join(command) + "\n" + result.stdout + result.stderr
        )
    return result.stdout


def git(*args: str, cwd: Path = ROOT) -> str:
    return run(["git", *args], cwd=cwd).strip()


def tracked_files(rev: str) -> list[dict]:
    """Every blob in the commit, with its mode and content hash."""
    rows = []
    for entry in git("ls-tree", "-r", "-z", "--full-tree", rev).split("\0"):
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        mode, kind, blob = meta.split()
        if kind != "blob":
            continue
        content = subprocess.run(
            ["git", "cat-file", "blob", blob], cwd=ROOT, capture_output=True, check=True
        ).stdout
        rows.append({"path": path, "mode": mode, "git_blob": blob,
                     "bytes": len(content), "sha256": sha256_bytes(content)})
    rows.sort(key=lambda row: row["path"])
    return rows


def hash_tree(path: Path) -> list[dict]:
    """Content hash of every regular file under `path`, sorted by path."""
    rows = []
    for entry in sorted(path.rglob("*")):
        if not entry.is_file() or entry.is_symlink():
            continue
        rows.append({"path": str(entry.relative_to(path)),
                     "bytes": entry.stat().st_size,
                     "sha256": sha256_file(entry)})
    return rows


def dependencies(binary: Path, env: dict) -> dict:
    """The shared objects the binary actually loads, and their hashes."""
    result = subprocess.run(["ldd", str(binary)], capture_output=True, text=True, env=env)
    loaded = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if "=>" in line:
            name, rest = line.split("=>", 1)
            target = rest.strip().split(" (")[0].strip()
        elif line.startswith("/"):
            name, target = line.split(" (")[0].strip(), line.split(" (")[0].strip()
        else:
            continue
        if not target or target == "not found":
            loaded.append({"name": name.strip(), "path": target or None, "sha256": None})
            continue
        path = Path(target)
        loaded.append({"name": name.strip(), "path": target,
                       "sha256": sha256_file(path) if path.is_file() else None})
    return {"ldd_exit": result.returncode, "loaded": loaded}


def identity(manifest: dict) -> str:
    """A stable identity: the manifest without its own identity field."""
    body = {key: value for key, value in manifest.items() if key != "identity"}
    return sha256_bytes(json.dumps(body, sort_keys=True, separators=(",", ":")).encode())


def refuse_existing(output: Path) -> None:
    if output.exists() and any(output.iterdir()):
        raise SystemExit(
            f"refusing to write into an initialized baseline: {output}\n"
            "A baseline is write-once. Use --check to verify it, or pass a new --output."
        )


def freeze(args) -> int:
    goose = args.goose.resolve()
    if not goose.is_file():
        raise SystemExit(f"compiler not found: {goose}")
    rev = git("rev-parse", args.rev)
    output = (args.output or ROOT / ".build" / "baseline" / rev[:12]).resolve()
    refuse_existing(output)
    output.mkdir(parents=True, exist_ok=True)

    # This machine exports an LD_LIBRARY_PATH that breaks the compiler and
    # cmake. Recorded, not assumed.
    env = dict(os.environ)
    env.pop("LD_LIBRARY_PATH", None)

    archive = output / "tree.tar"
    subprocess.run(["git", "archive", "--format=tar", "-o", str(archive), rev],
                   cwd=ROOT, check=True)
    tree = output / "tree"
    tree.mkdir()
    with tarfile.open(archive) as handle:
        handle.extractall(tree)

    # bench/bench-competitor.goose imports the competitor from ../.build/...,
    # which git archive does not carry. Copy the pinned checkout in and make it
    # read-only: a symlink would let a later fetch change what this baseline
    # built, and the copy is what --check verifies.
    competitor_copy = tree / ".build" / "competitor" / "goose-msgpack"
    competitor_before = None
    if COMPETITOR.is_dir():
        shutil.copytree(COMPETITOR, competitor_copy,
                        ignore=shutil.ignore_patterns(".git"))
        for entry in competitor_copy.rglob("*"):
            if entry.is_file():
                entry.chmod(entry.stat().st_mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
        competitor_before = hash_tree(competitor_copy)

    manifest: dict = {
        "schema": 2,
        "repository": str(ROOT),
        "rev": rev,
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "tree_sha": git("rev-parse", rev + "^{tree}"),
        "subject": git("log", "-1", "--format=%s", rev),
        "committed": git("log", "-1", "--format=%cI", rev),
        "working_tree_status": git("status", "--porcelain"),
        "archive": {"path": "tree.tar", "bytes": archive.stat().st_size,
                    "sha256": sha256_file(archive)},
        "files": tracked_files(rev),
        "compiler": {
            "path": str(goose),
            "sha256": sha256_file(goose),
            "bytes": goose.stat().st_size,
            "version": run([str(goose), "--version"], cwd=ROOT, env=env).strip(),
        },
        "platform": {
            "machine": os.uname().machine,
            "system": os.uname().sysname,
            "release": os.uname().release,
            "python": sys.version.split()[0],
            "cc": run([args.cc, "--version"], cwd=ROOT, env=env).splitlines()[0],
        },
        "competitor": {
            "source": str(COMPETITOR),
            "commit": git("rev-parse", "HEAD", cwd=COMPETITOR) if COMPETITOR.is_dir() else None,
            "describe": git("describe", "--tags", "--always", cwd=COMPETITOR) if COMPETITOR.is_dir() else None,
            "tree": git("rev-parse", "HEAD^{tree}", cwd=COMPETITOR) if COMPETITOR.is_dir() else None,
            "dirty": bool(git("status", "--porcelain", cwd=COMPETITOR)) if COMPETITOR.is_dir() else None,
            "copy": "tree/.build/competitor/goose-msgpack",
            "files": competitor_before,
        },
        "binaries": [],
    }

    if not args.skip_build:
        for name, source, flags in BINARIES:
            target = output / "bin" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            command = [str(goose), "build", source, *flags, "-o", str(target)]
            run(command, cwd=tree, env=env)
            manifest["binaries"].append({
                "name": name, "source": source, "command": command,
                "bytes": target.stat().st_size, "sha256": sha256_file(target),
                "dependencies": dependencies(target, env),
            })

    # The build must not have touched the competitor copy.
    if competitor_before is not None:
        after = hash_tree(competitor_copy)
        if after != competitor_before:
            raise SystemExit("the competitor copy changed during the build; baseline rejected")

    manifest["identity"] = identity(manifest)
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    digest = sha256_file(manifest_path)
    (output / "manifest.sha256").write_text(digest + "  manifest.json\n")

    print(f"frozen {rev[:12]} -> {output}")
    print(f"identity {manifest['identity']}")
    print(f"archive sha256 {manifest['archive']['sha256']}")
    print(f"compiler sha256 {manifest['compiler']['sha256']}")
    print(f"manifest sha256 {digest}")
    for row in manifest["binaries"]:
        print(f"  {row['name']}: {row['bytes']} bytes sha256 {row['sha256']}")
    return 0


def check(args) -> int:
    output = args.output.resolve()
    manifest_path = output / "manifest.json"
    if not manifest_path.is_file():
        raise SystemExit(f"no manifest at {manifest_path}")
    problems: list[str] = []

    recorded = (output / "manifest.sha256").read_text().split()[0]
    actual = sha256_file(manifest_path)
    if recorded != actual:
        problems.append(f"manifest.json sha256 {actual} != recorded {recorded}")
    manifest = json.loads(manifest_path.read_text())

    if identity(manifest) != manifest.get("identity"):
        problems.append("manifest identity does not match its own body")

    archive = output / manifest["archive"]["path"]
    if not archive.is_file():
        problems.append(f"archive missing: {archive}")
    elif sha256_file(archive) != manifest["archive"]["sha256"]:
        problems.append("archive sha256 mismatch")

    tree = output / "tree"
    for row in manifest["files"]:
        path = tree / row["path"]
        if not path.is_file():
            problems.append(f"missing: {row['path']}")
        elif sha256_file(path) != row["sha256"]:
            problems.append(f"changed: {row['path']}")

    for row in manifest["binaries"]:
        path = output / "bin" / row["name"]
        if not path.is_file():
            problems.append(f"missing binary: {row['name']}")
        elif sha256_file(path) != row["sha256"]:
            problems.append(f"changed binary: {row['name']}")

    competitor = manifest.get("competitor") or {}
    if competitor.get("files"):
        copy = output / competitor["copy"]
        if hash_tree(copy) != competitor["files"]:
            problems.append("competitor copy changed")

    if problems:
        print(f"baseline {output} FAILED {len(problems)} check(s):")
        for problem in problems:
            print("  " + problem)
        return 1
    print(f"baseline {output} verified: identity {manifest['identity']}")
    print(f"  {len(manifest['files'])} source files, {len(manifest['binaries'])} binaries, "
          f"{len(competitor.get('files') or [])} competitor files")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--goose", type=Path, help="pinned Goose compiler (required to freeze)")
    parser.add_argument("--rev", default="HEAD", help="commit to freeze (default HEAD)")
    parser.add_argument("--output", type=Path, help="default .build/baseline/<rev>")
    parser.add_argument("--cc", default="cc", help="C compiler for the baseline binaries")
    parser.add_argument("--skip-build", action="store_true", help="manifest only, no binaries")
    parser.add_argument("--check", action="store_true",
                        help="verify an existing baseline and modify nothing")
    args = parser.parse_args()
    if args.check:
        if not args.output:
            parser.error("--check needs --output")
        return check(args)
    if not args.goose:
        parser.error("--goose is required to freeze")
    return freeze(args)


if __name__ == "__main__":
    sys.exit(main())
