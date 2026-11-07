# Comparison with Macho0x/goose-msgpack

The competitor is real, maintained and good at what it does. This document
records exactly what it does, with source references, so the difference claimed
in the README can be checked rather than taken on trust.

## Identity

| | |
| --- | --- |
| Repository | <https://github.com/Macho0x/goose-msgpack> |
| Revision compared | `a3d08d25f0260a964f795008ac79468f728a1388` |
| Version | v0.2.2 |
| Files | `msgpack.goose` (entry), `encode.goose`, `decode.goose`, `value.goose`, `bench.goose`, `tests/self_check.goose` |
| Licence | see the repository's `LICENSE` |

The catalogue entry that motivates this library is in
[awesome-goose](https://github.com/carabistouflette/awesome-goose), which lists
the package at that revision and records the gap verbatim:

> MessagePack needs node/depth/length budgets, all-input versus one-value
> decoding, UTF-8 policy and stable map order.

## What the competitor does

### Encoding

`encode.goose` writes shortest-form integers, big-endian floats, and shortest
headers, appending to a caller-owned `u8[>..]`. Its own header states the
contract:

> Each appends to a caller-owned `u8[>..]`. A length outside 0 .. 2^32-1
> aborts.

So the only bound is an `abort()` on a length that cannot be encoded, and the
buffer grows without limit. There is no output budget.

### Decoding

`decode.goose` exposes typed primitives — `int`, `uint`, `float32`, `float64`,
`str`, `bin`, `array`, `map`, `ext` — each taking `(src, at: i64&)` and
returning `value, bool`. Its header states:

> A short buffer, marker 0xc1, or a marker of the wrong family returns false.
> The other results are then meaningless. The cursor stays on that marker when
> the value is rejected.
>
> str and bin are raw bytes. UTF-8 is not checked.

Two consequences follow directly:

1. **No full-input contract.** `decode::*` reads one value and leaves the
   cursor wherever it stopped. Nothing reports that the buffer held more than
   one value. A caller that wants "exactly one message" must compare the final
   cursor to `src.len` itself, and the library does not offer a function for
   it.
2. **No UTF-8 policy.** `str` returns the raw bytes. A caller that needs
   validated text must validate it separately.

### The DOM

`value.goose` builds a tree into a caller-supplied `Node[>..]` pool:

```goose
recursive fn read_array(src: u8[:], at: i64&, pool: Node[>..]&) -> Node? {
```

`read_array` and `read_map` are `recursive`. There is no depth counter and no
node budget, so the depth of the input is the depth of the C stack. A 1 MiB
input of `0x91` bytes is a million-deep recursion.

`value::decode` also does not check that the buffer held exactly one value: it
reads the first value, returns `true`, and leaves the rest unread.

## What this library does differently

| Concern | goose-msgpack | competitor |
| --- | --- | --- |
| Input size | `max_input_bytes`, checked in `init` | none |
| Output size | `max_output_bytes`, checked before every write | none |
| Node count | `max_nodes`, checked before every value | none |
| Depth | `max_depth`, checked before opening a container | none; recursion depth is the input's |
| `str` length | `max_str_bytes`, checked against the declared header | none |
| `bin`/`ext` length | `max_bin_bytes`, checked against the declared header | none |
| Container count | `max_container_len`, checked against the declared header | none |
| Full input | `finish` returns `TrailingBytes` | not checked |
| UTF-8 | validated on read and write | not checked |
| Decode shape | token stream, no DOM | typed primitives + optional DOM |
| Reader allocation | zero, inline `i64[..256]` depth stack | zero |

The difference is not a rename. A caller that switches from the competitor to
this library gains a decoder that cannot be made to allocate 4 GiB from a
five-byte header, cannot be made to recurse a million deep from a 1 MiB input,
and cannot silently accept a message with a second value appended. It loses the
DOM, which this library does not provide.

## Where the competitor is the better choice

- **Trusted, in-process data.** If the bytes came from your own encoder in the
  same process, budgets buy nothing and the competitor's smaller API is
  simpler.
- **You want a tree.** `value::decode` gives you one; this library does not.
- **You want the smallest possible dependency.** Both are dependency-free, but
  the competitor is smaller.

## Byte compatibility

The two libraries produce **byte-identical** output for the same value. This is
not an assertion in prose: [bench/bench.goose](../bench/bench.goose) and
[bench/bench-competitor.goose](../bench/bench-competitor.goose) build the same
five fixtures with each library, and `bench/measure.py` refuses to run if a
single byte differs. The observed result, recorded in
[VALIDATION.md](VALIDATION.md), is identical output on all five fixtures from
77 bytes to 25674 bytes.

That matters for the comparison: the benchmark measures the same workload, so
the only difference in the numbers is the contract.

## What is not compared

`value::decode` (the competitor's DOM) has no counterpart here, so it is
excluded from the benchmark. Comparing a token reader to a tree builder would
measure the data structure, not the codec. The exclusion is stated in
[bench/README.md](../bench/README.md) rather than hidden.
