#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent MessagePack differential oracle for goose-msgpack.

This file implements the documented contract a second time, from the MessagePack
specification and docs/api.md, without reading msgpack.goose. It generates a
seeded corpus, computes the expected response for every case, runs the Goose
driver in tests/oracle.goose over stdin, and compares line by line.

The response for one case is either

    OK <canonical hex>          one value decoded, re-encoded in shortest form
    E Error.<Name> <offset>     the reader rejected the input at that offset
    W Error.<Name>              the writer rejected the re-encoding

Nothing here is a performance measurement, a coverage-guided fuzzer or a
certification. It is a finite, seeded differential corpus.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SEED = 20261107

# (max_input, max_output, max_nodes, max_depth, max_str, max_bin, max_container)
DEFAULT = (1048576, 1048576, 65536, 32, 262144, 262144, 65536)
HARD = (67108864, 67108864, 1048576, 256, 16777216, 16777216, 1048576)


class Failure(Exception):
    def __init__(self, name: str, offset: int):
        super().__init__(f"{name} at {offset}")
        self.name = name
        self.offset = offset


# ---- UTF-8 -------------------------------------------------------------


def valid_utf8(data: bytes) -> bool:
    """Strict UTF-8: no overlong form, no surrogate, nothing above U+10FFFF."""
    i = 0
    n = len(data)
    while i < n:
        b = data[i]
        if b < 0x80:
            i += 1
            continue
        if b < 0xC2:
            return False
        if b < 0xE0:
            if i + 1 >= n or not 0x80 <= data[i + 1] <= 0xBF:
                return False
            i += 2
            continue
        if b < 0xF0:
            if i + 2 >= n:
                return False
            b1 = data[i + 1]
            if not 0x80 <= b1 <= 0xBF:
                return False
            if b == 0xE0 and b1 < 0xA0:
                return False
            if b == 0xED and b1 > 0x9F:
                return False
            if not 0x80 <= data[i + 2] <= 0xBF:
                return False
            i += 3
            continue
        if b < 0xF5:
            if i + 3 >= n:
                return False
            b1 = data[i + 1]
            if not 0x80 <= b1 <= 0xBF:
                return False
            if b == 0xF0 and b1 < 0x90:
                return False
            if b == 0xF4 and b1 > 0x8F:
                return False
            if not 0x80 <= data[i + 2] <= 0xBF:
                return False
            if not 0x80 <= data[i + 3] <= 0xBF:
                return False
            i += 4
            continue
        return False
    return True


def utf8_self_check() -> int:
    """Cross-check the validator above against CPython's strict codec."""
    rng = random.Random(SEED ^ 0x5555)
    checked = 0
    samples = [b"", b"\x7f", b"\xc2\x80", b"\xdf\xbf", b"\xe0\xa0\x80", b"\xed\x9f\xbf",
               b"\xee\x80\x80", b"\xef\xbf\xbf", b"\xf0\x90\x80\x80", b"\xf4\x8f\xbf\xbf",
               b"\x80", b"\xc0\x80", b"\xc1\xbf", b"\xe0\x80\x80", b"\xed\xa0\x80",
               b"\xf0\x80\x80\x80", b"\xf4\x90\x80\x80", b"\xf5\x80\x80\x80", b"\xc2",
               b"\xe1\x80", b"\xf0\x90\x80", b"\xef\xb7\x90", b"\xef\xbf\xbe"]
    for _ in range(4000):
        samples.append(rng.randbytes(rng.randrange(0, 7)))
    for sample in samples:
        try:
            sample.decode("utf-8", "strict")
            reference = True
        except UnicodeDecodeError:
            reference = False
        if valid_utf8(sample) != reference:
            raise AssertionError(f"UTF-8 validator disagrees with CPython on {sample.hex()}")
        checked += 1
    return checked


# ---- reader ------------------------------------------------------------


def sign(raw: int, width: int) -> int:
    bits = width * 8
    if raw >= 1 << (bits - 1):
        return raw - (1 << bits)
    return raw


class Reader:
    def __init__(self, data: bytes, limits):
        self.data = data
        self.limits = limits
        self.at = 0
        self.nodes = 0
        self.depth = 0
        self.remaining: list[int] = []
        self.started = False
        self.complete = False
        self.tokens: list[tuple] = []
        if len(data) > limits[0]:
            raise Failure("InputLimit", 0)

    # -- bookkeeping
    def close_completed(self) -> None:
        while self.remaining and self.remaining[-1] == 0:
            self.remaining.pop()
            self.depth -= 1

    def scalar(self, token: tuple) -> None:
        if self.remaining:
            self.remaining[-1] -= 1
        self.close_completed()
        if self.depth == 0:
            self.complete = True
        self.tokens.append(token)

    def open(self, token: tuple, elements: int, start: int) -> None:
        if self.remaining:
            self.remaining[-1] -= 1
        if elements > 0:
            if self.depth >= self.limits[3]:
                raise Failure("DepthLimit", start)
            self.remaining.append(elements)
            self.depth += 1
        else:
            self.close_completed()
            if self.depth == 0:
                self.complete = True
        self.tokens.append(token)

    # -- byte access
    def need(self, k: int) -> bool:
        return len(self.data) - self.at >= k

    def be(self, at: int, width: int) -> int:
        return int.from_bytes(self.data[at:at + width], "big")

    def take(self, k: int, limit: int, name: str, start: int) -> bytes:
        if k > limit:
            raise Failure(name, start)
        if not self.need(k):
            raise Failure("Truncated", start)
        view = self.data[self.at:self.at + k]
        self.at += k
        return view

    def payload(self, width: int, limit: int, name: str, start: int) -> bytes:
        if not self.need(width):
            raise Failure("Truncated", start)
        k = self.be(self.at, width)
        self.at += width
        return self.take(k, limit, name, start)

    def str_body(self, view: bytes, start: int) -> None:
        if not valid_utf8(view):
            raise Failure("InvalidUtf8", start)
        self.scalar(("str", view))

    def ext_body(self, k: int, start: int) -> None:
        if k > self.limits[5]:
            raise Failure("BinLimit", start)
        if not self.need(k + 1):
            raise Failure("Truncated", start)
        typ = self.data[self.at]
        self.at += 1
        view = self.data[self.at:self.at + k]
        self.at += k
        self.scalar(("ext", sign(typ, 1), view))

    def array_body(self, k: int, start: int) -> None:
        if k > self.limits[6]:
            raise Failure("ContainerLimit", start)
        if k > len(self.data) - self.at:
            raise Failure("Truncated", start)
        self.open(("array", k), k, start)

    def map_body(self, k: int, start: int) -> None:
        if k > self.limits[6]:
            raise Failure("ContainerLimit", start)
        if k > (len(self.data) - self.at) // 2:
            raise Failure("Truncated", start)
        self.open(("map", k), k * 2, start)

    def next(self) -> None:
        if self.complete:
            raise Failure("InvalidState", self.at)
        if self.at >= len(self.data):
            raise Failure("Truncated", self.at)
        if self.nodes >= self.limits[2]:
            raise Failure("NodeLimit", self.at)
        start = self.at
        m = self.data[self.at]
        self.nodes += 1
        self.started = True
        if m <= 0x7F:
            self.at += 1
            self.scalar(("uint", m))
        elif m >= 0xE0:
            self.at += 1
            self.scalar(("int", m - 0x100))
        elif 0xA0 <= m <= 0xBF:
            k = m & 0x1F
            self.at += 1
            self.str_body(self.take(k, self.limits[4], "StrLimit", start), start)
        elif 0x90 <= m <= 0x9F:
            self.at += 1
            self.array_body(m & 0x0F, start)
        elif 0x80 <= m <= 0x8F:
            self.at += 1
            self.map_body(m & 0x0F, start)
        elif m == 0xC0:
            self.at += 1
            self.scalar(("nil",))
        elif m == 0xC1:
            raise Failure("Reserved", start)
        elif m == 0xC2:
            self.at += 1
            self.scalar(("bool", False))
        elif m == 0xC3:
            self.at += 1
            self.scalar(("bool", True))
        elif 0xC4 <= m <= 0xC6:
            width = 1 << (m - 0xC4)
            self.at += 1
            self.scalar(("bin", self.payload(width, self.limits[5], "BinLimit", start)))
        elif 0xC7 <= m <= 0xC9:
            width = 1 << (m - 0xC7)
            self.at += 1
            if not self.need(width):
                raise Failure("Truncated", start)
            k = self.be(self.at, width)
            self.at += width
            self.ext_body(k, start)
        elif m == 0xCA:
            self.at += 1
            if not self.need(4):
                raise Failure("Truncated", start)
            bits = self.be(self.at, 4)
            self.at += 4
            self.scalar(("f32", bits))
        elif m == 0xCB:
            self.at += 1
            if not self.need(8):
                raise Failure("Truncated", start)
            bits = self.be(self.at, 8)
            self.at += 8
            self.scalar(("f64", bits))
        elif 0xCC <= m <= 0xCF:
            width = 1 << (m - 0xCC)
            self.at += 1
            if not self.need(width):
                raise Failure("Truncated", start)
            raw = self.be(self.at, width)
            self.at += width
            self.scalar(("uint", raw))
        elif 0xD0 <= m <= 0xD3:
            width = 1 << (m - 0xD0)
            self.at += 1
            if not self.need(width):
                raise Failure("Truncated", start)
            raw = self.be(self.at, width)
            self.at += width
            self.scalar(("int", sign(raw, width)))
        elif 0xD4 <= m <= 0xD8:
            self.at += 1
            self.ext_body(1 << (m - 0xD4), start)
        elif 0xD9 <= m <= 0xDB:
            width = 1 << (m - 0xD9)
            self.at += 1
            self.str_body(self.payload(width, self.limits[4], "StrLimit", start), start)
        elif m in (0xDC, 0xDD):
            width = 2 if m == 0xDC else 4
            self.at += 1
            if not self.need(width):
                raise Failure("Truncated", start)
            k = self.be(self.at, width)
            self.at += width
            self.array_body(k, start)
        else:  # 0xDE, 0xDF
            width = 2 if m == 0xDE else 4
            self.at += 1
            if not self.need(width):
                raise Failure("Truncated", start)
            k = self.be(self.at, width)
            self.at += width
            self.map_body(k, start)

    def finish(self):
        if not self.started:
            return ("InvalidState", self.at)
        if not self.complete:
            if self.at >= len(self.data):
                return ("Truncated", self.at)
            return ("Unbalanced", self.at)
        if self.at < len(self.data):
            return ("TrailingBytes", self.at)
        return None


# ---- canonical writer --------------------------------------------------


def enc_uint(v: int) -> bytes:
    if v <= 0x7F:
        return bytes([v])
    if v <= 0xFF:
        return b"\xcc" + bytes([v])
    if v <= 0xFFFF:
        return b"\xcd" + v.to_bytes(2, "big")
    if v <= 0xFFFFFFFF:
        return b"\xce" + v.to_bytes(4, "big")
    return b"\xcf" + v.to_bytes(8, "big")


def enc_int(v: int) -> bytes:
    if v >= 0:
        return enc_uint(v)
    if v >= -32:
        return bytes([v & 0xFF])
    if v >= -128:
        return b"\xd0" + (v & 0xFF).to_bytes(1, "big")
    if v >= -32768:
        return b"\xd1" + (v & 0xFFFF).to_bytes(2, "big")
    if v >= -2147483648:
        return b"\xd2" + (v & 0xFFFFFFFF).to_bytes(4, "big")
    return b"\xd3" + (v & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "big")


def enc_str(v: bytes) -> bytes:
    n = len(v)
    if n <= 31:
        return bytes([0xA0 | n]) + v
    if n <= 0xFF:
        return b"\xd9" + bytes([n]) + v
    if n <= 0xFFFF:
        return b"\xda" + n.to_bytes(2, "big") + v
    return b"\xdb" + n.to_bytes(4, "big") + v


def enc_bin(v: bytes) -> bytes:
    n = len(v)
    if n <= 0xFF:
        return b"\xc4" + bytes([n]) + v
    if n <= 0xFFFF:
        return b"\xc5" + n.to_bytes(2, "big") + v
    return b"\xc6" + n.to_bytes(4, "big") + v


def enc_ext(typ: int, v: bytes) -> bytes:
    n = len(v)
    fixed = {1: 0xD4, 2: 0xD5, 4: 0xD6, 8: 0xD7, 16: 0xD8}
    if n in fixed:
        return bytes([fixed[n], typ & 0xFF]) + v
    if n <= 0xFF:
        return b"\xc7" + bytes([n, typ & 0xFF]) + v
    if n <= 0xFFFF:
        return b"\xc8" + n.to_bytes(2, "big") + bytes([typ & 0xFF]) + v
    return b"\xc9" + n.to_bytes(4, "big") + bytes([typ & 0xFF]) + v


def enc_array(n: int) -> bytes:
    if n <= 15:
        return bytes([0x90 | n])
    if n <= 0xFFFF:
        return b"\xdc" + n.to_bytes(2, "big")
    return b"\xdd" + n.to_bytes(4, "big")


def enc_map(n: int) -> bytes:
    if n <= 15:
        return bytes([0x80 | n])
    if n <= 0xFFFF:
        return b"\xde" + n.to_bytes(2, "big")
    return b"\xdf" + n.to_bytes(4, "big")


def encode(tokens) -> bytes:
    out = bytearray()
    for t in tokens:
        kind = t[0]
        if kind == "nil":
            out.append(0xC0)
        elif kind == "bool":
            out.append(0xC3 if t[1] else 0xC2)
        elif kind == "uint":
            out += enc_uint(t[1])
        elif kind == "int":
            out += enc_int(t[1])
        elif kind == "f32":
            out.append(0xCA)
            out += t[1].to_bytes(4, "big")
        elif kind == "f64":
            out.append(0xCB)
            out += t[1].to_bytes(8, "big")
        elif kind == "str":
            out += enc_str(t[1])
        elif kind == "bin":
            out += enc_bin(t[1])
        elif kind == "array":
            out += enc_array(t[1])
        elif kind == "map":
            out += enc_map(t[1])
        elif kind == "ext":
            out += enc_ext(t[1], t[2])
        else:
            raise AssertionError(kind)
    return bytes(out)


def response(limits, data: bytes) -> str:
    try:
        r = Reader(data, limits)
        while not r.complete:
            r.next()
        error = r.finish()
        if error is not None:
            return f"E Error.{error[0]} {error[1]}"
        canonical = encode(r.tokens)
        # The writer applies the same budgets; only the output cap can differ,
        # because the canonical form is never longer than the input.
        if len(canonical) > limits[1]:
            return "W Error.OutputLimit"
        return "OK " + canonical.hex()
    except Failure as f:
        return f"E Error.{f.name} {f.offset}"


# ---- corpus ------------------------------------------------------------


def flatten(node) -> list[tuple]:
    out: list[tuple] = []

    def walk(n):
        if n[0] == "array":
            out.append(("array", len(n[1])))
            for child in n[1]:
                walk(child)
        elif n[0] == "map":
            out.append(("map", len(n[1])))
            for key, value in n[1]:
                walk(key)
                walk(value)
        else:
            out.append(n)

    walk(node)
    return out


def random_text(rng, n: int) -> bytes:
    """`n` bytes of valid UTF-8, mixing ASCII and multi-byte scalars."""
    out = bytearray()
    while len(out) < n:
        room = n - len(out)
        pick = rng.randrange(4)
        if pick == 0 or room < 2:
            out.append(rng.randrange(0x20, 0x7F))
        elif pick == 1 and room >= 2:
            out += chr(rng.randrange(0x80, 0x800)).encode()
        elif pick == 2 and room >= 3:
            out += chr(rng.randrange(0x800, 0xD800)).encode()
        elif room >= 4:
            out += chr(rng.randrange(0x10000, 0x110000)).encode()
        else:
            out.append(rng.randrange(0x20, 0x7F))
    return bytes(out[:n]) if valid_utf8(bytes(out[:n])) else b"x" * n


def random_node(rng, depth: int):
    kinds = ["nil", "bool", "uint", "int", "f32", "f64", "str", "bin", "ext"]
    if depth > 0:
        kinds += ["array", "map", "array", "map"]
    kind = rng.choice(kinds)
    if kind == "nil":
        return ("nil",)
    if kind == "bool":
        return ("bool", rng.randrange(2) == 1)
    if kind == "uint":
        return ("uint", rng.choice([0, 1, 127, 128, 255, 256, 65535, 65536,
                                    4294967295, 4294967296, 2**64 - 1,
                                    rng.randrange(0, 2**64)]))
    if kind == "int":
        return ("int", rng.choice([-1, -32, -33, -128, -129, -32768, -32769,
                                   -2147483648, -2147483649, -2**63,
                                   rng.randrange(-2**63, 2**63)]))
    if kind == "f32":
        return ("f32", rng.choice([0, 0x80000000, 0x3FC00000, 0x7F800000,
                                   0x7FC00000, rng.randrange(0, 2**32)]))
    if kind == "f64":
        return ("f64", rng.choice([0, 0x8000000000000000, 0x3FF8000000000000,
                                   0x7FF0000000000000, 0x7FF8000000000000,
                                   rng.randrange(0, 2**64)]))
    if kind == "str":
        return ("str", random_text(rng, rng.choice([0, 1, 2, 3, 15, 16, 31, 32,
                                                    rng.randrange(0, 40)])))
    if kind == "bin":
        return ("bin", rng.randbytes(rng.choice([0, 1, 2, 15, 16, 255, 256,
                                                 rng.randrange(0, 40)])))
    if kind == "ext":
        return ("ext", rng.randrange(-128, 128),
                rng.randbytes(rng.choice([0, 1, 2, 3, 4, 8, 16, 17, rng.randrange(0, 20)])))
    if kind == "array":
        return ("array", [random_node(rng, depth - 1) for _ in range(rng.randrange(0, 5))])
    return ("map", [(random_node(rng, depth - 1), random_node(rng, depth - 1))
                    for _ in range(rng.randrange(0, 4))])


def wide_encode(tokens) -> bytes:
    """The same values with every integer in its widest form."""
    out = bytearray()
    for t in tokens:
        kind = t[0]
        if kind == "uint":
            out += b"\xcf" + t[1].to_bytes(8, "big")
        elif kind == "int":
            out += b"\xd3" + (t[1] & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "big")
        elif kind == "str":
            out += b"\xdb" + len(t[1]).to_bytes(4, "big") + t[1]
        elif kind == "bin":
            out += b"\xc6" + len(t[1]).to_bytes(4, "big") + t[1]
        elif kind == "array":
            out += b"\xdd" + t[1].to_bytes(4, "big")
        elif kind == "map":
            out += b"\xdf" + t[1].to_bytes(4, "big")
        else:
            out += encode([t])
    return bytes(out)


def corpus(target: int = 100000):
    rng = random.Random(SEED)
    cases: list[tuple[str, tuple, bytes]] = []

    def add(label: str, data: bytes, limits=DEFAULT):
        cases.append((label, limits, data))

    # 1. Random values, canonically encoded: decode and re-encode is identity.
    while len(cases) < target * 45 // 100:
        node = random_node(rng, rng.randrange(0, 4))
        tokens = flatten(node)
        add(f"value-{len(cases)}", encode(tokens))

    # 2. The same values in widest form: the canonical form is the shortest.
    while len(cases) < target * 70 // 100:
        node = random_node(rng, rng.randrange(0, 4))
        tokens = flatten(node)
        add(f"wide-{len(cases)}", wide_encode(tokens))

    # 3. Single-byte mutations of valid encodings.
    seeds = []
    for _ in range(400):
        node = random_node(rng, rng.randrange(0, 3))
        seeds.append(encode(flatten(node)))
    while len(cases) < target:
        base = bytearray(rng.choice(seeds))
        if not base:
            base = bytearray(b"\x01")
        at = rng.randrange(len(base))
        base[at] = rng.randrange(256)
        add(f"mutate-{len(cases)}", bytes(base))

    # 4. Every proper prefix of a valid encoding is truncated or complete.
    for base in seeds[:120]:
        for cut in range(len(base)):
            add(f"prefix-{len(base)}-{cut}", base[:cut])

    # 5. Length boundaries for str, bin, ext, array and map.
    for n in (0, 1, 15, 16, 31, 32, 127, 128, 255, 256, 65535, 65536):
        add(f"str-{n}", encode([("str", b"a" * n)]))
        add(f"bin-{n}", encode([("bin", b"\x00" * n)]))
        add(f"ext-{n}", encode([("ext", 7, b"\x01" * n)]))
        add(f"array-{n}", encode([("array", n)] + [("nil",)] * n))
        add(f"map-{n}", encode([("map", n)] + [("nil",), ("nil",)] * n))

    # 6. Budget boundaries: each limit at threshold-1, threshold, threshold+1.
    probes = [
        ("input", 0, lambda v: (v, *DEFAULT[1:])),
        ("output", 1, lambda v: (DEFAULT[0], v, *DEFAULT[2:])),
        ("nodes", 2, lambda v: (*DEFAULT[:2], v, *DEFAULT[3:])),
        ("depth", 3, lambda v: (*DEFAULT[:3], v, *DEFAULT[4:])),
        ("str", 4, lambda v: (*DEFAULT[:4], v, *DEFAULT[5:])),
        ("bin", 5, lambda v: (*DEFAULT[:5], v, *DEFAULT[6:])),
        ("container", 6, lambda v: (*DEFAULT[:6], v)),
    ]
    budget_inputs = [
        b"\x01",
        b"\x92\x01\x02",
        b"\x91\x91\x91\x01",
        b"\xa3abc",
        b"\xc4\x03abc",
        b"\x93\x01\x02\x03",
        b"\x82\x01\x02\x03\x04",
        b"\xd4\x01\x7f",
        b"\xcb\x3f\xf8\x00\x00\x00\x00\x00\x00",
    ]
    for name, index, make in probes:
        for data in budget_inputs:
            exact = {
                "input": len(data),
                "output": len(data),
                "nodes": 1 + data.count(b"\x01"),
                "depth": 4,
                "str": 3,
                "bin": 3,
                "container": 3,
            }[name]
            for delta in (-1, 0, 1):
                value = max(0, exact + delta)
                add(f"budget-{name}-{delta}-{data.hex()}", data, make(value))

    # 7. Invalid UTF-8 inside str markers, and the same bytes as bin.
    bad = [b"\xff", b"\x80", b"\xc0\x80", b"\xc1\xbf", b"\xe0\x80\x80", b"\xe0\x9f\xbf",
           b"\xed\xa0\x80", b"\xed\xbf\xbf", b"\xf0\x80\x80\x80", b"\xf0\x8f\xbf\xbf",
           b"\xf4\x90\x80\x80", b"\xf5\x80\x80\x80", b"\xc2", b"\xe1\x80", b"\xf0\x90\x80"]
    for payload in bad:
        add(f"utf8-fixstr-{payload.hex()}", bytes([0xA0 | len(payload)]) + payload)
        add(f"utf8-str8-{payload.hex()}", b"\xd9" + bytes([len(payload)]) + payload)
        add(f"utf8-str16-{payload.hex()}", b"\xda" + len(payload).to_bytes(2, "big") + payload)
        add(f"utf8-bin-{payload.hex()}", b"\xc4" + bytes([len(payload)]) + payload)
    good = [b"\xef\xb7\x90", b"\xef\xbf\xbe", b"\xef\xbf\xbf", b"\xf0\x9f\xbf\xbe",
            b"\xf4\x8f\xbf\xbf", b"\xc2\x80", b"\xdf\xbf", b"\xe0\xa0\x80"]
    for payload in good:
        add(f"utf8-good-{payload.hex()}", bytes([0xA0 | len(payload)]) + payload)

    # 8. Structural edge cases.
    add("empty", b"")
    add("reserved", b"\xc1")
    add("trailing", b"\x01\x02")
    add("trailing-nested", b"\x91\x01\x02")
    add("unbalanced", b"\x92\x01")
    add("deep-32", b"\x91" * 32 + b"\x01")
    add("deep-33", b"\x91" * 33 + b"\x01")
    add("deep-33-shallow", b"\x91" * 33 + b"\x01", (*DEFAULT[:3], 40, *DEFAULT[4:]))
    add("huge-array", b"\xdd\xff\xff\xff\xff")
    add("huge-map", b"\xdf\xff\xff\xff\xff")
    add("huge-str", b"\xdb\xff\xff\xff\xff")
    add("huge-bin", b"\xc6\xff\xff\xff\xff")
    add("huge-ext", b"\xc9\xff\xff\xff\xff\x01")
    add("map-odd", b"\x81\x01")
    add("fixext-16", b"\xd8\x01" + b"\x00" * 16)
    add("ext-0", b"\xc7\x00\x05")
    add("noncanonical-int", b"\xd1\x00\x05")
    add("noncanonical-neg", b"\xd3\xff\xff\xff\xff\xff\xff\xff\xff")

    return cases


# ---- driver ------------------------------------------------------------


def source_identity() -> dict:
    files = [ROOT / "msgpack.goose", ROOT / "tests" / "oracle.goose", Path(__file__).resolve()]
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--goose", type=Path, help="Run tests/oracle.goose through this compiler")
    group.add_argument("--binary", type=Path, help="Use an already built driver")
    parser.add_argument("--debug", action="store_true", help="Pass --debug to the compiler")
    parser.add_argument("--cases", type=int, default=100000, help="Target corpus size")
    parser.add_argument("--output", type=Path, default=ROOT / ".build" / "oracle.json")
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    if args.debug and not args.goose:
        parser.error("--debug requires --goose")

    utf8_checked = utf8_self_check()
    cases = corpus(args.cases)
    payload = "".join(
        "R " + " ".join(str(x) for x in limits) + " " + data.hex() + "\n"
        for _, limits, data in cases
    )
    expected = [response(limits, data) for _, limits, data in cases]

    before = source_identity()
    program = (args.binary or args.goose).resolve()
    program_hash = hashlib.sha256(program.read_bytes()).hexdigest()
    command = [str(program)] if args.binary else [
        str(program), "run", "tests/oracle.goose", *(["--debug"] if args.debug else [])]
    result = subprocess.run(command, input=payload, capture_output=True, text=True,
                            cwd=ROOT, timeout=args.timeout)
    if result.returncode or result.stderr:
        raise AssertionError(
            f"driver exit {result.returncode}: stdout={result.stdout[-1500:]!r} "
            f"stderr={result.stderr[-3000:]!r}")
    actual = result.stdout.splitlines()
    if actual != expected:
        index = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b),
                     min(len(actual), len(expected)))
        label = cases[index][0] if index < len(cases) else "extra-output"
        raise AssertionError(
            f"{label} at {index}: actual={actual[index:index + 1]!r}, "
            f"expected={expected[index:index + 1]!r}; outputs={len(actual)}/{len(expected)}")
    if source_identity() != before or hashlib.sha256(program.read_bytes()).hexdigest() != program_hash:
        raise RuntimeError("Source or executable changed during oracle execution; result rejected")

    record = {
        "seed": SEED,
        "cases": len(cases),
        "utf8_self_check_cases": utf8_checked,
        "corpus_sha256": hashlib.sha256(payload.encode()).hexdigest(),
        "expected_sha256": hashlib.sha256(("\n".join(expected) + "\n").encode()).hexdigest(),
        "stdout_sha256": hashlib.sha256(result.stdout.encode()).hexdigest(),
        "python": sys.version,
        "platform": platform.platform(),
        "command": command,
        "executable_sha256": program_hash,
        "source_sha256": before,
        "notes": [
            "Independent second implementation of the documented contract, written from the "
            "MessagePack specification and docs/api.md",
            "Finite seeded differential corpus, not coverage-guided fuzzing or certification",
            "The UTF-8 validator is cross-checked against CPython's strict codec",
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(record, indent=2) + "\n")
    print(f"msgpack oracle: {len(cases)} differential cases passed; "
          f"corpus {record['corpus_sha256'][:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
