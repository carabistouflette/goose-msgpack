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
| `skip(reader)` | `Error`; consume the rest of the current container |
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

Accessors on a `Token`: `as_i64`, `as_u64`, `as_f64`, `as_bool`, `text`,
`bytes`, `ext_type`, `count`. Each returns `value, bool` except `text`,
`bytes`, `ext_type` and `count`, which return the payload or `0` for a token
that has none.

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
| `max_depth` | 32 | 256 | before opening a container |
| `max_str_bytes` | 256 KiB | 16 MiB | before the payload is read |
| `max_bin_bytes` | 256 KiB | 16 MiB | before the payload is read |
| `max_container_len` | 65536 | 1048576 | before the header is accepted |

A budget is checked against the declared length in the header, so a 4 GiB
`str32` header is rejected without reading or reserving 4 GiB. The reader
allocates nothing at all: the depth stack is a fixed `i64[..256]` inside the
`Reader` value.

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
both encode byte-identical output before any timing. The benchmark operator runs the
samples serially so no other process competes for the CPU. See
[bench/README.md](bench/README.md) for the equal-contract statement and the
allocation costs.

## Development

```sh
make setup          # fetch the pinned Goose compiler
make check          # format, type-check, Python syntax
make test           # contract tests, 100k-case differential oracle, example
make test-debug     # the same under Goose debug checks
make sanitize SANITIZER_CC=gcc     # ASan/UBSan over the whole corpus
make sanitize SANITIZER_CC=clang
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
