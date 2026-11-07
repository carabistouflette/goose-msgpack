# Benchmark

This directory holds the measurement instrument and the reports it produced.
Nothing here runs as part of `make test`.

Two things must be true before a number from this directory means anything, and
both are checked rather than assumed:

1. **The instrument must not measure itself.** The first profile of the
   benchmark binary showed 45% of samples inside the harness's own byte-wise
   checksum, which ran inside the timed loop. The harness was rewritten: the
   full content checksum moved to a separate `checksum` mode run before and
   after the timing passes, and the in-loop anti-elimination barrier is now a
   word-wise hash plus a token-kind/span fold, which `perf` puts at ~4% of self
   time. **That correction is a harness fix, not a library improvement**, and it
   is not counted as one: the baseline binary is rebuilt from the frozen tree
   with the *current* harness, so the only difference between the two binaries
   is `msgpack.goose`.
2. **The output contract must be unambiguous.** The binary prints
   `time <fixture> <op> <n> <dt_ns>` — two totals, never a rate — and the reader
   divides exactly once. An earlier version printed a rate next to the batch
   size and the reader divided by the batch again, which understated every row
   by the batch size. Reports from before that fix carry `invalid-unit` in their
   name and must not be compared with anything; see `INVALID-UNIT.md` in
   `.build/bench/`.

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

## Matched valid workload, and where the contract differs

The workload is matched: same value, same bytes, same schema walk, same
compiler, same flags, proven by `verify` before any timing. The **contract is
not matched**, and cannot be made equal without deleting the reason this library
exists. Calling this an "equal contract" comparison would be wrong, so it is
called a matched valid workload:

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

# Analytic controls for the output contract. No binary needed.
python3 bench/paired.py --selftest

# The negative control. A and B are the same binary, so every ratio is 1.0.
# If this fails, the window is contaminated and no comparison from it is valid.
python3 bench/paired.py --a .build/bench/msgpack-bench \
                        --b .build/bench/msgpack-bench \
                        --label self-control --self-control --same-library \
                        --batch-invariance

# The comparison. Same library on both sides, so every checksum must match.
python3 bench/paired.py --a .build/bench/msgpack-bench-baseline \
                        --b .build/bench/msgpack-bench \
                        --label old-vs-new --same-library --batch-invariance

# A third-party column. Checksums cannot match across libraries; the encode
# rows still must, which is what proves the workload is the same.
python3 bench/paired.py --a .build/bench/msgpack-bench \
                        --b .build/bench/msgpack-bench-competitor \
                        --label ours-vs-competitor

# The MPack reference, three columns. `--b-args` passes the comparator's mode
# word, so the same rows are measured against the same contract.
make bench-mpack
.build/bench/msgpack-bench-mpack macros          # the build under measurement
.build/bench/msgpack-bench-mpack budget-selftest # the budgets actually fire
python3 bench/paired.py --a .build/bench/msgpack-bench \
                        --b .build/bench/msgpack-bench-mpack \
                        --label ours-vs-mpack-raw --batch-invariance
python3 bench/paired.py --a .build/bench/msgpack-bench \
                        --b .build/bench/msgpack-bench-mpack \
                        --b-args contract --label ours-vs-mpack-contract
python3 bench/paired.py --a .build/bench/msgpack-bench \
                        --b .build/bench/msgpack-bench-mpack \
                        --b-args contract-wide --label ours-vs-mpack-contract-wide
```

### The MPack columns

`bench/bench-mpack.c` is a C reference over the same five fixtures and the same
ten rows. It is a **token traversal, not a DOM**: `mpack_read_tag` plus
`mpack_skip_bytes` plus `mpack_done_*`, which is the comparable shape because
goose-msgpack is a token reader.

Three columns, and each one is allowed to claim only what it measures:

| Column | What it does | What it may claim |
|---|---|---|
| `raw` | tag API, skip payloads | matched valid workload: same bytes, same rows, same traversal shape. **Not** the same contract. |
| `contract` | plus goose-msgpack's **default** `Limits` (1 MiB input, 65536 nodes, depth 32, str/bin 256 KiB, container 65536), UTF-8 through `mpack_read_utf8_inplace`, and `mpack_reader_remaining() == 0` | the cost of the contract, measured |
| `contract-wide` | the same with goose-msgpack's **hard maxima** (64 MiB, 1048576 nodes, depth 256, str/bin 16 MiB, container 1048576) | whether the limit *values* cost anything (they should not: the checks are comparisons against constants) |

Every budget is checked at the point goose-msgpack checks it, including the
declared length **before** the payload is read: `mpack_read_tag` consumes only
the header, so `tag.v.l` is known while the payload is still unread. The earlier
claim that MPack "cannot cheaply refuse a declared length before reading it" was
wrong and has been removed.

`budget-selftest` is the negative control: ten cases, each exceeding exactly one
limit, asserting the refusal code. It includes the case that distinguishes
structural depth from open frames — a chain of 40 non-empty arrays is refused at
depth 32, while an array holding 40 empty arrays is accepted, because an empty
container opens no frame — and a valid small document that must be accepted, so
the controls cannot pass by refusing everything.

`macros` prints the effective `MPACK_*` values and the struct sizes, because a
comparison against a debug build is not a comparison. The default `-O2` build
reports `MPACK_DEBUG 0`, `MPACK_READ_TRACKING 0`, `MPACK_WRITE_TRACKING 0`,
`MPACK_MALLOC unused`, `sizeof(mpack_reader_t) 80`; the explicit
`-DNDEBUG -DMPACK_DEBUG=0` build reports the same values and produces identical
checksums, so the two are the same configuration and the plain build was already
a production build.

`verify` is the cross-implementation proof: our Goose writer and MPack's writer
produce **byte-identical** output for all five fixtures, and the ten encode
checksums agree. The decode checksums cannot agree, because the two token models
are different; `paired.py` records that as `encode_checksums_agree` and does not
fail the run on it, because the byte-identity gate is strictly stronger.

### The input-identity gate, and the two defects it found

`verify` publishes the **invalid** variants as well as the valid fixtures:

```
fixture <name> bytes <n> hex <hex>
invalid <name> <op> bytes <n> hex <hex>
```

35 rows per binary: 5 valid and 30 invalid. `paired.py` refuses to run if the two
binaries disagree on any of them. Without that gate, a comparator that builds a
different invalid input is measuring a different row, and the difference in the
refusal path is read as a performance difference.

It found two real defects in `bench/bench-mpack.c`:

1. **The corrupt variants were different documents.** `bench.goose` writes the
   reserved marker `0xc1` at the start, the middle and the end. The MPack harness
   flipped the low bit instead. `0x86 ^ 0x01` is `0x87`, a valid fixmap of 7, so
   MPack walked the whole document while goose-msgpack refused at the first byte.
   The row reported a refusal against a traversal: `decode-corrupt-start` on
   `plan-large` came out at a ratio of 1718, which is not a speed difference, it
   is two different jobs. The harness now writes `0xc1`.
2. **`truncated-end` was timed against the `truncated-middle` bytes.** Both
   variants shared one `static char buf[65536]`, and the middle variant was built
   second, so it overwrote the end variant. Each variant now has its own buffer.

Both were invisible before the invalid rows were published, because `verify` only
covered the valid fixtures and the two harnesses agreed on those.

### The sanitizer control, and the third defect it found

The 35 rows still do not cover everything: the five fixtures contain no `bin` and
no `ext`, so a truncated bin or ext payload is never decoded by `verify` at all.
`make bench-mpack-sanitize` builds the comparator under
`-fsanitize=address,undefined` and runs `safety-selftest`, which decodes ten
truncated payloads (bin8/16/32, ext8/16/32, fixstr, str8/16/32) in both the raw
and the contract column. Each variant is allocated to its exact length, so an
overrun lands on a redzone instead of inside a 64 KiB buffer.

That control found a third defect. The harness skipped a payload with
`mpack_skip_bytes` and then folded its first and last byte **before** checking
`mpack_reader_error`, so a truncated payload was sampled past its end. The
pre-fix code, rebuilt under the same sanitizer, is caught with
`AddressSanitizer: heap-buffer-overflow, READ of size 1`. The fix checks the
reader error immediately after the skip and after `mpack_done_*`, before anything
samples or folds the payload, in the str, bin and ext cases. The 35-row `verify`
output is unchanged by the fix — which is exactly why the functional comparison
could not have found it.

`measure.py` is the older instrument: it pairs the two binaries inside one run
and reports medians. `paired.py` is the one to use for a before/after question,
because it adds the negative control, the ratio interval, the batch-invariance
control and the contention record. Both read the same output contract.

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

1. Same compiler binary, same `--cc`, same optimisation flags.
2. Same fixture bytes, proven by `verify` before any timing, and the bytes must
   equal what `bench/fixtures.py` predicts from the independent encoder.
3. Alternating passes, and the side that runs first alternates every sample, so
   a monotonic drift in the machine hits both columns equally.
4. At least 20 measured samples after at least one discarded warmup pass;
   `paired.py` refuses fewer.
5. No row is dropped. A row present in one binary and missing from the other
   aborts the run, unless the missing side declared it `na`.
6. The competitor is fetched at a pinned commit and never modified.
7. Every child is pinned to one CPU, chosen explicitly and recorded, so a
   measurement cannot migrate between cores mid-run.
8. Content checksums are computed before and after the timing passes and must be
   identical. For a same-library comparison they must also match across the two
   binaries; for a third-party column the encode rows must match, which is what
   proves the workload is the same.
9. The negative control must pass: the same binary against itself must produce a
   ratio interval containing 1.0 on every row.
10. Batch invariance: the same work timed with twice the batch must cost the same
    per call. The gate is calibrated against the noise the run itself observed —
    each batch is timed five times, and the between-batch difference must stay
    within twice the within-batch spread, with a 10% floor. It has three
    outcomes, not two: `ok`, `fail`, and `inconclusive` when the within-batch
    spread exceeds 15%, because a host too noisy to resolve the question makes
    the measurement unavailable, not correct. A difference of 50% or more is
    `fail` whatever the noise was, since a factor-of-batch error is 100%.
11. The binary identity is captured before and after the run and must be
    unchanged, and each binary's provenance sidecar must describe the binary on
    disk. A rebuild mid-run would otherwise be invisible: the functional
    checksums describe the workload, not the code that produced the times. A run
    with no build records is not admissible.
12. No measurement is taken while another build or test runs on the machine.
    Builds, tests, fuzzing and timing are serialised through one lock.

## Contention, and why the old gate was not enough

The previous protocol required a load average at or below 0.5. On an eight-core
machine that is not a measure of contention: a load average of 3 spread over
eight cores can leave the pinned core idle, and a load average of 0.4 can sit
entirely on the core being measured. The absolute number was also unachievable
here — the host runs at a load average near 4 — so the gate could only ever be
failed, never passed.

`bench/contention.py` replaces it with checks that are about the core being
measured:

| Check | Threshold | Why |
|---|---|---|
| Pinned | the chosen CPU is in the affinity mask | a measurement must not migrate |
| CPU idle | per-CPU busy fraction from `/proc/stat` deltas < 5% | the core itself must be free |
| SMT siblings idle | siblings of the chosen CPU, **excluding the chosen CPU**, < 5% busy | a sibling steals issue slots; the chosen CPU is already checked above |
| No stall | PSI `some total` delta over the window < 1% | the whole machine must not be stalling |
| Clock stable | calibration CV < 2% | the clock must be steady |
| No preemption | child CPU time over wall time > 95%, from `wait4` | a preempted child is a contaminated sample |

The legacy load-average gate is **still recorded**, in `legacy_gate`, with its
value and whether it would have passed. It is not used as the criterion, and it
was not removed to make a result possible: it is reported next to the checks
that replaced it so a reader can see both.

### The gate must not count our own work

The first version of this gate took the `/proc/stat` counters around the
calibration, so the calibration's own CPU time — a compile plus sixteen runs of
a dependent integer chain — was counted as contention. On an idle host it
reported the measured core as 57% busy and refused the window. That refusal was
not evidence about the host; it was the instrument measuring itself, the same
class of error as the checksum inside the timed loop.

The fix is structural, not a threshold change:

- **The idle window is measured first, with no work of ours running.** What
  `/proc/stat` and PSI report over that window is other people's load, which is
  what the gate is about.
- **The calibration runs afterwards**, and is used only for clock stability and
  preemption. The window it runs in is still recorded, with the calibrator's own
  CPU time subtracted (`window_busy_raw` and `window_busy_corrected`), so a
  reader can see that the subtraction is what makes the two windows comparable.
- **PSI is windowed.** `some avg10` is a ten-second moving average, so it
  describes the last ten seconds rather than the window being judged. The
  cumulative `some total` counter is windowed: its delta over the window divided
  by the window is the stall fraction for exactly that window.
- **The chosen CPU is excluded from the sibling check**, so the same jiffies are
  not counted twice and the two checks are not presented as independent evidence
  when they are one measurement.

`python3 bench/contention.py --selftest` is the control for both failure modes,
and it runs in `make check`:

```
$ python3 bench/contention.py --selftest --cpu 3
cpu 3: quiet busy 0.1800, with a busy child 0.9804
calibration window busy 0.6667 (our own work)
contention self-check ok: sensitive to a busy child, blind to our own work,
chosen CPU excluded from the sibling check
```

The first line proves the gate is **sensitive**: a child spinning on the
measured CPU raises the busy fraction from 0.18 to 0.98, so real contention is
seen. The second proves it is **blind to our own work**: the calibration window
is 0.67 busy, which is exactly why it cannot be the window the gate judges.

When the checks fail the run is labelled `exploratory`. An exploratory run
cannot support a ranking claim. What it can still support is a *comparison*,
because the negative control proves the design is unbiased under that load: if
the same binary against itself yields ratio intervals containing 1.0, then a
ratio that excludes 1.0 is a real difference, not a scheduling artefact.

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
