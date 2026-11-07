# API contract

Everything here is checked by [tests/api.goose](../tests/api.goose) (400
assertions) and by the differential oracle in
[tests/oracle.py](../tests/oracle.py) (102723 cases). A statement that is not
covered by one of those two is marked **not enforced**.

## Types

```goose
struct Limits {
    max_input_bytes:   i64 = 1048576,
    max_output_bytes:  i64 = 1048576,
    max_nodes:         i64 = 65536,
    max_depth:         i64 = 32,
    max_str_bytes:     i64 = 262144,
    max_bin_bytes:     i64 = 262144,
    max_container_len: i64 = 65536,
}

enum Token {
    Nil,
    Bool { v: bool },
    Int { v: i64 },
    Uint { v: u64 },
    F32 { v: f32 },
    F64 { v: f64 },
    Str { v: const u8[:] },
    Bin { v: const u8[:] },
    Array { count: i64 },
    Map { count: i64 },
    Ext { typ: i8, v: const u8[:] },
}
```

`Reader` and `Writer` are fixed-size values. Construct them with
`msgpack::Reader { .. }` and `msgpack::Writer { .. }`; a Goose value type must
be constructed at its declaration.

## Reader

### `init(reader, input, limits = Limits { .. }) -> Error`

Resets the reader over `input`. Returns `InvalidOptions` if any limit is
negative or above its `MAX_*` constant; the reader is left untouched, so a
caller can retry with valid limits. Returns `InputLimit` if
`input.len > max_input_bytes`; that error is sticky.

### `next(reader) -> Token, Error`

Returns the next wire value. A container token reports its element count and
opens a frame; the caller then reads that many elements. `Map { count }` counts
**pairs**, so the caller reads `2 * count` elements.

On error the reader is poisoned: every later `next` returns the same error, and
`offset` holds the byte offset of the failure.

### `done(reader) -> bool`

True when the top-level value and all its children have been read.

`done` is terminal for this reader. A `next` after it returns `InvalidState`
and poisons the reader, so a caller that wants to read a second document out of
the same buffer must re-`init` over `input[consumed(reader)..]` rather than
keep calling `next`. The writer may emit a sequence of values; the reader
deliberately reads exactly one, and `finish` enforces that.

### `finish(reader) -> Error`

A pure check, not a mutation. Returns:

- the sticky error, if `next` already failed;
- `InvalidState` when no value was read at all;
- `Truncated` when the input ended inside a value;
- `Unbalanced` when a container is still open;
- `TrailingBytes` when the top-level value ended before the input did;
- `Error.None` when exactly one top-level value was read and the input is
  exhausted.

`finish` does **not** set the sticky error, so a caller can inspect the state
and keep reading. `offset` is set to the position of the failure.

### `skip(reader) -> Error`

Skips exactly one complete value, children included. Budgets still apply, so a
skipped value cannot exceed `max_nodes`, `max_depth` or the length limits. This
is the primitive for a member the caller does not understand.

### `offset`, `consumed`, `depth`, `remaining`

| Function | Meaning |
| --- | --- |
| `offset(reader)` | Byte offset of the last error, or of the last `finish` failure |
| `consumed(reader)` | Bytes advanced so far |
| `depth(reader)` | Open **non-empty** frames; see [Depth accounting](#depth-accounting) |
| `remaining(reader)` | Elements left in the innermost container, `-1` at top level |

### Depth accounting

`max_depth` bounds the number of **simultaneously open non-empty frames**, not
the structural nesting depth of the value. The two differ by at most one, and
the difference is deliberate:

- A container with `count > 0` opens a frame. The frame holds the number of
  elements still to read and is popped when that count reaches zero.
- A container with `count == 0` is a **leaf**. It opens no frame, consumes no
  depth slot, and is accepted at any depth. It also closes the frames it
  completes, so `depth(reader)` is `0` immediately after reading an empty
  container that was the last element of every enclosing container.

Consequences, all pinned by `depth_semantics_cases` in
[tests/api.goose](../tests/api.goose):

| Shape | `max_depth` | Accepted | Open frames | Container nesting depth |
| --- | ---: | --- | ---: | ---: |
| `91 91 01` | 2 | yes | 2 | 2 |
| `91 91 90` | 2 | yes | 2 | 3 |
| `91 91 91 90` | 2 | no, `DepthLimit` at offset 2 | 2 | — |
| `81 90 90` | 1 | yes | 1 | 2 |
| `91` × 256 + `01` | 256 | yes | 256 | 256 |
| `91` × 257 + `01` | 256 | no, `DepthLimit` | 256 | — |

So the container nesting depth of an accepted document is at most
`max_depth + 1`, and that bound is attained exactly when the deepest container
is empty. A caller that needs "no more than N containers on any path" must set
`max_depth = N - 1`.

The frame stack is a fixed `i64[..MAX_DEPTH]` inside the `Reader` value, and
`MAX_DEPTH` is also the hard maximum for `max_depth`, so a push happens only
when `len < max_depth <= MAX_DEPTH`: the stack cannot overflow and the reader
still allocates nothing. The writer mirrors the reader exactly — `array(w, 0)`
and `map(w, 0)` write a header and open no frame.

This is a semantic, not an optimisation. Changing it would change which
documents are accepted, so it is documented and tested rather than tuned.

## Writer

### `init(writer, limits = Limits { .. }) -> Error`

Resets the writer and clears its output. `InvalidOptions` behaves as for the
reader: the writer is left untouched. Every other writer function returns
`InvalidState` until `init` succeeds.

### Value functions

`nil`, `boolean(v)`, `uint(v: u64)`, `int(v: i64)`, `float32(v: f32)`,
`float64(v: f64)`, `str(v)`, `bin(v)`, `ext(typ: i8, v)`, `array(n)`,
`map(n)`. Each returns `Error`.

`array(n)` and `map(n)` open a frame; the caller then writes `n` elements
(`2 * n` for a map). A frame closes automatically when its last element is
written.

### `finish(writer) -> Error`

A pure check. Returns `Unbalanced` if a container is still open, otherwise
`Error.None`. It does not set the sticky error. The writer can emit zero or
more root values; budgets cover the entire output since `init`. Applications
own framing. To verify that output contains exactly one value, use the reader's
full-input `finish`, which rejects an empty or concatenated document.

### `output(writer) -> const u8[:]`, `written(writer) -> i64`

`output` borrows the writer's buffer. Copy the bytes before the next write.

## Integer policy

Shortest form, matching `rmp`'s `write_uint` / `write_sint`:

| Value | Bytes |
| --- | --- |
| `0 .. 127` | positive fixint |
| `-32 .. -1` | negative fixint |
| `128 .. 255` | `0xcc` + u8 |
| `256 .. 65535` | `0xcd` + u16 |
| `65536 .. 2^32-1` | `0xce` + u32 |
| `2^32 .. 2^64-1` | `0xcf` + u64 |
| `-128 .. -33` | `0xd0` + i8 |
| `-32768 .. -129` | `0xd1` + i16 |
| `-2^31 .. -32769` | `0xd2` + i32 |
| `-2^63 .. -2^31-1` | `0xd3` + i64 |

A non-negative value always uses the unsigned family, so `int(5)` and
`uint(5)` both produce `0x05`. On read, `Int` and `Uint` report the **marker
family**, not the sign: `0x05` is `Uint`, `0xff` is `Int`. `as_i64` accepts
both families when the value fits; `as_u64` rejects a negative.

## Token accessors

| Accessor | Returns | For a token that does not match |
| --- | --- | --- |
| `as_i64(token)` | `i64, bool` | `0, false` |
| `as_u64(token)` | `u64, bool` | `0, false` |
| `as_f64(token)` | `f64, bool` | `0.0, false` |
| `as_bool(token)` | `bool, bool` | `false, false` |
| `text(token)` | `const u8[:]` | `""` |
| `bytes(token)` | `const u8[:]` | `""` |
| `ext_type(token)` | `i8` | `0` |
| `count(token)` | `i64` | `-1` |

`as_i64` accepts both integer families when the value fits; `as_u64` rejects a
negative. `as_f64` widens an `F32` and does not convert an integer. `text` is
the payload of a `Str` and is already validated as UTF-8. `bytes` is the
payload of a `Bin` or an `Ext`. `count` is the declared element count of an
`Array` or the pair count of a `Map`.

Two sentinels collide with real values, and the collision is documented rather
than papered over:

- `ext_type(token)` returns `0` for a token that is not an `Ext`, and `0` is
  also a valid extension type. `ext_type(token) == 0` therefore does not
  distinguish "an `Ext` of type 0" from "not an `Ext`".
- `bytes(token)` returns `""` for a token that is not a `Bin` or an `Ext`, and
  `""` is also a zero-length `Bin` or `Ext`.

When the distinction matters, match on the token instead of using the
accessor:

```goose
match token {
    Ext e => { /* e.typ and e.v are the real values */ },
    _ => { /* not an extension */ },
}
```

The accessors are conveniences for a caller that already knows the token's
family, which is the common case in a schema walk.

## Float policy

IEEE-754 big-endian, `0xca` for `f32` and `0xcb` for `f64`. The writer never
widens or narrows: `float32` writes four bytes, `float64` writes eight. The
reader returns `F32` or `F64` as it found them; `as_f64` widens an `F32`.

## String, binary and extension policy

| Family | Markers | Payload |
| --- | --- | --- |
| `str` | `0xa0..0xbf`, `0xd9`, `0xda`, `0xdb` | UTF-8, validated both ways |
| `bin` | `0xc4`, `0xc5`, `0xc6` | opaque bytes |
| `ext` | `0xd4..0xd8`, `0xc7..0xc9` | signed type byte + opaque bytes |

`str` is validated as UTF-8 on read and on write. Overlong encodings,
surrogates (U+D800..U+DFFF), truncated sequences and code points above
U+10FFFF are rejected with `InvalidUtf8`. Non-characters such as U+FFFE and
U+FFFF are valid UTF-8 and are accepted. `bin` and `ext` are never validated.

The reader rejects a `str` whose declared length exceeds `max_str_bytes` before
reading the payload, and likewise for `bin` and `max_bin_bytes`. `ext` uses
`max_bin_bytes`.

## Error table

| Error | Raised by | Meaning |
| --- | --- | --- |
| `None` | — | Success |
| `InvalidOptions` | `init` | A limit is negative or above its `MAX_*` |
| `InvalidState` | both | A writer call before `init`, a `next` after the value completed, or reader `finish` before any value |
| `Truncated` | reader | The input ended inside a value |
| `Reserved` | reader | Marker `0xc1`, which the specification reserves |
| `DepthLimit` | both | Opening a container would exceed `max_depth` |
| `NodeLimit` | both | The value count would exceed `max_nodes` |
| `InputLimit` | reader | `input.len > max_input_bytes` |
| `OutputLimit` | writer | The next write would exceed `max_output_bytes` |
| `StrLimit` | both | A `str` length exceeds `max_str_bytes` |
| `BinLimit` | both | A `bin` or `ext` length exceeds `max_bin_bytes` |
| `ContainerLimit` | both | A container count exceeds `max_container_len` |
| `TrailingBytes` | reader `finish` | The input holds more than one value |
| `Unbalanced` | both `finish` | A container is still open |
| `InvalidUtf8` | both | A `str` payload is not valid UTF-8 |

## Budget timing

Every budget is checked against the **declared** length in the header, before
the payload is read or reserved. A `str32` header declaring 4 GiB is rejected
with `StrLimit` after reading five bytes, not after allocating 4 GiB. The
reader allocates nothing at all: its depth stack is a fixed `i64[..256]`
inside the `Reader` value, so a `Reader` is 2 KiB and a container costs one
`i64` slot, never a node.

A container header is also checked for feasibility against the bytes that
remain: an `array` declaring more elements than there are bytes left, or a
`map` declaring more pairs than there are byte pairs left, is rejected with
`Truncated` **at the header offset**, before the container token is returned.
So a truncated container never yields a token whose count the caller could not
possibly satisfy.

## Not enforced

- **Map key uniqueness.** A map with duplicate keys is accepted; the reader
  reports the count and the caller decides.
- **Map key ordering.** The reader preserves wire order and does not sort.
  The writer writes pairs in the order the caller writes them.
- **Canonical form.** The reader accepts any valid encoding, including a
  non-shortest integer or a `str8` that would fit in `fixstr`. The writer
  always emits the shortest form, so a decode-then-encode round trip
  canonicalises.
- **Timestamp extension.** `ext` type `-1` is returned as an opaque `Ext`; it
  is not interpreted as a timestamp.
