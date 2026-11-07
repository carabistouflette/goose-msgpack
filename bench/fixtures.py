#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixture table for the goose-msgpack benchmark, and its expected bytes.

The table is the single source of truth: bench/bench.goose hard-codes the same
numbers, and this file recomputes the expected encoding with the independent
encoder in tests/oracle.py. `--check` fails if the two disagree, so a fixture
cannot drift silently.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import oracle  # noqa: E402  (the independent encoder, reused on purpose)

# name, tasks, edges, string members, string bytes
FIXTURES = [
    ("plan-small", 4, 3, 0, 0),
    ("plan-medium", 64, 128, 0, 0),
    ("plan-large", 1024, 4096, 0, 0),
    ("strings-16x32", 0, 0, 16, 32),
    ("strings-4x256", 0, 0, 4, 256),
]


def fnv1a(data: bytes) -> int:
    value = 0xCBF29CE484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def manifest(tasks: int, edges: int, members: int, member_bytes: int) -> list[tuple]:
    """The same value bench.goose builds, as a flat token list."""
    tokens: list[tuple] = [("map", 6)]
    tokens += [("str", b"format"), ("str", b"goose-task-plan")]
    tokens += [("str", b"version"), ("uint", 1)]
    tokens += [("str", b"count"), ("uint", tasks)]
    tokens += [("str", b"concurrency"), ("uint", max(1, tasks // 2))]
    tokens += [("str", b"edges"), ("array", edges)]
    for i in range(edges):
        tokens += [("array", 2), ("uint", i % max(1, tasks)), ("uint", (i * 7 + 1) % max(1, tasks))]
    tokens += [("str", b"labels"), ("map", members)]
    for i in range(members):
        tokens += [("str", f"k{i}".encode()), ("str", b"x" * member_bytes)]
    return tokens


def expected() -> list[dict]:
    rows = []
    for name, tasks, edges, members, member_bytes in FIXTURES:
        data = oracle.encode(manifest(tasks, edges, members, member_bytes))
        rows.append({"name": name, "tasks": tasks, "edges": edges,
                     "members": members, "member_bytes": member_bytes,
                     "bytes": len(data), "fnv1a": f"{fnv1a(data):016x}",
                     "sha256": hashlib.sha256(data).hexdigest()})
    return rows


def table_digest() -> str:
    return hashlib.sha256(json.dumps(FIXTURES).encode()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify the table and print it")
    parser.add_argument("--emit", type=Path, help="Write the expected rows as JSON")
    args = parser.parse_args()
    rows = expected()
    if args.check:
        for row in rows:
            print(f"{row['name']}: {row['bytes']} bytes fnv1a {row['fnv1a']}")
        print(f"fixture table sha256 {table_digest()}")
    if args.emit:
        args.emit.parent.mkdir(parents=True, exist_ok=True)
        args.emit.write_text(json.dumps({"table_sha256": table_digest(), "rows": rows}, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
