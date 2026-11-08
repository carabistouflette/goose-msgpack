#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""An independent walk of the MessagePack wire format, used as a witness.

`tests/triangulate.py` compares this library with msgpack-c. When the two
disagree it has to decide whether the disagreement is a *contract difference*
(this library refuses on purpose, msgpack-c does not) or a *defect* (this
library refuses something it should have accepted). Deciding that from the
refusal code alone is circular: it trusts the code it is trying to check. A
refusal labelled `InvalidUtf8` would be excused even if the bytes were valid
UTF-8, and a refusal labelled `DepthLimit` would be excused even if the document
were shallow.

So the exception is granted only when a witness computed from the bytes and the
limits says the refusal was justified. This module is that witness. It is a
third implementation, written from the specification table, sharing no code with
`tests/oracle.py`, with `msgpack.goose`, or with msgpack-c.

It is deliberately not a decoder: it produces the canonical token form (so it
can also serve as a third opinion on accepted documents) plus the quantities the
budgets are stated in, and it never raises on malformed input.

    from wire import walk, WIDEST
    result = walk(data, WIDEST)
    result["status"]        # "ok" | "truncated" | "reserved" | "trailing"
    result["tokens"]        # canonical lines, only when status == "ok"
    result["nodes"]         # values seen
    result["max_frames"]    # deepest stack of open non-empty containers
    result["max_str"]       # largest declared str length
    result["max_bin"]       # largest declared bin length
    result["max_container"] # largest declared array/map element count
    result["invalid_utf8"]  # offsets of str payloads that are not valid UTF-8

`max_frames` counts *open non-empty* containers, which is the quantity
`max_depth` bounds. An empty container is a leaf: it opens no frame. That is the
same accounting `docs/api.md#depth-accounting` states, and it is why a document
whose deepest container is empty can be one level deeper than `max_depth`.
"""
from __future__ import annotations

import struct

# The widest limits the library allows, which is what tests/triangulate.goose
# configures. Kept here as literals so the witness does not import the library
# it is checking; `tests/triangulate.py` asserts they still match.
WIDEST = {
    "max_input_bytes": 67108864,
    "max_nodes": 1048576,
    "max_depth": 256,
    "max_str_bytes": 16777216,
    "max_bin_bytes": 16777216,
    "max_container_len": 1048576,
}

# msgpack_unpack_next's fixed frame stack (MSGPACK_EMBED_STACK_SIZE).
MSGPACK_C_STACK = 32


def _hex(data: bytes) -> str:
    return data.hex()


def walk(data: bytes, limits: dict | None = None) -> dict:
    """Walk one document. Never raises; reports what the bytes contain."""
    limits = limits or WIDEST
    total = len(data)
    at = 0
    tokens: list[str] = []
    nodes = 0
    max_frames = 0
    max_str = 0
    max_bin = 0
    max_container = 0
    invalid_utf8: list[int] = []
    status = "ok"

    remaining = 1
    stack: list[int] = []

    def take(count: int) -> bytes | None:
        nonlocal at
        if at + count > total:
            return None
        chunk = data[at:at + count]
        at += count
        return chunk

    def uint(width: int) -> int | None:
        chunk = take(width)
        return None if chunk is None else int.from_bytes(chunk, "big")

    while True:
        if remaining == 0:
            if not stack:
                break
            remaining = stack.pop()
            continue
        if at >= total:
            status = "truncated"
            break

        marker = data[at]
        at += 1
        nodes += 1

        # --- containers ---------------------------------------------------
        count: int | None = None
        is_map = False
        if 0x80 <= marker <= 0x8F:
            count, is_map = marker & 0x0F, True
        elif 0x90 <= marker <= 0x9F:
            count = marker & 0x0F
        elif marker in (0xDC, 0xDD):
            count = uint(2 if marker == 0xDC else 4)
        elif marker in (0xDE, 0xDF):
            count, is_map = uint(2 if marker == 0xDE else 4), True

        if count is not None:
            if count is None:  # pragma: no cover - guarded above
                status = "truncated"
                break
            items = count * 2 if is_map else count
            max_container = max(max_container, count)
            tokens.append(f"{'map' if is_map else 'array'} {count}")
            remaining -= 1
            if items > 0:
                stack.append(remaining)
                remaining = items
                max_frames = max(max_frames, len(stack))
            continue

        # --- scalars ------------------------------------------------------
        if marker <= 0x7F:
            tokens.append(f"int {marker}")
        elif marker >= 0xE0:
            tokens.append(f"int {marker - 0x100}")
        elif 0xA0 <= marker <= 0xBF:
            length = marker & 0x1F
            max_str = max(max_str, length)
            payload = take(length)
            if payload is None:
                status = "truncated"
                break
            tokens.append(f"str {length} {_hex(payload)}")
            if not _valid_utf8(payload):
                invalid_utf8.append(at - length)
        elif marker == 0xC0:
            tokens.append("nil")
        elif marker == 0xC1:
            status = "reserved"
            break
        elif marker in (0xC2, 0xC3):
            tokens.append(f"bool {1 if marker == 0xC3 else 0}")
        elif marker in (0xC4, 0xC5, 0xC6):
            length = uint(1 << (marker - 0xC4))
            if length is None:
                status = "truncated"
                break
            max_bin = max(max_bin, length)
            payload = take(length)
            if payload is None:
                status = "truncated"
                break
            tokens.append(f"bin {length} {_hex(payload)}")
        elif marker in (0xC7, 0xC8, 0xC9):
            width = 1 << (marker - 0xC7)
            length = uint(width)
            if length is None:
                status = "truncated"
                break
            head = take(1)
            if head is None:
                status = "truncated"
                break
            payload = take(length)
            if payload is None:
                status = "truncated"
                break
            tokens.append(f"ext {_i8(head[0])} {length} {_hex(payload)}")
        elif marker == 0xCA:
            chunk = take(4)
            if chunk is None:
                status = "truncated"
                break
            tokens.append(f"f32 {_hex(chunk[::-1])}")
        elif marker == 0xCB:
            chunk = take(8)
            if chunk is None:
                status = "truncated"
                break
            tokens.append(f"f64 {_hex(chunk[::-1])}")
        elif 0xCC <= marker <= 0xCF:
            value = uint(1 << (marker - 0xCC))
            if value is None:
                status = "truncated"
                break
            tokens.append(f"int {value}" if value <= 0x7FFF_FFFF_FFFF_FFFF else f"uint {value}")
        elif 0xD0 <= marker <= 0xD3:
            width = 1 << (marker - 0xD0)
            value = uint(width)
            if value is None:
                status = "truncated"
                break
            if value >> (width * 8 - 1):
                value -= 1 << (width * 8)
            tokens.append(f"int {value}")
        elif 0xD4 <= marker <= 0xD8:
            length = 1 << (marker - 0xD4)
            head = take(1)
            if head is None:
                status = "truncated"
                break
            payload = take(length)
            if payload is None:
                status = "truncated"
                break
            tokens.append(f"ext {_i8(head[0])} {length} {_hex(payload)}")
        elif marker in (0xD9, 0xDA, 0xDB):
            length = uint(1 << (marker - 0xD9))
            if length is None:
                status = "truncated"
                break
            max_str = max(max_str, length)
            payload = take(length)
            if payload is None:
                status = "truncated"
                break
            tokens.append(f"str {length} {_hex(payload)}")
            if not _valid_utf8(payload):
                invalid_utf8.append(at - length)
        else:  # pragma: no cover - every marker is covered above
            raise AssertionError(f"unhandled marker {marker:#04x}")

        remaining -= 1

    if status == "ok" and at != total:
        status = "trailing"

    return {
        "status": status,
        "tokens": tokens if status == "ok" else [],
        "nodes": nodes,
        "max_frames": max_frames,
        "max_str": max_str,
        "max_bin": max_bin,
        "max_container": max_container,
        "invalid_utf8": invalid_utf8,
        "consumed": at,
        "total": total,
    }


def _i8(byte: int) -> int:
    return byte - 0x100 if byte >= 0x80 else byte


def _valid_utf8(payload: bytes) -> bool:
    """Strict UTF-8, as the specification requires for the str family.

    Python's decoder rejects overlong forms, surrogates and code points above
    U+10FFFF, which is exactly the set the library rejects.
    """
    try:
        payload.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


def budget_exceeded(result: dict, reason: str, limits: dict | None = None) -> tuple[bool, str]:
    """Is a budget refusal justified by the bytes?

    Returns (justified, explanation). The comparison is `>` because each limit
    is the largest value the reader accepts: it refuses the value that would
    exceed it, not the value that reaches it.
    """
    limits = limits or WIDEST
    if reason == "InputLimit":
        over = result["total"] > limits["max_input_bytes"]
        return over, f"input {result['total']} vs limit {limits['max_input_bytes']}"
    if reason == "NodeLimit":
        over = result["nodes"] > limits["max_nodes"]
        return over, f"nodes {result['nodes']} vs limit {limits['max_nodes']}"
    if reason == "DepthLimit":
        over = result["max_frames"] > limits["max_depth"]
        return over, f"open frames {result['max_frames']} vs limit {limits['max_depth']}"
    if reason == "StrLimit":
        over = result["max_str"] > limits["max_str_bytes"]
        return over, f"str {result['max_str']} vs limit {limits['max_str_bytes']}"
    if reason == "BinLimit":
        over = result["max_bin"] > limits["max_bin_bytes"]
        return over, f"bin {result['max_bin']} vs limit {limits['max_bin_bytes']}"
    if reason == "ContainerLimit":
        over = result["max_container"] > limits["max_container_len"]
        return over, f"container {result['max_container']} vs limit {limits['max_container_len']}"
    return False, f"unknown budget reason {reason}"


def main() -> int:
    """Self-check: the witness must agree with the specification on known cases."""
    cases = [
        (b"\xc0", "ok", ["nil"]),
        (b"\x01", "ok", ["int 1"]),
        (b"\xff", "ok", ["int -1"]),
        (b"\x90", "ok", ["array 0"]),
        (b"\x80", "ok", ["map 0"]),
        (b"\x91\x90", "ok", ["array 1", "array 0"]),
        (b"\x81\x90\x90", "ok", ["map 1", "array 0", "array 0"]),
        (b"\xc1", "reserved", []),
        (b"", "truncated", []),
        (b"\x92\x01", "truncated", []),
        (b"\x01\x02", "trailing", []),
        (b"\xa1a", "ok", ["str 1 61"]),
        (b"\xa1\xff", "ok", ["str 1 ff"]),
        (b"\xc4\x01\xff", "ok", ["bin 1 ff"]),
        (b"\xd4\xf9\x01", "ok", ["ext -7 1 01"]),
        (b"\xca\x3f\xc0\x00\x00", "ok", ["f32 0000c03f"]),
        (b"\xcb\x3f\xf8\x00\x00\x00\x00\x00\x00", "ok", ["f64 000000000000f83f"]),
        (b"\xcf\xff\xff\xff\xff\xff\xff\xff\xff", "ok", ["uint 18446744073709551615"]),
        (b"\xd3\x80\x00\x00\x00\x00\x00\x00\x00", "ok", ["int -9223372036854775808"]),
    ]
    failures = 0
    for data, want_status, want_tokens in cases:
        got = walk(data)
        if got["status"] != want_status or got["tokens"] != want_tokens:
            print(f"FAIL {data.hex()}: {got['status']} {got['tokens']} "
                  f"!= {want_status} {want_tokens}")
            failures += 1

    # Depth accounting: 300 nested non-empty arrays open 300 frames; the same
    # chain ending in an empty array opens 300 frames too, because the empty
    # array is a leaf that opens none.
    deep = walk(b"\x91" * 300 + b"\x01")
    if deep["max_frames"] != 300:
        print(f"FAIL depth: {deep['max_frames']} != 300")
        failures += 1
    deep_empty = walk(b"\x91" * 300 + b"\x90")
    if deep_empty["max_frames"] != 300:
        print(f"FAIL depth-empty: {deep_empty['max_frames']} != 300")
        failures += 1
    if deep_empty["nodes"] != 301:
        print(f"FAIL depth-empty nodes: {deep_empty['nodes']} != 301")
        failures += 1

    # UTF-8 witness.
    if walk(b"\xa1\xff")["invalid_utf8"] != [1]:
        print("FAIL utf8: lone 0xff not flagged")
        failures += 1
    if walk(b"\xa2\xc3\xa9")["invalid_utf8"]:
        print("FAIL utf8: valid 2-byte sequence flagged")
        failures += 1
    if walk(b"\xa3\xed\xa0\x80")["invalid_utf8"] != [1]:
        print("FAIL utf8: surrogate not flagged")
        failures += 1

    # Budget witness.
    justified, why = budget_exceeded(walk(b"\x91" * 257 + b"\x01"), "DepthLimit")
    if not justified:
        print(f"FAIL budget: depth 257 not justified ({why})")
        failures += 1
    justified, why = budget_exceeded(walk(b"\x91" * 256 + b"\x01"), "DepthLimit")
    if justified:
        print(f"FAIL budget: depth 256 wrongly justified ({why})")
        failures += 1

    if failures:
        print(f"{failures} witness self-check failure(s)")
        return 1
    print(f"wire witness ok: {len(cases)} marker cases, depth, utf8 and budget checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
