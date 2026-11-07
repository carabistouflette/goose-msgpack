# goose-msgpack

Bounded MessagePack for Goose. A token reader and a writer that check input,
output, node, depth, string, binary and container budgets before accepting the
work they bound. The reader's `finish` requires exactly one complete value.
The writer can emit a sequence; applications own framing between values.
Pure Goose, Apache-2.0.

Experimental: the API is not frozen, no stable release exists, and no performance
measurement has been recorded yet. See [docs/VALIDATION.md](docs/VALIDATION.md)
for exactly what has and has not been executed.

## Why another MessagePack

[`Macho0x/goose-msgpack`](https://github.com/Macho0x/goose-msgpack) at
`a3d08d25f0260a964f795008ac79468f728a1388` (v0.2.2) already encodes and decodes
MessagePack in Goose. It is a good codec and this library does not replace it
for trusted, in-process data. The gap is the one the
[awesome-goose catalogue](https://github.com/carabistouflette/awesome-goose)
records verbatim:

> MessagePack needs node/depth/length budgets, all-input versus one-value
> decoding, UTF-8 policy and stable map order.

Concretely, against that revision:

| | goose-msgpack | Macho0x/goose-msgpack v0.2.2 |
|---|---|---|
| Budgets | input, output, nodes, depth, str, bin, container | none |
| Budget timing | checked before allocation | n/a |
| Full input | `finish` rejects trailing bytes | `decode::*` leaves them unread |
| UTF-8 | validated on read and write | raw bytes, not checked |
| Decode shape | token stream, no DOM | typed primitives + optional DOM |
| Reader allocation | zero (inline depth stack) | zero |
| Output cap | `max_output_bytes` | none |

The difference is the contract, not the name. [docs/COMPARISON.md](docs/COMPARISON.md)
gives the exact source references.

## Quickstart

Install the Goose revision in [GOOSE_REVISION](GOOSE_REVISION), save this as
`main.goose`, then run `goose run main.goose`. Package imports belong in the
application's root source file.

```goose
import msgpack from "carabistouflette/goose-msgpack@fcd52b882563049084dc133aa218b47ebacd4360";
import std;
fn main() {
    var writer = msgpack::Writer { .. };
    assert(msgpack::init(writer) == msgpack::Error.None);
    assert(msgpack::map(writer, 2) == msgpack::Error.None);
    assert(msgpack::str(writer, "count") == msgpack::Error.None);
    assert(msgpack::uint(writer, 4) == msgpack::Error.None);
    assert(msgpack::str(writer, "tags") == msgpack::Error.None);
    assert(msgpack::array(writer, 2) == msgpack::Error.None);
    assert(msgpack::str(writer, "a") == msgpack::Error.None);
    assert(msgpack::str(writer, "b") == msgpack::Error.None);
    assert(msgpack::finish(writer) == msgpack::Error.None);

    var reader = msgpack::Reader { .. };
    assert(msgpack::init(reader, msgpack::output(writer)) == msgpack::Error.None);
    let head, e1 = msgpack::next(reader);
    assert(e1 == msgpack::Error.None && msgpack::count(head) == 2);
    let key, e2 = msgpack::next(reader);
    assert(e2 == msgpack::Error.None && msgpack::text(key) == "count");
    let value, e3 = msgpack::next(reader);
    let n, ok = msgpack::as_u64(value);
    assert(e3 == msgpack::Error.None && ok && n == 4);
    let tags, e4 = msgpack::next(reader);
    assert(e4 == msgpack::Error.None && msgpack::text(tags) == "tags");
    // skip one complete value, children included
    assert(msgpack::skip(reader) == msgpack::Error.None);
    assert(msgpack::finish(reader) == msgpack::Error.None);
}
```

The runnable example is [examples/plan.goose](examples/plan.goose): a
`goose-task` build-plan manifest, the handoff a planner and a runner in
separate processes need. From a checkout with the pinned compiler:

```sh
make setup
.toolchain/goose/build/goose run examples/plan.goose
```

Observed output:

```
manifest: 69 bytes
plan v1: 4 tasks, concurrency 2, 3 edges 0->2 1->2 2->3
padded manifest rejected: Error.TrailingBytes
self-loop rejected: Error.SelfLoop
```

The example is executed by `make test`, so the quickstart cannot rot silently.

## API

Reader, over a `const u8[:]` the caller owns:

| Operation | Result |
| --- | --- |
| `init(reader, input, limits)` | `Error`; resets the reader |
| `next(reader)` | `Token, Error`; one wire value |
| `done(reader)` | `bool`; the top-level value is complete |
| `finish(reader)` | `Error`; `TrailingBytes` unless exactly one value was read |
| `skip(reader)` | `Error`; skip exactly one complete value, children included |
| `offset(reader)` | `i64`; byte offset of the last error |
| `consumed(reader)` | `i64`; bytes advanced |
| `depth(reader)` | `i64`; open containers |
| `remaining(reader)` | `i64`; elements left in the innermost container |

Writer, into a `u8[>..]` the writer grows:

| Operation | Result |
| --- | --- |
| `init(writer, limits)` | `Error`; resets the writer |
| `nil`, `boolean`, `uint`, `int`, `float32`, `float64` | `Error` |
| `str`, `bin`, `ext` | `Error` |
| `array(writer, n)`, `map(writer, n)` | `Error`; then write the elements |
| `finish(writer)` | `Error`; `Unbalanced` if a container is open |
| `output(writer)` | `const u8[:]`; the bytes written |
| `written(writer)` | `i64` |

Accessors on a `Token`:

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

`count` is the declared element count of an `Array` or the pair count of a
`Map`. `text` is the payload of a `Str`, already validated as UTF-8. `bytes` is
the payload of a `Bin` or an `Ext`.

`ext_type` is the one accessor whose sentinel collides with a real value: `0`
is a valid extension type, so `ext_type(token) == 0` does not tell you whether
the token is an `Ext` of type 0 or not an `Ext` at all. The same is true of
`bytes(token) == ""`, which is both a zero-length `Bin` and a non-`Bin`. When
the distinction matters, match on the token:

```goose
match token {
    Ext e => { /* e.typ and e.v are the real values */ },
    _ => { /* not an extension */ },
}
```

The accessors are conveniences for the case where the caller already knows the
token's family, which is the common case in a schema walk.

`Int` and `Uint` report the **wire family**, not the mathematical sign: a
positive fixint is `Uint`, a negative fixint is `Int`. Use `as_i64` when the
sign is what matters.

## Limits

`Limits` has a default for every field and a hard maximum. `init` returns
`InvalidOptions` for a value outside `0 .. MAX_*`.

| Field | Default | Hard maximum | Enforced |
| --- | ---: | ---: | --- |
| `max_input_bytes` | 1 MiB | 64 MiB | `init` |
| `max_output_bytes` | 1 MiB | 64 MiB | before every write |
| `max_nodes` | 65536 | 1048576 | before every value |
| `max_depth` | 32 | 256 | before opening a non-empty container frame |
| `max_str_bytes` | 256 KiB | 16 MiB | before the payload is read |
| `max_bin_bytes` | 256 KiB | 16 MiB | before the payload is read |
| `max_container_len` | 65536 | 1048576 | before the header is accepted |

A budget is checked against the declared length in the header, so a 4 GiB
`str32` header is rejected without reading or reserving 4 GiB. The reader
allocates nothing at all: the depth stack is a fixed `i64[..256]` inside the
`Reader` value.

`max_depth` counts **open non-empty frames**, not containers on a path. An
empty container is a leaf: it opens no frame and is accepted at any depth, so
the container nesting depth of an accepted document is at most
`max_depth + 1`. Set `max_depth = N - 1` if you need "at most N containers on
any path". [docs/api.md](docs/api.md#depth-accounting) has the table and the
argument; `depth_semantics_cases` in [tests/api.goose](tests/api.goose) pins it.

## UTF-8 policy

`str` is validated as UTF-8 on **both** sides. The writer rejects invalid
bytes with `InvalidUtf8`; the reader rejects a `fixstr`, `str8`, `str16` or
`str32` payload that is not valid UTF-8, at the offset of the string header.
`bin` and `ext` are opaque byte strings and are never validated.

This is stricter than the MessagePack specification, which calls `str` "UTF-8
string" but does not require a decoder to check. It is the policy that makes
`text(token)` safe to use without a second validation pass. Overlong encodings,
surrogate code points, truncated sequences and code points above U+10FFFF are
all rejected; non-characters such as U+FFFE are valid UTF-8 and are accepted.

## Ownership

- The reader borrows the input. `Str`, `Bin` and `Ext` payloads are
  `const u8[:]` views into it; nothing is copied. The input must outlive the
  tokens.
- The writer owns its `u8[>..]` and grows it. `output` borrows it; copy the
  bytes before the next write.
- `finish` on both sides is a pure check. It does not set the sticky error, so
  a caller can inspect the state and continue.

## Performance

**No measurement has been recorded.** [bench/](bench/) is a prepared,
reproducible harness that compares this library with the pinned competitor on
five fixtures from 77 bytes to 25 KiB, with an invalid-input row, and proves
both encode byte-identical output before any timing. It runs 25 rows per side:
encode and decode into a reused buffer and into a fresh one, plus a truncated
input. Every row folds a content checksum rather than a length, so a faster
wrong answer is rejected instead of reported. The benchmark operator runs the
samples serially so no other process competes for the CPU. See
[bench/README.md](bench/README.md) for the equal-contract statement, the
allocation costs, and why the competitor column is not classifiable.

## Development

```sh
make setup          # fetch the pinned Goose compiler
make check          # format, type-check, Python syntax
make test           # contract tests, 100k-case differential oracle, example
make test-debug     # the same under Goose debug checks
make sanitize SANITIZER_CC=gcc     # ASan/UBSan over the whole corpus
make sanitize SANITIZER_CC=clang
make fuzz           # 2 x 120 s coverage-guided campaigns + 8 negative controls
make mutate         # 16 targeted mutants, both suites
make bench-build    # compile both benchmark binaries, no timing
```

`make test` runs the contract tests twice (interpreted and standalone), the
differential oracle twice (interpreted and native), and the example twice.

## Provenance

- Compiler: `eadca409f68210893f366e60d0c2f0dc29a339be`, recorded in
  [GOOSE_REVISION](GOOSE_REVISION).
- Licence: Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
- Third-party: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Design and the budget-before-allocation argument: [docs/DESIGN.md](docs/DESIGN.md).
- Full contract and error table: [docs/api.md](docs/api.md).
- What was executed, with exact commands and output: [docs/VALIDATION.md](docs/VALIDATION.md).
