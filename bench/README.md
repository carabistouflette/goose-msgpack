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

Five operations per fixture, 25 rows for goose-msgpack:

- `encode-reused` — build the whole manifest, including `finish`, appending into
  one output buffer that is cleared and reused. This is a caller streaming many
  documents.
- `encode-fresh` — the same, into a fresh `u8[>..]` per document. This is a
  caller producing one message per request. The pair separates allocator cost
  from encoder cost.
- `decode-fresh` — walk the whole manifest with a new `Reader` value per call,
  so the 2 KiB depth stack is a new value.
- `decode-reused` — the same with one `Reader` re-initialised per call. The
  reader is a local of the caller, not a global: a global reader would hold a
  reference into the fixture buffer across the `clear()` that rebuilds it, which
  the borrow checker rejects.
- `decode-truncated` — the same buffer with its last byte removed. Both must
  reject it. This is the invalid-input row: it measures rejection, not
  throughput, and a library that accepted the buffer would be wrong.

The competitor emits the same rows except `decode-reused`, which it prints as
`na`: its decoder is stateless (`at` is a caller-owned cursor), so there is no
reader object to reuse. The cell is reported as not applicable rather than
duplicated from `decode-fresh`.

## Content checksums

Every row folds a content checksum, not a length or a token count. A length
cannot distinguish a correct encode from a wrong one of the same size, and a
compiler may delete work whose only observable effect is a length it can prove.

- `encode-*` folds FNV-1a over the produced bytes.
- `decode-*` folds FNV-1a over the token discriminant and the exact byte span
  each token consumed, so a reader that splits the input differently, or
  reinterprets a marker, changes the checksum.

Both binaries have a `checksum` mode that prints one `sum <fixture> <op> <value>`
row per measured row. `measure.py` runs it before and after the timing passes
and aborts if it changed, and `--compare` refuses to pair two runs whose
checksums differ: a speed-up that changes a checksum is a wrong answer, not a
faster one.

The encode checksums are identical between this library and the competitor,
which is a second confirmation that both encode the same bytes. The decode
checksums differ, because the token models differ, so each binary is compared
against its own `checksum` mode and never across binaries.

## Commands

```sh
make bench-build                      # fetch the competitor, build both binaries
.build/bench/msgpack-bench verify     # fixture bytes, no timing
.build/bench/msgpack-bench-competitor verify
.build/bench/msgpack-bench checksum   # content checksums, no timing

# Baseline: the frozen library, the current harness.
python3 bench/build-baseline.py --tree .build/baseline/18c968bcf2d9-v2/tree

# One run per side, then the paired table.
python3 bench/measure.py --bench .build/bench/msgpack-bench-baseline \
                         --label baseline  --out .build/bench/baseline.json
python3 bench/measure.py --label optimised --out .build/bench/optimised.json
python3 bench/measure.py --compare .build/bench/baseline.json \
                                 .build/bench/optimised.json
```

`build-baseline.py` assembles a scratch tree from the frozen `msgpack.goose` and
the **current** `bench/bench.goose`, builds it, and refuses to continue if the
frozen library changed while it was building. The harness is the measurement
instrument, so both sides must use the same one; only `msgpack.goose` may
differ. The frozen tree is read, never written.

`measure.py` writes a JSON report and a Markdown table with, per row, the
median, p10, p90, min, max, MAD, IQR and stdev, **every raw per-sample value**,
the peak RSS of each pass (`os.wait4`, so it is attributed to that child and not
to a process-wide high-water mark), and a provenance block hashed **before and
after** the run: compiler revision and binary SHA-256, library and harness
SHA-256, competitor commit, platform, CPU count, affinity mask, compiler
version. If any of those hashes changed during the run, the run is discarded.

### Budget

25 rows × 20 samples × 200 ms ≈ 100 s of timed work per binary, plus 2 warmup
passes and process startup, so roughly **4 minutes wall clock for both sides**
and about **5 minutes for a baseline/optimised pair**. Peak RSS is recorded per
pass; the harness itself is a few MiB. `--samples` below 20 and `--warmup` below
1 are refused.

## Fairness rules

1. Same compiler binary, same `--cc clang`, same optimisation flags.
2. Same fixture bytes, proven by `verify` before any timing.
3. Alternating passes, and the side that runs first alternates every sample, so
   a monotonic drift in the machine hits both columns equally.
4. At least 20 measured samples after at least one discarded warmup pass;
   `measure.py` refuses fewer.
5. No row is dropped. A row present in one binary and missing from the other
   aborts the run, unless the missing side declared it `na`.
6. The competitor is fetched at a pinned commit and never modified.
7. No measurement is taken while another build or test runs on the machine.
8. Content checksums must match between the two runs being compared.

## The competitor column is not classifiable

The competitor column is a maintained reference point, **not** an equal-contract
comparison, and no result here should be read as "faster than" or "slower than"
in the sense of a like-for-like benchmark. Macho0x/goose-msgpack has no input,
output, node, depth, str, bin or container budget, no full-input `finish`, and
no UTF-8 validation, and its decoder is a typed schema walk rather than a token
stream. `value::decode` (its DOM) is excluded because comparing a token reader
to a tree builder measures the data structure.

Because the contracts differ, this harness cannot produce a SOTA claim in either
direction. A row where goose-msgpack is slower is the price of the contract; a
row where it is faster is not evidence that the contract is free.

## Known limits

- The competitor's `bench.goose` uses a fixed time window rather than samples.
  This harness uses both: a batch, then a window, then samples of the window.
- Rows under a microsecond move from run to run. `plan-small` encode is one of
  them; read it as a bound, not a number.
- The two decode paths are not the same code shape. goose-msgpack dispatches
  once per value into a tagged `Token`; the competitor calls a typed function
  per field. That is a real API difference, and it is part of what the row
  measures.
