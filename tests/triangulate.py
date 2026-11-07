#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Third-party triangulation for goose-msgpack.

The differential oracle in tests/oracle.py is an independent reimplementation of
the same contract, but it was written for this library. A misreading of the
specification can be shared by both sides and stay invisible. This driver adds a
second, unrelated implementation: msgpack-c, the C library maintained by the
official msgpack organisation, pinned at a recorded commit.

    python3 tests/triangulate.py --goose <goose> --msgpack-c .build/thirdparty/msgpack-c

It builds two binaries that read the same corpus and print the same canonical
token form, then compares them record by record:

    .build/triangulate            goose-msgpack, token stream
    .build/triangulate-msgpackc   msgpack-c, DOM walked in pre-order

The corpus is generated here with a small encoder written from the
specification, not with tests/oracle.py, so the generator cannot inherit the
oracle's reading either.

What a disagreement means
-------------------------

`agree-accept`   both accept and the canonical forms are identical.
`agree-reject`   both refuse the record.
`policy-utf8`    msgpack-c accepts, this library refuses with `InvalidUtf8`.
                 msgpack-c does not validate UTF-8; this library does, on
                 purpose. A contract difference, counted and reported.
`budget-*`       msgpack-c accepts, this library refuses with a budget error.
                 msgpack-c has no input, node, depth, str, bin or container
                 budget. A contract difference, counted and reported.
`oracle-depth-limit-32`
                 msgpack-c refuses and this library accepts, because
                 `msgpack_unpack_next` has a fixed 32-frame stack
                 (`MSGPACK_EMBED_STACK_SIZE`, `unpack_template.h`, marked
                 `FIXME`) and reports a deeper document as NOMEM. This
                 library's limit is configurable up to `MAX_DEPTH = 256` and
                 reports `DepthLimit`. The oracle is the stricter side here.
`oracle-f32-nan-quieting`
                 both accept, and the only difference is that msgpack-c
                 reports an f32 NaN with the quiet bit set. msgpack-c widens
                 an f32 to a double and narrows it back, which quiets a
                 signalling NaN; this library keeps the wire bits exactly.
                 The oracle is the lossy side here, and the report says so.
`DEFECT-*`       anything else. These fail the run:
                 - both accept but the trees differ;
                 - msgpack-c refuses and this library accepts;
                 - this library refuses with `Truncated` or `Reserved` where
                   msgpack-c accepted, which would mean a valid document is
                   being rejected.

The report is written as JSON so a later run can be compared with it.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MSGPACK_C_COMMIT = "f3f796bbe6a2dd0414520f187cec2e4bd41766bf"  # c_master, 7.0.3
MSGPACK_C_VERSION = "7.0.3"

# ---------------------------------------------------------------------------
# A minimal encoder, written from the specification. Deliberately not
# tests/oracle.py: the generator must not share the oracle's reading.
# ---------------------------------------------------------------------------


def be(value: int, width: int) -> bytes:
    return value.to_bytes(width, "big")


def enc_uint(v: int) -> bytes:
    if v < 0:
        raise ValueError("enc_uint of a negative value")
    if v <= 0x7F:
        return bytes([v])
    if v <= 0xFF:
        return b"\xcc" + be(v, 1)
    if v <= 0xFFFF:
        return b"\xcd" + be(v, 2)
    if v <= 0xFFFFFFFF:
        return b"\xce" + be(v, 4)
    return b"\xcf" + be(v, 8)


def enc_int(v: int) -> bytes:
    if v >= 0:
        return enc_uint(v)
    if v >= -32:
        return bytes([v & 0xFF])
    if v >= -128:
        return b"\xd0" + be(v & 0xFF, 1)
    if v >= -32768:
        return b"\xd1" + be(v & 0xFFFF, 2)
    if v >= -2147483648:
        return b"\xd2" + be(v & 0xFFFFFFFF, 4)
    return b"\xd3" + be(v & 0xFFFFFFFFFFFFFFFF, 8)


def enc_str(payload: bytes) -> bytes:
    n = len(payload)
    if n <= 31:
        return bytes([0xA0 | n]) + payload
    if n <= 0xFF:
        return b"\xd9" + be(n, 1) + payload
    if n <= 0xFFFF:
        return b"\xda" + be(n, 2) + payload
    return b"\xdb" + be(n, 4) + payload


def enc_bin(payload: bytes) -> bytes:
    n = len(payload)
    if n <= 0xFF:
        return b"\xc4" + be(n, 1) + payload
    if n <= 0xFFFF:
        return b"\xc5" + be(n, 2) + payload
    return b"\xc6" + be(n, 4) + payload


def enc_ext(typ: int, payload: bytes) -> bytes:
    n = len(payload)
    fixed = {1: 0xD4, 2: 0xD5, 4: 0xD6, 8: 0xD7, 16: 0xD8}
    if n in fixed:
        return bytes([fixed[n], typ & 0xFF]) + payload
    if n <= 0xFF:
        return b"\xc7" + be(n, 1) + bytes([typ & 0xFF]) + payload
    if n <= 0xFFFF:
        return b"\xc8" + be(n, 2) + bytes([typ & 0xFF]) + payload
    return b"\xc9" + be(n, 4) + bytes([typ & 0xFF]) + payload


def enc_array(items: list[bytes]) -> bytes:
    n = len(items)
    if n <= 15:
        head = bytes([0x90 | n])
    elif n <= 0xFFFF:
        head = b"\xdc" + be(n, 2)
    else:
        head = b"\xdd" + be(n, 4)
    return head + b"".join(items)


def enc_map(pairs: list[tuple[bytes, bytes]]) -> bytes:
    n = len(pairs)
    if n <= 15:
        head = bytes([0x80 | n])
    elif n <= 0xFFFF:
        head = b"\xde" + be(n, 2)
    else:
        head = b"\xdf" + be(n, 4)
    return head + b"".join(k + v for k, v in pairs)


def enc_float32(bits: int) -> bytes:
    return b"\xca" + be(bits, 4)


def enc_float64(bits: int) -> bytes:
    return b"\xcb" + be(bits, 8)


# ---------------------------------------------------------------------------
# Corpus
# ---------------------------------------------------------------------------

VALID_UTF8 = [
    b"",
    b"a",
    b"hello",
    "é".encode(),
    "日本語".encode(),
    "🎉".encode(),
    b"\x7f",
    b"\xc2\x80",          # U+0080, the shortest 2-byte form
    b"\xdf\xbf",          # U+07FF
    b"\xe0\xa0\x80",      # U+0800, the shortest 3-byte form
    b"\xef\xbf\xbf",      # U+FFFF
    b"\xf0\x90\x80\x80",  # U+10000, the shortest 4-byte form
    b"\xf4\x8f\xbf\xbf",  # U+10FFFF, the last code point
    b"\xef\xbf\xbe",      # U+FFFE, a non-character but valid UTF-8
    b"x" * 31,
    b"x" * 32,
    b"x" * 255,
    b"x" * 256,
]

INVALID_UTF8 = [
    b"\x80",                    # a lone continuation byte
    b"\xc0\x80",                # overlong NUL
    b"\xc1\xbf",                # overlong
    b"\xe0\x80\x80",            # overlong
    b"\xf0\x80\x80\x80",        # overlong
    b"\xed\xa0\x80",            # a surrogate, U+D800
    b"\xed\xbf\xbf",            # a surrogate, U+DFFF
    b"\xf4\x90\x80\x80",        # above U+10FFFF
    b"\xf5\x80\x80\x80",        # an invalid lead byte
    b"\xc2",                    # truncated 2-byte sequence
    b"\xe2\x82",                # truncated 3-byte sequence
    b"\xf0\x9f\x8e",            # truncated 4-byte sequence
    b"ok\xff",                  # invalid in the middle
    b"\xffok",                  # invalid at the start
    b"ok\xc0\xaf",              # overlong in the middle
]


def edge_cases() -> list[tuple[str, bytes]]:
    rows: list[tuple[str, bytes]] = []

    def add(name: str, data: bytes) -> None:
        rows.append((name, data))

    # Scalars, every marker family.
    add("nil", b"\xc0")
    add("false", b"\xc2")
    add("true", b"\xc3")
    for v in (0, 1, 127, 128, 255, 256, 65535, 65536, 4294967295, 4294967296,
              2**63 - 1, 2**63, 2**64 - 1):
        add(f"uint-{v}", enc_uint(v))
    for v in (-1, -32, -33, -128, -129, -32768, -32769, -2147483648,
              -2147483649, -(2**63)):
        add(f"int-{v}", enc_int(v))
    # Non-shortest forms: the specification allows them, a decoder must accept.
    add("uint8-nonshortest", b"\xcc\x05")
    add("uint16-nonshortest", b"\xcd\x00\x05")
    add("uint32-nonshortest", b"\xce\x00\x00\x00\x05")
    add("uint64-nonshortest", b"\xcf\x00\x00\x00\x00\x00\x00\x00\x05")
    add("int8-nonshortest", b"\xd0\x05")
    add("int64-nonshortest", b"\xd3\x00\x00\x00\x00\x00\x00\x00\x05")
    add("str8-nonshortest", b"\xd9\x01a")
    add("str16-nonshortest", b"\xda\x00\x01a")
    add("str32-nonshortest", b"\xdb\x00\x00\x00\x01a")
    add("array16-nonshortest", b"\xdc\x00\x01\x01")
    add("array32-nonshortest", b"\xdd\x00\x00\x00\x01\x01")
    add("map16-nonshortest", b"\xde\x00\x01\xa1a\x01")
    add("map32-nonshortest", b"\xdf\x00\x00\x00\x01\xa1a\x01")

    # Floats: both widths, NaN, infinities, -0.0, subnormals.
    for bits in (0x00000000, 0x80000000, 0x3FC00000, 0x7F800000, 0xFF800000,
                 0x7FC00000, 0x7F800001, 0x00000001, 0x7F7FFFFF):
        add(f"f32-{bits:08x}", enc_float32(bits))
    for bits in (0x0000000000000000, 0x8000000000000000, 0x3FF8000000000000,
                 0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000000,
                 0x7FF0000000000001, 0x0000000000000001, 0x7FEFFFFFFFFFFFFF):
        add(f"f64-{bits:016x}", enc_float64(bits))

    # Strings, binary and extension payloads at their length boundaries.
    for payload in VALID_UTF8:
        add(f"str-{len(payload)}", enc_str(payload))
    for n in (0, 1, 255, 256, 65535, 65536):
        add(f"bin-{n}", enc_bin(bytes((i * 37) & 0xFF for i in range(n))))
    for n in (0, 1, 2, 3, 4, 8, 16, 17, 255, 256):
        add(f"ext-{n}", enc_ext(-7, bytes((i * 11) & 0xFF for i in range(n))))
    add("ext-type-127", enc_ext(127, b"\x01\x02"))
    add("ext-type-neg128", enc_ext(-128, b"\x01\x02"))

    # Containers, including empty ones at depth.
    add("array-empty", b"\x90")
    add("map-empty", b"\x80")
    add("array-of-empty", b"\x92\x90\x90")
    add("map-empty-pair", b"\x81\x90\x90")
    add("nested-empty-3", b"\x91\x91\x90")
    add("nested-empty-8", b"\x91" * 7 + b"\x90")
    add("nested-int-8", b"\x91" * 7 + b"\x01")
    add("array-16", enc_array([enc_uint(i) for i in range(16)]))
    add("map-16", enc_map([(enc_str(f"k{i}".encode()), enc_uint(i)) for i in range(16)]))
    add("mixed-tree", enc_map([
        (enc_str(b"format"), enc_str(b"goose-task-plan")),
        (enc_str(b"version"), enc_uint(1)),
        (enc_str(b"edges"), enc_array([enc_array([enc_uint(0), enc_uint(1)])])),
        (enc_str(b"blob"), enc_bin(b"\x00\x01\x02")),
        (enc_str(b"when"), enc_ext(1, b"\x00\x00\x00\x00")),
        (enc_str(b"ratio"), enc_float64(0x3FF8000000000000)),
    ]))

    # Refusals: the reserved marker, truncation at the start, middle and end,
    # a container length the input cannot hold, and trailing bytes.
    add("reserved-c1", b"\xc1")
    add("reserved-c1-in-array", b"\x92\x01\xc1")
    add("empty-input", b"")
    add("truncated-fixstr", b"\xa5ab")
    add("truncated-str8-header", b"\xd9")
    add("truncated-str8-body", b"\xd9\x05ab")
    add("truncated-uint32", b"\xce\x00\x00")
    add("truncated-float64", b"\xcb\x00\x00\x00\x00")
    add("truncated-array", b"\x92\x01")
    add("truncated-map", b"\x81\xa1a")
    add("truncated-ext", b"\xd6\x01\x00")
    add("array-count-too-large", b"\xdc\xff\xff\x01")
    add("map-count-too-large", b"\xde\xff\xff\x01")
    # Deep nesting: msgpack-c has no depth budget, this library does. These
    # rows exist so the `budget-depth` classification is exercised, not just
    # declared.
    add("deep-31-int", b"\x91" * 31 + b"\x01")
    add("deep-32-int", b"\x91" * 32 + b"\x01")
    add("deep-33-int", b"\x91" * 33 + b"\x01")
    add("deep-256-int", b"\x91" * 256 + b"\x01")
    add("deep-257-int", b"\x91" * 257 + b"\x01")
    add("deep-300-int", b"\x91" * 300 + b"\x01")
    add("deep-300-empty", b"\x91" * 300 + b"\x90")

    add("trailing-byte", b"\x01\x02")
    add("trailing-after-array", b"\x91\x01\x02")
    add("trailing-after-empty", b"\x90\x00")

    # Invalid UTF-8 in a str: this library refuses, msgpack-c does not.
    for payload in INVALID_UTF8:
        add(f"invalid-utf8-{len(payload)}", enc_str(payload))
    # The same bytes in a bin are opaque and must be accepted by both.
    for payload in INVALID_UTF8:
        add(f"invalid-utf8-in-bin-{len(payload)}", enc_bin(payload))

    return rows


def random_tree(rng: random.Random, depth: int) -> bytes:
    """A random valid value, at most `depth` containers deep."""
    if depth <= 0:
        kind = rng.randrange(6)
    else:
        kind = rng.randrange(10)
    if kind == 0:
        return b"\xc0"
    if kind == 1:
        return b"\xc3" if rng.randrange(2) else b"\xc2"
    if kind == 2:
        return enc_uint(rng.choice([0, 1, 127, 128, 255, 256, 65535, 65536,
                                    2**32 - 1, 2**32, 2**63 - 1, 2**64 - 1]))
    if kind == 3:
        return enc_int(rng.choice([-1, -32, -33, -128, -129, -32768, -32769,
                                   -2147483648, -2147483649, -(2**63)]))
    if kind == 4:
        return enc_float32(rng.getrandbits(32))
    if kind == 5:
        return enc_float64(rng.getrandbits(64))
    if kind == 6:
        return enc_str(rng.choice(VALID_UTF8))
    if kind == 7:
        return enc_bin(bytes(rng.getrandbits(8) for _ in range(rng.randrange(0, 40))))
    if kind == 8:
        return enc_ext(rng.randrange(-128, 128),
                       bytes(rng.getrandbits(8) for _ in range(rng.choice([0, 1, 2, 4, 8, 16, 17]))))
    if kind == 9:
        n = rng.randrange(0, 5)
        return enc_array([random_tree(rng, depth - 1) for _ in range(n)])
    n = rng.randrange(0, 4)
    return enc_map([(enc_str(rng.choice(VALID_UTF8)), random_tree(rng, depth - 1))
                    for _ in range(n)])


def corpus(seed: int, trees: int) -> list[tuple[str, bytes]]:
    rows = edge_cases()
    rng = random.Random(seed)
    for i in range(trees):
        rows.append((f"random-{i}", random_tree(rng, rng.randrange(1, 6))))
    # Mutations of a valid document: truncation at every offset, one byte
    # changed, one byte appended. This is where a decoder that reads past the
    # end, or accepts a wrong length, shows up.
    base = enc_map([
        (enc_str(b"format"), enc_str(b"goose-task-plan")),
        (enc_str(b"count"), enc_uint(4)),
        (enc_str(b"edges"), enc_array([enc_array([enc_uint(0), enc_uint(2)])])),
    ])
    for cut in range(len(base)):
        rows.append((f"truncate-{cut}", base[:cut]))
    for pos in range(len(base)):
        for mask in (0x01, 0x80, 0xFF):
            mutated = bytearray(base)
            mutated[pos] ^= mask
            rows.append((f"flip-{pos}-{mask:02x}", bytes(mutated)))
    for extra in (b"\x00", b"\xc1", b"\x90", b"\xff"):
        rows.append((f"append-{extra.hex()}", base + extra))
    return rows


def write_corpus(rows: list[tuple[str, bytes]], path: Path) -> None:
    with path.open("wb") as handle:
        for _, data in rows:
            handle.write(struct.pack("<I", len(data)))
            handle.write(data)


# ---------------------------------------------------------------------------
# Running and comparing
# ---------------------------------------------------------------------------


def run(binary: Path, corpus_path: Path) -> str:
    result = subprocess.run([str(binary), str(corpus_path)], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"{binary.name} exited {result.returncode}\n{result.stderr}")
    return result.stdout


def parse(text: str) -> list[dict]:
    """Split the canonical output into one entry per record."""
    records: list[dict] = []
    current: dict | None = None
    for line in text.splitlines():
        if line.startswith("record "):
            if current is not None:
                raise SystemExit(f"record {current['index']} has no terminator")
            current = {"index": int(line.split()[1]), "tokens": [], "verdict": None}
            continue
        if current is None:
            raise SystemExit(f"line outside a record: {line!r}")
        if line == "end":
            current["verdict"] = "accept"
            records.append(current)
            current = None
        elif line.startswith("reject"):
            current["verdict"] = "reject"
            current["reason"] = line.split(maxsplit=1)[1] if " " in line else ""
            records.append(current)
            current = None
        else:
            current["tokens"].append(line)
    if current is not None:
        raise SystemExit(f"record {current['index']} has no terminator")
    return records


def f32_bits(token: str) -> int | None:
    """The numeric bits of an `f32 <hex>` canonical token, or None."""
    if not token.startswith("f32 "):
        return None
    raw = bytes.fromhex(token[4:])
    if len(raw) != 4:
        return None
    return int.from_bytes(raw, sys.byteorder)


def is_nan32(bits: int) -> bool:
    return (bits & 0x7F800000) == 0x7F800000 and (bits & 0x007FFFFF) != 0


def only_f32_nan_quieting(mine: list[str], theirs: list[str]) -> bool:
    """True when the only difference is msgpack-c quieting an f32 NaN.

    msgpack-c stores an f32 as a widened double and narrows it back on the way
    out. Widening a signalling NaN sets the quiet bit, so the payload it reports
    is the wire payload with bit 22 set. This library keeps the wire bits
    exactly. The difference is msgpack-c's lossy widening, not a disagreement
    about the document, so it is classified rather than counted as a defect.
    """
    if len(mine) != len(theirs):
        return False
    seen = False
    for a, b in zip(mine, theirs):
        if a == b:
            continue
        ba, bb = f32_bits(a), f32_bits(b)
        if ba is None or bb is None:
            return False
        if not (is_nan32(ba) and is_nan32(bb)):
            return False
        if bb != (ba | 0x00400000):
            return False
        seen = True
    return seen


BUDGET_REASONS = {
    "DepthLimit": "budget-depth",
    "NodeLimit": "budget-nodes",
    "InputLimit": "budget-input",
    "StrLimit": "budget-str",
    "BinLimit": "budget-bin",
    "ContainerLimit": "budget-container",
}


def classify(mine: dict, theirs: dict) -> tuple[str, str]:
    """Return (class, detail) for one record."""
    if mine["verdict"] == "accept" and theirs["verdict"] == "accept":
        if mine["tokens"] == theirs["tokens"]:
            return "agree-accept", ""
        if only_f32_nan_quieting(mine["tokens"], theirs["tokens"]):
            return "oracle-f32-nan-quieting", "msgpack-c widens f32 to double and quiets the NaN"
        for i, (a, b) in enumerate(zip(mine["tokens"], theirs["tokens"])):
            if a != b:
                return "DEFECT-tree", f"token {i}: goose {a!r} vs msgpack-c {b!r}"
        return "DEFECT-tree", (
            f"length {len(mine['tokens'])} vs {len(theirs['tokens'])}"
        )
    if mine["verdict"] == "reject" and theirs["verdict"] == "reject":
        return "agree-reject", f"{mine.get('reason', '')}/{theirs.get('reason', '')}"
    if mine["verdict"] == "reject" and theirs["verdict"] == "accept":
        reason = mine.get("reason", "")
        if reason == "InvalidUtf8":
            return "policy-utf8", reason
        if reason in BUDGET_REASONS:
            return BUDGET_REASONS[reason], reason
        return "DEFECT-we-reject-valid", reason
    if theirs.get("reason") == "depth-stack":
        # msgpack_unpack_next has a fixed 32-frame stack
        # (MSGPACK_EMBED_STACK_SIZE, unpack_template.h:141, marked FIXME) and
        # reports a deeper document as NOMEM. This library's limit is
        # configurable up to MAX_DEPTH = 256 and reports DepthLimit. The oracle
        # is the stricter side here, and the report says so.
        return "oracle-depth-limit-32", "msgpack-c fixed 32-frame stack"
    return "DEFECT-we-accept-invalid", theirs.get("reason", "")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--goose", required=True, help="Pinned goose compiler binary")
    parser.add_argument("--msgpack-c", type=Path, default=ROOT / ".build" / "thirdparty" / "msgpack-c",
                        help="msgpack-c checkout (default .build/thirdparty/msgpack-c)")
    parser.add_argument("--cc", default="clang")
    parser.add_argument("--seed", type=int, default=20261107)
    parser.add_argument("--trees", type=int, default=400, help="Random valid trees to add")
    parser.add_argument("--output", type=Path, default=ROOT / ".build" / "triangulate" / "report.json")
    args = parser.parse_args()

    msgpack_c = args.msgpack_c.resolve()
    if not (msgpack_c / "include" / "msgpack.h").exists():
        raise SystemExit(f"{msgpack_c} is not a msgpack-c checkout")
    head = subprocess.run(["git", "-C", str(msgpack_c), "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    if head != MSGPACK_C_COMMIT:
        raise SystemExit(f"msgpack-c is at {head}, expected {MSGPACK_C_COMMIT}")

    out_dir = args.output.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    corpus_path = out_dir / "corpus.bin"
    rows = corpus(args.seed, args.trees)
    write_corpus(rows, corpus_path)
    print(f"corpus: {len(rows)} records, {corpus_path.stat().st_size} bytes")

    mine_bin = out_dir / "triangulate"
    theirs_bin = out_dir / "triangulate-msgpackc"
    env = dict(os.environ)
    env.pop("LD_LIBRARY_PATH", None)

    build = subprocess.run(
        [args.goose, "build", str(ROOT / "tests" / "triangulate.goose"),
         "--standalone", "--cc", args.cc, "-O2", "-o", str(mine_bin)],
        capture_output=True, text=True, env=env)
    if build.returncode != 0:
        raise SystemExit(f"goose build failed:\n{build.stdout}\n{build.stderr}")
    # msgpack-c generates two headers from cmake templates. The only
    # substitutions are the two endianness flags, so generating them here is
    # deterministic and keeps the build out of cmake. Both are recorded in the
    # report.
    generated = {}
    for name in ("sysdep.h", "pack_template.h"):
        target = msgpack_c / "include" / "msgpack" / name
        if not target.exists():
            template = (msgpack_c / "cmake" / f"{name}.in").read_text()
            target.write_text(template.replace("@MSGPACK_ENDIAN_BIG_BYTE@", "0")
                                      .replace("@MSGPACK_ENDIAN_LITTLE_BYTE@", "1"))
        generated[name] = hashlib.sha256(target.read_bytes()).hexdigest()
    sources = sorted(str(p) for p in (msgpack_c / "src").glob("*.c"))
    build = subprocess.run(
        [args.cc, "-O2", "-I", str(msgpack_c / "include"),
         str(ROOT / "tests" / "triangulate_msgpackc.c"), *sources, "-o", str(theirs_bin)],
        capture_output=True, text=True, env=env)
    if build.returncode != 0:
        raise SystemExit(f"msgpack-c build failed:\n{build.stdout}\n{build.stderr}")

    mine = parse(run(mine_bin, corpus_path))
    theirs = parse(run(theirs_bin, corpus_path))
    if len(mine) != len(rows) or len(theirs) != len(rows):
        raise SystemExit(f"record count: corpus {len(rows)}, goose {len(mine)}, msgpack-c {len(theirs)}")

    counts: dict[str, int] = {}
    defects: list[dict] = []
    examples: dict[str, list[dict]] = {}
    for (name, data), a, b in zip(rows, mine, theirs):
        kind, detail = classify(a, b)
        counts[kind] = counts.get(kind, 0) + 1
        if kind.startswith("DEFECT"):
            defects.append({"name": name, "bytes": data.hex(), "class": kind, "detail": detail})
        elif kind not in ("agree-accept", "agree-reject"):
            examples.setdefault(kind, [])
            if len(examples[kind]) < 5:
                examples[kind].append({"name": name, "bytes": data.hex(), "detail": detail})

    report = {
        "schema": 1,
        "msgpack_c": {
            "commit": MSGPACK_C_COMMIT,
            "version": MSGPACK_C_VERSION,
            "generated_headers": generated,
        },
        "corpus": {
            "records": len(rows),
            "bytes": corpus_path.stat().st_size,
            "sha256": hashlib.sha256(corpus_path.read_bytes()).hexdigest(),
            "seed": args.seed,
            "random_trees": args.trees,
        },
        "counts": counts,
        "contract_differences": examples,
        "defects": defects,
        "binaries": {
            "goose": str(mine_bin),
            "goose_sha256": hashlib.sha256(mine_bin.read_bytes()).hexdigest(),
            "msgpack_c": str(theirs_bin),
            "msgpack_c_sha256": hashlib.sha256(theirs_bin.read_bytes()).hexdigest(),
        },
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")

    for kind in sorted(counts):
        print(f"  {kind}: {counts[kind]}")
    print(f"report: {args.output}")
    if defects:
        print(f"FAIL: {len(defects)} defect(s)", file=sys.stderr)
        for defect in defects[:10]:
            print(f"  {defect['name']} {defect['class']}: {defect['detail']}", file=sys.stderr)
        return 1
    print("triangulation ok: no defect")
    return 0


if __name__ == "__main__":
    sys.exit(main())
