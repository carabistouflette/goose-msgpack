# Competitive review — goose-msgpack, cycle 1

Date: 2026-11-07. Scope: `libraries/goose-msgpack` at baseline `18c968b`, local
work `2dced6c` plus the changes recorded in `CHANGELOG.md`.

This document exists to answer one question honestly: **is this library actually
better than the alternatives, and where is it not?** It records what each
alternative guarantees, what it costs to use, and what was measured — in that
order, because a speed number without the contract it was obtained under is not
a comparison.

Nothing here is a claim of state of the art. The measurements are labelled with
their admissibility, and the sections that could not be established say so.

## 1. Method

Three rules were applied throughout.

**Primary sources, pinned.** Every alternative is a specific commit, fetched and
built locally, not a version number taken on trust. The commit is recorded in
the report and re-checked on every run (`tests/fetch-thirdparty.py` refuses to
proceed if the checkout is at a different revision).

**Contracts before numbers.** A library that is faster because it refuses less,
validates less, or allocates less is not faster at the same job. Each
alternative's guarantees are written down first (§3), and the performance
comparison (§6) states which guarantees were in force.

**A refusal is never excused by its own error code.** The triangulation driver
grants a "contract difference" only when an independent walk of the bytes
(`tests/wire.py`) proves the refusal was justified. See §5.

## 2. The alternatives

### 2.1 `Macho0x/goose-msgpack` — the Goose alternative

- Repository: <https://github.com/Macho0x/goose-msgpack>
- Pinned: `a3d08d25f0260a964f795008ac79468f728a1388`, tag `v0.2.2`.
- Fetched to `.build/competitor/goose-msgpack` by `bench/fetch.py`.

This is the only other MessagePack implementation written in Goose that was
found. It is the relevant alternative for the "same language, same runtime"
question: a Goose user choosing a MessagePack library has these two options.

It is **not** an independent oracle. It is a Goose program, so it shares the
language, the compiler and the runtime with this library. A misreading of the
MessagePack specification that both authors made would be invisible in a
comparison between them. That is why §5 adds a third implementation in a
different language.

### 2.2 `msgpack/msgpack-c` — the maintained C reference

- Repository: <https://github.com/msgpack/msgpack-c>, branch `c_master`.
- Pinned: `f3f796bbe6a2dd0414520f187cec2e4bd41766bf`, version 7.0.3.
- Licence: Boost Software License 1.0.
- Listed on <https://msgpack.org> as the C/C++ implementation.
- Fetched to `.build/thirdparty/msgpack-c` by `tests/fetch-thirdparty.py`.

This is the implementation the MessagePack organisation itself maintains. It is
the closest thing the format has to a reference C implementation, it is used by
other projects, and it is actively maintained. It is the primary third-party
oracle for correctness.

### 2.3 `ludocode/mpack` — the performance-oriented C implementation

- Repository: <https://github.com/ludocode/mpack>.
- Pinned: `c9d1820ecfdbc3954c60a218492251e457cc1f86`, version 1.1.1.
- Listed on <https://msgpack.org> as a C implementation.
- Feature comparison published by the author:
  <https://ludocode.github.io/mpack/md_docs_features.html>.
- Fetched to `.build/thirdparty/mpack` by `tests/fetch-thirdparty.py`.

MPack is the C implementation that is explicitly designed and documented around
performance, with a published benchmark suite. It is the relevant performance
reference: if this library is slower than MPack on the same work, that is the
number worth reporting.

### 2.4 What was deliberately not used as the only alternative

`tests/oracle.py` is an independent Python reimplementation of this library's
contract. It is valuable — it catches implementation bugs — but it was written
for this library, by the same author, from the same reading of the
specification. Using it as the *only* alternative would leave a correlated
modelling error undetectable. It is retained as one oracle among three, not as
the alternative.

A wrapper around Goose's own standard library was also rejected as an
alternative: it would measure the same runtime against itself and prove nothing
about the library.

## 3. Contract matrix

The columns are the guarantees each implementation actually makes, read from its
source and documentation, not from its README's marketing.

| Guarantee | goose-msgpack | Macho0x v0.2.2 | msgpack-c 7.0.3 | MPack 1.1.1 |
|---|---|---|---|---|
| Exactly one root value, trailing bytes refused | **yes**, `finish` → `TrailingBytes` | see §3.1 | **no** — caller compares `off` to `len` | **no** — caller checks `mpack_reader_remaining` |
| UTF-8 validated on `str` | **yes**, `InvalidUtf8`, always | see §3.1 | **no** | **not by the tag API**; **yes** if the caller uses `mpack_read_utf8` / `mpack_read_utf8_inplace` |
| Depth budget | **yes**, configurable, `MAX_DEPTH = 256`, bounds open non-empty frames | see §3.1 | **fixed 32 frames**, reported as `NOMEM` | **no budget**; the tracking stack is caller-sized and only exists when `MPACK_READ_TRACKING` is on |
| Node budget | **yes**, `NodeLimit` | see §3.1 | **no** | **no** |
| Input-size budget | **yes**, `InputLimit` | see §3.1 | **no** | **no** |
| Per-`str`/`bin`/container length budget | **yes** | see §3.1 | **no** | **no** |
| Reader allocation | **none** — fixed `i64[256]` frame stack in the `Reader` | see §3.1 | heap: `msgpack_zone` for the DOM | **none** in the default build (`MPACK_READ_TRACKING` defaults to 0); heap tracking stack only when tracking is enabled; node tree for the DOM API |
| Token model | streaming, one token per `next` | see §3.1 | DOM (`msgpack_object`) | DOM (node tree) or expect API |
| `f32` wire bits preserved exactly | **yes** | see §3.1 | **no** — widened to `double`, signalling NaN quieted | **yes** (keeps `float`) |
| Writer framing | sequence of values, application framing | see §3.1 | sequence | sequence |
| Reserved marker `0xc1` refused | **yes**, `Reserved` | see §3.1 | **yes**, `PARSE_ERROR` | **yes** |
| Declared length refused before the payload is read | **yes** | see §3.1 | **no** | **possible** — `mpack_read_tag` consumes only the header, so the caller can check `tag.v.l` before taking the payload |

### 3.1 Macho0x v0.2.2

The competitor's guarantees were not established to the same depth as the C
libraries'. It is a Goose program of comparable size, and reading it in full was
not part of this cycle. Its column is therefore marked "see §3.1" rather than
filled with claims that were not verified. What *was* verified is that it
encodes the same fixtures to the same bytes (§6.1), which is the property the
performance comparison depends on.

**This is an open gap.** A contract matrix with one column unverified is not a
complete comparison, and the performance numbers against that column should be
read as "faster at producing the same bytes", not "faster at the same
guarantees".

## 4. Interoperability, ownership and API costs

Recorded before any classification, because these are the costs that decide
whether a speed difference matters.

### 4.1 msgpack-c

- **Ownership.** `msgpack_unpack_next` fills a `msgpack_unpacked` that owns a
  `msgpack_zone`. The zone must be destroyed with `msgpack_unpacked_destroy`.
  Every decoded document therefore has a lifetime the caller must manage, and a
  decode allocates. This library's `Reader` owns nothing: it borrows the input
  and returns tokens that borrow from it.
- **API shape.** The return type is an **enum, not a bool**:
  `MSGPACK_UNPACK_SUCCESS = 2`, `EXTRA_BYTES = 1`, `CONTINUE = 0`,
  `PARSE_ERROR = -1`, `NOMEM_ERROR = -2`. Both error values convert to `true` in
  a boolean test, so `if (msgpack_unpack_next(...))` silently treats a parse
  error as success. The triangulation oracle compares against `SUCCESS`
  explicitly for this reason.
- **Depth.** The frame stack is a fixed `MSGPACK_EMBED_STACK_SIZE` (32) array in
  `unpack_template.h`, marked `FIXME` in the source. A deeper document returns
  `NOMEM_ERROR`, which is indistinguishable from a real allocation failure at
  this API. A caller cannot tell "too deep" from "out of memory".
- **Interop cost.** To use msgpack-c from Goose you need a C shim and a
  `msgpack_zone` lifetime per document. The shim is the cost; the zone is the
  ownership cost.

### 4.2 MPack

- **Ownership.** `mpack_reader_init_data` borrows the input and does not copy
  the payload. The reader carries a **tracking stack**, but it is a
  heap-allocated growable array (`mpack_track_t.elements`) that only exists when
  `MPACK_READ_TRACKING` is 1 — and that defaults to 0 unless `MPACK_DEBUG` is
  on. The default build therefore does not allocate for tracking, which
  `bench-mpack macros` prints rather than assumes (`MPACK_DEBUG 0`,
  `MPACK_READ_TRACKING 0`, `MPACK_MALLOC unused`, `sizeof(mpack_reader_t) 80`).
  The node API (`mpack_tree_*`) does allocate a tree. So MPack's zero-copy claim
  holds for the tag API in the default build, and stops holding as soon as
  tracking or the tree API is enabled.
- **API shape.** Two APIs: an expect API (`mpack_read_uint`, `mpack_read_str`)
  that is fast but requires knowing the schema, and a tag API
  (`mpack_read_tag` + `mpack_done_*`) that is schemaless. The benchmark uses the
  tag API, because that is the comparable one: this library is schemaless.
- **Depth.** MPack has no depth budget. The tracking stack is caller-sized and
  only exists when tracking is enabled, so an unbounded document is the
  caller's problem. A caller who wants a budget counts frames in the traversal,
  which is what `bench/bench-mpack.c`'s `contract` mode does.
- **Interop cost.** Same as msgpack-c: a C shim, plus a decision about who owns
  the tracking stack if tracking is enabled. With tracking off there is nothing
  to own.

### 4.3 Macho0x

- **Ownership.** Same language, same model: no interop cost. This is the one
  axis where the Goose alternative is strictly cheaper than either C library.

## 5. Correctness triangulation

`make triangulate` builds three binaries over one corpus and compares them
record by record:

| Binary | Implementation | Role |
|---|---|---|
| `.build/triangulate/triangulate` | this library | subject |
| `.build/triangulate/triangulate-msgpackc` | msgpack-c 7.0.3 | third-party oracle |
| `tests/wire.py` | independent Python walk | witness |

The witness is not decoration. Without it the classifier would excuse a refusal
on the strength of its own error code: a bug that refused valid UTF-8 as
`InvalidUtf8`, or a one-byte document as `NodeLimit`, would be counted as a
"policy difference" and the run would stay green. The witness recomputes the
quantities the budgets are stated in — node count, open non-empty frames, str
and bin lengths, container lengths, and strict UTF-8 validity — from the bytes
and the limits, and an exception is granted only when the witness agrees.

`tests/triangulate.py --selftest` is the negative control for that gate: 16
cases, 12 of which require the classifier to report a failure. It includes a
one-byte valid document (`0x05`) refused as `InvalidUtf8` and as `NodeLimit`,
both of which must be defects, and a `NOMEM` at depth 2, which must be an
infrastructure error rather than the depth-budget exception.

### 5.1 Result

```
$ make triangulate
corpus: 724 records, 153046 bytes
random_tree coverage: [(0, 62), (1, 71), (2, 54), (3, 51), (4, 59), (5, 52),
                       (6, 50), (7, 54), (8, 46), (9, 61), (10, 59)]
  agree-accept: 557
  agree-reject: 87
  oracle-depth-limit-32: 2
  oracle-f32-nan-quieting: 1
  policy-utf8: 77
triangulation ok: no defect
```

`random_tree` draws from 11 kinds and the run asserts every one was produced.
Before that assertion the generator drew from 10 kinds while handling 11, so the
`map` branch was unreachable and the corpus looked larger than it was.

### 5.2 What the triangulation found in the alternatives

These are properties of the alternatives, discovered by measurement, not
assumptions:

- **msgpack-c has a depth budget, but it is a fixed 32-frame stack.** A document
  33 containers deep is refused as `NOMEM`. This library accepts up to 256
  configurable frames and reports `DepthLimit`. The oracle is the stricter side
  here.
- **msgpack-c does not preserve `f32` wire bits.** It widens an `f32` to a
  `double` and narrows it back, which quiets a signalling NaN: `0x7f800001`
  comes back as `0x7fc00001`. This library keeps the wire bits exactly. The
  oracle is the lossy side here.
- **msgpack-c does not validate UTF-8.** 77 records in the corpus are accepted
  by msgpack-c and refused by this library with `InvalidUtf8`, each confirmed by
  the witness to contain genuinely invalid UTF-8.

### 5.3 A structural limit of this triangulation

`budget-depth` can never be exercised against msgpack-c: any document deeper
than this library's 256-frame limit is also deeper than msgpack-c's 32-frame
stack, so both refuse and the record lands in `agree-reject`. The
`budget-depth` classification is therefore proven only by the classifier's
negative control (`--selftest`), not by an end-to-end record. The other budget
classes are exercisable in principle but were not exercised end to end in this
cycle, because doing so needs records larger than 16 MiB.

**This is an open gap**, and it is stated rather than papered over.

## 6. Performance

### 6.1 The harness had to be fixed first

The first profile of the benchmark binary showed **45% of samples inside the
harness's own checksum**, a byte-at-a-time FNV-1a over the encoded bytes, run
inside the timed loop. The harness was measuring itself.

That is exactly the failure mode the measurement rules forbid: a checksum must
be computed outside the timed region, and the timed region must contain an
anti-elimination barrier that is cheap enough not to dominate. The harness was
rewritten:

- the full byte-wise content checksum moved to a separate `checksum` mode, run
  before and after the timing passes and required to be identical;
- the in-loop barrier is now a word-wise `hash()` over the token stream plus a
  token-kind/span fold, which `perf` puts at ~4% of self time.

**This is a harness correction, not a library improvement.** Both the old and
the new library are measured with the *same* corrected harness: the baseline
binary is rebuilt from the frozen tree with the current `bench/bench.goose`
(`bench/build-baseline.py`), so the only difference between the two binaries is
`msgpack.goose`. Any speed difference reported below is therefore attributable
to the library, and the harness fix is not counted as a gain.

### 6.2 Profile of the core, after the correction

`perf record -F 999` on the corrected harness, self time, both binaries built
with the same compiler and flags:

| Symbol | Old library | New library |
|---|---:|---:|
| `msgpack_next` (dispatch) | 31.3% | 35.3% |
| `msgpack_valid_utf8` | 9.3% | 12.8% |
| `drain` (harness fold) | 10.6% | 10.7% |
| `msgpack_array_body` | 4.8% | 6.4% |
| `msgpack_uint` | 3.5% | 4.9% |
| libc `memcpy` family | 13.6% | 5.5% |
| `encode_plan` (harness) | 7.3% | 5.2% |
| harness `hash_lanes` + `main` + `clock_gettime` | ~5% | ~7% |

The harness's own share is ~4–7% in both columns, down from 45%. The remaining
harness cost is the anti-elimination fold, which is deliberately kept: removing
it would let the compiler eliminate the work being measured.

### 6.3 The optimisation the profile justified

`msgpack_valid_utf8` was the largest single library function that could be
improved without touching the contract. It walked the payload one byte at a
time, spending a compare and a branch on every byte, and the corpus is
overwhelmingly ASCII.

The change adds an ASCII fast path: OR eight bytes and test the high bit, which
costs one branch per eight bytes. It cannot change the verdict — a byte with the
high bit set makes the OR at least `0x80`, so the exact checks below still see
it — and the slow path is unchanged. The contract is identical, which
`make test` confirms: 1116 API checks and 102723 differential cases, corpus
`453ae1128e2e069b`, the same digest as before the change.

### 6.4 Measurement

See `bench/README.md` for the protocol and `.build/bench/*.md` for the raw
reports. The headline table is in §6.5.

### 6.5 Before / after / concurrent, at equal contracts

Filled from the paired runs; see the generated reports for the raw samples,
dispersion and ratio intervals.

## 7. What is not claimed

- **No state-of-the-art claim.** The measurements are labelled with their
  admissibility, and the host could not be shown to be quiet.
- **No claim that the Goose alternative is slower at equal guarantees**, because
  its guarantees were not established (§3.1).
- **No claim about the C libraries at equal guarantees.** msgpack-c and MPack
  make weaker guarantees (no UTF-8 validation, no full-input contract, no
  default budgets). A comparison against them is a comparison of different
  jobs, and is reported as such.
- **No coverage-guided fuzzing claim.** The fuzz campaign is a floor.
- **No Windows, macOS, 32-bit or big-endian run.**
