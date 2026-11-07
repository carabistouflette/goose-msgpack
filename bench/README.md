# Benchmark

**No measurement has been recorded yet.** This directory is a prepared,
reproducible harness. The benchmark operator runs the samples serially, with no other
process competing for the CPU, and records the result. Nothing here runs as
part of `make test`.

## What is compared

| | goose-msgpack | Macho0x/goose-msgpack |
|---|---|---|
| Revision | this tree | `a3d08d25f0260a964f795008ac79468f728a1388` (v0.2.2) |
| Compiler | pinned `GOOSE_REVISION` | the same binary |
| Encode | `Writer` + `finish` | `encode::*` appending to a caller-owned `u8[>..]` |
| Decode | `Reader::next` token stream | `decode::*` typed primitives |
| Budgets | input, output, nodes, depth, str, bin, container | none |
| Full input | `finish` rejects trailing bytes | not checked |
| UTF-8 | validated on read and write | not checked |

Both binaries build the same five fixtures and print the same rows. `verify`
proves the two encode **byte-identical** output, and `measure.py` aborts if a
single byte differs, so the paired rows measure the same workload.

## Equal contract, and where it is not equal

The workload is equal: same value, same bytes, same schema walk, same
compiler, same flags. The contract is not, and cannot be made equal without
deleting the reason this library exists:

- Every `next` and every writer call checks the node, depth, str, bin and
  container budgets before it allocates or advances. The competitor has no
  equivalent check, so this cost has no counterpart row.
- `finish` walks the remaining state to prove the input was exactly one value.
  The competitor's `decode::*` leaves trailing bytes unread by design.
- `str` is validated as UTF-8 on both sides. The competitor returns raw bytes.

Those checks are reported as part of the goose-msgpack column, not hidden in a
separate row. A reader who wants "the same work without the contract" can
subtract nothing meaningful, because the contract is the work.

`value::decode` (the competitor's DOM) is **excluded**: goose-msgpack has no
DOM, so there is no equal-contract row. Comparing a token reader to a tree
builder would measure the data structure, not the codec.

## Allocation and ownership

| | goose-msgpack | competitor |
|---|---|---|
| Reader | zero allocation; a fixed `i64[..256]` depth stack lives inside the `Reader` value (2 KiB) | zero allocation |
| Writer | grows `u8[>..]` to the output size; the caller owns the buffer | grows the caller's `u8[>..]`; the caller owns the buffer |
| Decoded `str`/`bin` | a `const u8[:]` view into the input, no copy | a `u8[:]` view into the input, no copy |
| DOM | none | `value::decode` fills a caller-supplied `Node[>..]` pool |

Both readers borrow the input. Neither copies a payload. The `Reader` value is
2 KiB larger than the competitor's cursor because the depth stack is inline;
that is a fixed cost per reader, not per value.

## Fixtures

| name | shape | bytes |
|---|---|---|
| `plan-small` | 4 tasks, 3 edges | 77 |
| `plan-medium` | 64 tasks, 128 edges | 454 |
| `plan-large` | 1024 tasks, 4096 edges | 25674 |
| `strings-16x32` | 16 string members of 32 bytes | 668 |
| `strings-4x256` | 4 string members of 256 bytes | 1116 |

`bench/fixtures.py` is the single source of truth. It encodes the same value
with the independent encoder in `tests/oracle.py` and prints the expected
length and SHA-256, so a fixture cannot drift silently.

## Operations

- `encode` — build the whole manifest, including `finish`.
- `decode` — walk the whole manifest. goose-msgpack drains the token stream;
  the competitor walks the schema with typed primitives.
- `decode-truncated` — the same buffer with its last byte removed. Both must
  reject it. This is the invalid-input row: it measures rejection, not
  throughput, and a library that accepted the buffer would be wrong.

## Commands

```sh
make bench-build                      # fetch the competitor, build both binaries
.build/bench/msgpack-bench verify     # fixture bytes, no timing
.build/bench/msgpack-bench-competitor verify
python3 bench/measure.py --samples 7 --batch 64 --ms 200
```

`measure.py` writes `.build/bench/measure.json` and `.build/bench/measure.md`
with the per-row median, min, max, ratio and a provenance block: compiler
revision and binary SHA-256, library and harness SHA-256, competitor commit,
platform, CPU count, affinity mask and compiler version.

## Fairness rules

1. Same compiler binary, same `--cc clang`, same optimisation flags.
2. Same fixture bytes, proven by `verify` before any timing.
3. Alternating passes, so a drift in the machine hits both columns.
4. Median of at least three samples; `measure.py` refuses fewer.
5. No row is dropped. A row present in one binary and missing from the other
   aborts the run.
6. The competitor is fetched at a pinned commit and never modified.
7. No measurement is taken while another build or test runs on the machine.

## Known limits

- The competitor's `bench.goose` uses a fixed time window rather than samples.
  This harness uses both: a batch, then a window, then samples of the window.
- Rows under a microsecond move from run to run. `plan-small` encode is one of
  them; read it as a bound, not a number.
- The two decode paths are not the same code shape. goose-msgpack dispatches
  once per value into a tagged `Token`; the competitor calls a typed function
  per field. That is a real API difference, and it is part of what the row
  measures.
