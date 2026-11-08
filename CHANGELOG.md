# Changelog

## Unreleased

Initial bounded MessagePack reader and writer.

- `Reader` over a borrowed `const u8[:]`: token stream, zero allocation, an
  inline `i64[..256]` depth stack, and a full-input `finish` that rejects
  trailing bytes.
- `Writer` into an owned `u8[>..]`: shortest-form integers, big-endian floats,
  shortest headers, and an output budget checked before every write.
- Budgets for input, output, nodes, depth, string, binary and container
  length, each checked against the declared header before any allocation.
- Strict UTF-8 on `str` for both read and write; `bin` and `ext` opaque.
- `skip` for a member the caller does not understand.
- Contract tests (400 assertions), an independent Python oracle over 102723
  differential cases, a runnable `goose-task` plan example, and a prepared
  benchmark against the pinned competitor.

### Contract documentation

- **Depth accounting is now stated precisely.** `max_depth` bounds the number of
  *open non-empty container frames*, not the structural nesting depth of the
  document. An empty container is a leaf: it opens no frame. The invariant is
  `container nesting depth <= open frames + 1 <= max_depth + 1`, with equality
  exactly when the deepest container is empty. `depth()` returns the frame
  count, so it reads 0 immediately after such a leaf unwinds its parents. This
  was already the behaviour; it is now documented and pinned by
  `depth_semantics_cases`, including a 256-chain accepted and a 257-chain
  refused with `DepthLimit`. **No semantic change.**
- **`skip` consumes exactly one complete value**, not the rest of the current
  container. The README said otherwise; the code and `docs/api.md` were right.
- **Accessor sentinels are documented.** `ext_type` returns `i8` and `0` for a
  non-`Ext` token, but `0` is also a valid ext type; `bytes` returns `""` for a
  non-`Bin` token, but `""` is also a valid zero-length `Bin`. Both are
  ambiguous, and `match` is the unambiguous path. Pinned by
  `accessor_sentinel_cases`. **No API change.**

### Third-party triangulation

- `make triangulate` compares this library with **msgpack-c 7.0.3**
  (`f3f796bbe6a2dd0414520f187cec2e4bd41766bf`, `c_master`) over a 724-record
  corpus: 557 agree-accept, 87 agree-reject, 77 policy-utf8, 2
  oracle-depth-limit-32, 1 oracle-f32-nan-quieting, 0 defects.
- `tests/wire.py` is an independent witness: a third implementation that walks
  the wire format and recomputes the quantities the budgets are stated in. A
  contract difference is granted only when the witness agrees, so a refusal is
  never excused on the strength of its own error code.
  `tests/triangulate.py --selftest` is the negative control: 16 cases, 12 of
  which require a failure, including a one-byte valid document refused as
  `InvalidUtf8` and as `NodeLimit`.
- Found in the alternatives: msgpack-c has a **fixed 32-frame stack** and
  reports a deeper document as `NOMEM`; it **does not preserve `f32` wire bits**
  (a signalling NaN is quieted by the widen/narrow round trip); it **does not
  validate UTF-8**.

### Performance

- **The harness was measuring itself.** `perf` showed 45% of samples inside the
  benchmark's own byte-wise checksum, which ran inside the timed loop. The
  checksum moved to a separate `checksum` mode run before and after the timing
  passes; the in-loop anti-elimination barrier is now a word-wise hash plus a
  token-kind/span fold, ~4% of self time. This is a harness correction, not a
  library improvement, and it is not counted as one: the baseline binary is
  rebuilt from the frozen tree with the current harness.
- **The output contract was wrong by a factor of the batch size.** The binary
  printed a rate next to the batch size and the reader divided by the batch
  again. The contract is now `time <fixture> <op> <n> <dt_ns>` — two totals, and
  the reader divides exactly once. Reports from before the fix carry
  `invalid-unit` in their name. `bench/paired.py --selftest` pins the arithmetic
  and `--batch-invariance` re-times at twice the batch.
- **`valid_utf8` gained an ASCII fast path.** It was 12.8% of self time, almost
  all of it in ASCII payloads. OR-ing eight bytes and testing the high bit costs
  one branch per eight bytes and cannot change the verdict. The contract is
  identical: 1116 API checks and 102723 differential cases, corpus
  `453ae1128e2e069b`, the same digest as before the change.
- `bench/paired.py` adds the negative control (same binary against itself must
  yield ratio intervals containing 1.0), a bootstrap interval on the ratio, and
  a batch-invariance control. `bench/contention.py` replaces the absolute
  load-average gate with per-CPU busy fraction, SMT sibling state, PSI and clock
  stability; the legacy gate is still recorded, not removed.
- **The contention gate no longer counts our own work as contention.** The old
  gate sampled `/proc/stat` before the calibration build and after its fifteen
  runs, then required the window to be under 5% busy — so it measured our own
  calibration as load and refused a quiet host. The gate now takes the quiet
  window *before* any work of ours, and the preemption check uses
  `CLOCK_MONOTONIC` and `CLOCK_THREAD_CPUTIME_ID` bracketing the same loop
  inside `bench/calibrate.c`, so `cpu/wall` is a real preemption signal rather
  than a parent's view that includes `fork`/`exec`. The parent `wait4` figures
  are kept as provenance, not as a gate. `--selftest` proves sensitivity to a
  bounded busy child, blindness to our own calibration, exclusion of the chosen
  CPU from the sibling check, and that the preemption gate is not a phantom.
- **Checksums print as unsigned.** `format_int` takes a signed value, so a
  checksum with the high bit set printed negative and the same bytes hashed to
  two different-looking numbers across implementations. `bench.goose` and
  `bench-competitor.goose` now print the u64 as unsigned decimal, and
  `bench/paired.py` normalises to the u64 bit pattern so a report from before
  the fix still compares correctly.

### The MPack reference

- `bench/bench-mpack.c` measures **MPack 1.1.1**
  (`c9d1820ecfdbc3954c60a218492251e457cc1f86`) over the same five fixtures and
  the same ten rows, as a token traversal (`mpack_read_tag` + `mpack_skip_bytes`
  + `mpack_done_*`), not a DOM.
- **Three columns, each allowed to claim only what it measures.** `raw` is the
  matched valid workload. `contract` adds goose-msgpack's **default** `Limits`
  (1 MiB input, 65536 nodes, depth 32, str/bin 256 KiB, container 65536), UTF-8
  through `mpack_read_utf8_inplace`, and `mpack_reader_remaining() == 0`.
  `contract-wide` uses the hard maxima instead, to show that the limit *values*
  cost nothing.
- **Cross-implementation proof.** Our Goose writer and MPack's writer produce
  byte-identical output for all five fixtures, and the ten encode checksums
  agree. The decode checksums cannot agree, because the token models differ;
  `paired.py` records that as `encode_checksums_agree` and does not fail on it,
  because the byte-identity gate is strictly stronger.
- **The budgets have a negative control.** `budget-selftest` runs ten cases,
  each exceeding exactly one limit, and asserts the refusal code. It includes
  the case that separates structural depth from open frames — 40 nested
  non-empty arrays are refused at depth 32, while an array holding 40 empty
  arrays is accepted — and a valid small document that must be accepted, so the
  controls cannot pass by refusing everything.
- **The build is printed, not assumed.** `macros` reports `MPACK_DEBUG 0`,
  `MPACK_READ_TRACKING 0`, `MPACK_WRITE_TRACKING 0`, `MPACK_MALLOC unused`,
  `sizeof(mpack_reader_t) 80`. `MPACK_DEBUG` defaults to 0 unless `DEBUG` or
  `_DEBUG` is defined, so a plain `-O2` compile is already a production build;
  an explicit `-DNDEBUG -DMPACK_DEBUG=0` build reports the same values and
  produces identical checksums.
- **Two claims corrected.** "MPack does not validate UTF-8" is true of the raw
  tag API and false of the library, which offers `mpack_read_utf8` and
  `mpack_read_utf8_inplace`. "MPack cannot refuse a declared length before
  reading it" was wrong: `mpack_read_tag` consumes only the header, so the
  length is known while the payload is still unread, and `contract` mode checks
  it there. The tracking stack is a heap array that only exists when
  `MPACK_READ_TRACKING` is on, so the default build does not allocate for it.
- **The comparator no longer does parasitic work.** `write_manifest` filled a
  4096-byte buffer for every map member, so a 32-byte member paid 4096 bytes of
  `memset` that goose-msgpack never does. The filler is built once, outside the
  loop.
- **The input-identity gate found two harness defects.** `verify` now publishes
  the 30 invalid variants as well as the 5 valid fixtures, and `paired.py`
  refuses to run if the two binaries disagree on any of the 35 rows. It caught
  (a) the MPack harness building the corrupt variants as a bit flip instead of
  the reserved marker `0xc1`, so `0x86 ^ 0x01 = 0x87` left a valid fixmap and
  MPack walked the whole document while goose-msgpack refused at the first byte
  — a ratio of 1718 that compared a refusal against a traversal; and (b)
  `truncated-end` and `truncated-middle` sharing one buffer, so `truncated-end`
  was timed against the middle variant's bytes. Both are fixed.
- **The sanitizer control found a third harness defect.** The five fixtures
  contain no `bin` and no `ext`, so the 35 `verify` rows never decode a truncated
  bin or ext payload. `make bench-mpack-sanitize` builds the comparator under
  `-fsanitize=address,undefined` and runs `safety-selftest`, which decodes ten
  truncated payloads (bin8/16/32, ext8/16/32, fixstr, str8/16/32) from
  exactly-sized buffers in both the raw and the contract column. It caught the
  harness skipping a payload with `mpack_skip_bytes` and then folding its first
  and last byte *before* checking `mpack_reader_error`, so a truncated payload
  was sampled past its end. The pre-fix code, rebuilt under the same sanitizer,
  reports `AddressSanitizer: heap-buffer-overflow, READ of size 1`. The fix
  checks the reader error immediately after the skip and after `mpack_done_*`,
  before anything samples or folds the payload, in the str, bin and ext cases.
  The 35-row `verify` output is unchanged by the fix, which is why the functional
  comparison could not have found it.
- **The batch-invariance control no longer passes on noise.** It has three
  outcomes: `ok`, `fail`, and `inconclusive` when the within-batch spread exceeds
  15%. A host too noisy to resolve the question makes the measurement
  unavailable, not correct. A difference of 50% or more is `fail` whatever the
  noise was. The analytic controls pin both directions.
- **Binary identity is captured before and after the run.** A rebuild mid-run
  would otherwise be invisible, because the functional checksums describe the
  workload and not the code that produced the times. Each binary's provenance
  sidecar must also describe the binary on disk, and a run with no build records
  is not admissible.

No release. No state-of-the-art claim. The measurements are `exploratory`: the
host could not be shown to be quiet, so they support a comparison between two
builds, not a ranking against the world.
