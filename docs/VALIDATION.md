# Validation

What was executed, with the exact command and the exact output. Anything not in
this file was not run.

## Environment

| | |
| --- | --- |
| Compiler | `goose eadca40 (runtime 3025e5810379)` |
| Revision | `eadca409f68210893f366e60d0c2f0dc29a339be` |
| Binary | pinned compiler binary, reused read-only without rebuilding |
| C compilers | gcc 16.2.1, clang 23.1.4 |
| Python | 3.14.9 |
| Platform | Linux x86-64 |

Every command below was run with `env -u LD_LIBRARY_PATH`, because the harness
environment exports an `LD_LIBRARY_PATH` that breaks the compiler and cmake.
The `Makefile` does not do this for you; it is a property of this machine, not
of the project.

## `make check`

```
$ env -u LD_LIBRARY_PATH make check GOOSE=<pinned goose>
"<goose>" format --check msgpack.goose tests examples bench
"<goose>" check msgpack.goose
"<goose>" check tests/api.goose
"<goose>" check tests/oracle.goose
"<goose>" check examples/plan.goose
"<goose>" check bench/bench.goose
python3 -m py_compile tests/oracle.py scripts/sanitize.py scripts/quickstart.py bench/measure.py bench/fixtures.py bench/fetch.py
git diff --check
exit 0
```

## `make test`

```
$ env -u LD_LIBRARY_PATH make test GOOSE=<pinned goose>
"<goose>" run tests/api.goose
msgpack api ok: 1061 checks
python3 tests/oracle.py --goose "<goose>" --cases 100000 --output .build/oracle.json
msgpack oracle: 102723 differential cases passed; corpus 453ae1128e2e069b
"<goose>" build tests/api.goose --standalone --cc "cc" -O2 -o .build/api
built .build/api
./.build/api
msgpack api ok: 1061 checks
"<goose>" build tests/oracle.goose --standalone --cc "cc" -O2 -o .build/oracle
built .build/oracle
python3 tests/oracle.py --binary .build/oracle --cases 100000 --output .build/oracle-native.json
msgpack oracle: 102723 differential cases passed; corpus 453ae1128e2e069b
"<goose>" run examples/plan.goose
manifest: 69 bytes
plan v1: 4 tasks, concurrency 2, 3 edges 0->2 1->2 2->3
padded manifest rejected: Error.TrailingBytes
self-loop rejected: Error.SelfLoop
"<goose>" build examples/plan.goose --standalone --cc "cc" -O2 -o .build/plan
built .build/plan
./.build/plan
manifest: 69 bytes
plan v1: 4 tasks, concurrency 2, 3 edges 0->2 1->2 2->3
padded manifest rejected: Error.TrailingBytes
self-loop rejected: Error.SelfLoop
python3 scripts/quickstart.py --goose "<goose>"
README quickstart ok
exit 0
```

The contract tests and the oracle each run twice: interpreted, then as a
standalone native binary. The corpus digest `453ae1128e2e069b` is identical
across both, so the native build and the interpreter agree on all 102723 cases.

## `make test-debug`

```
$ env -u LD_LIBRARY_PATH make test-debug GOOSE=<pinned goose>
"<goose>" run tests/api.goose --debug
msgpack api ok: 1061 checks
python3 tests/oracle.py --goose "<goose>" --debug --cases 100000 --output .build/oracle-debug.json
msgpack oracle: 102723 differential cases passed; corpus 453ae1128e2e069b
"<goose>" build tests/api.goose --standalone --debug --cc "cc" -o .build/api-debug
built .build/api-debug
./.build/api-debug
msgpack api ok: 1061 checks
"<goose>" run examples/plan.goose --debug
manifest: 69 bytes
plan v1: 4 tasks, concurrency 2, 3 edges 0->2 1->2 2->3
padded manifest rejected: Error.TrailingBytes
self-loop rejected: Error.SelfLoop
python3 scripts/quickstart.py --goose "<goose>" --debug
README quickstart ok
exit 0
```

Debug mode found a real bug that release mode hid. `push_be` wrote
`(value >> (i * 8)) as u8`; for the low byte of a value above 255 the cast
truncated silently in release and trapped in debug:

```
goose runtime error: as conversion out of range (debug): 256 as u8 (msgpack.goose:507)
```

The fix masks before the cast, `((value >> (i * 8)) & 0xff) as u8`. This is why
`make test-debug` is a required check and not an optional one.

## `make sanitize`

```
$ env -u LD_LIBRARY_PATH make sanitize SANITIZER_CC=gcc GOOSE=<pinned goose> OUTPUT=.build/sanitize-gcc.json
msgpack sanitizer: contract tests and 102723 oracle cases passed under ASan/UBSan (gcc)
msgpack sanitizer results: .build/sanitize-gcc.json
exit 0

$ env -u LD_LIBRARY_PATH make sanitize SANITIZER_CC=clang GOOSE=<pinned goose> OUTPUT=.build/sanitize-clang.json
msgpack sanitizer: contract tests and 102723 oracle cases passed under ASan/UBSan (clang)
msgpack sanitizer results: .build/sanitize-clang.json
exit 0
```

`scripts/sanitize.py` wraps the C compiler so every generated translation unit
and link gets `-fsanitize=address,undefined -fno-omit-frame-pointer -UNDEBUG`,
then runs the contract tests (release and debug) and the full corpus against
the instrumented binaries. It records every compiler command line, hashes the
inputs before and after, and rejects the result if a source file or an
instrumented binary changed during the run.

**Limit:** this instruments the generated Goose and runtime C. Installed system
libraries are not rebuilt.

## Fuzzing

`tests/fuzz.goose` is a libFuzzer target that calls the **real Goose API**:
`msgpack::init`, `next`, `skip`, `finish`, `consumed`, `depth`, `remaining`,
`offset`, and the writer. It is not a reimplementation of the parser and it does
not fuzz the generated C directly. `tests/fuzz.c` is the driver; it remaps
`_Exit` to `goose_fuzz_exit` so a Goose assertion aborts the process and
libFuzzer retains the exact input bytes.

```sh
env -u LD_LIBRARY_PATH python3 scripts/fuzz.py --goose <pinned goose> \
    --seconds 120 --runs 100000 --seed 20261107 --seed 20261108 \
    --defect no-input-budget --defect no-utf8-check --defect no-output-budget \
    --defect no-array-truncation --defect no-node-budget --defect no-depth-budget \
    --defect no-str-budget --defect asan-overread \
    --output .build/fuzz/results.json
```

Build: `clang 23.1.4`, `-O1 -g -fsanitize=fuzzer,address,undefined
-fno-sanitize-recover=all -fno-omit-frame-pointer`, Goose `--debug` (so the
runtime's own overflow and bounds checks are live), `c_patches 0` — the
generated C is not edited for the campaigns. Limits: `-max_len=4096
-timeout=5 -rss_limit_mb=1024`. 59 seeds.

| seed | seconds | executed | corpus | coverage | artifacts |
| ---: | ---: | ---: | ---: | --- | --- |
| 20261107 | 120 | 100000 | 857 | cov 388, ft 1669 | none |
| 20261108 | 120 | 100000 | 615 | cov 388, ft 1590 | none |

Both campaigns ran the full requested 100000 executions and the full 120 s, and
found no crash, no assertion failure and no sanitizer report.

The target asserts the contract, not just "did not crash":

- state invariants: `consumed <= len`, `depth <= max_depth`, `offset <= len`,
  `remaining == -1` exactly when `depth == 0` and `>= 1` otherwise;
- payload aliasing: a `Str`/`Bin`/`Ext` view is exactly
  `data[consumed - len .. consumed]`, so a copy or an off-by-one is caught;
- container feasibility: `array.count <= len - at`, `map.count <= (len - at) / 2`;
- canonical fixed point: `encode(decode(x))` is idempotent and never longer;
- `skip` equivalence: skipping a value consumes exactly what reading it does;
- `InvalidState` stickiness after `done`;
- every budget at exactly one unit below the observed maximum — input, nodes,
  depth, container, str, bin, and the output-prefix property.

### Negative controls

A fuzz target that never fails proves nothing. Eight defects were injected into
the generated C, one per guarantee, and each had to be caught:

| control | guarantee | caught by |
| --- | --- | --- |
| `no-input-budget` | `init` rejects `input.len > max_input_bytes` | Goose assertion |
| `no-utf8-check` | the reader rejects a non-UTF-8 `str` payload | Goose assertion |
| `no-output-budget` | the writer never appends past `max_output_bytes` | Goose assertion |
| `no-array-truncation` | an impossible array count is `Truncated` at the header | Goose assertion |
| `no-node-budget` | the reader stops at `max_nodes` | Goose assertion |
| `no-depth-budget` | the reader stops at `max_depth` | Goose assertion |
| `no-str-budget` | a declared `str`/`bin` length above budget is rejected first | Goose assertion |
| `asan-overread` | a multi-byte field is read only inside the input | **AddressSanitizer** |

All eight were caught. `asan-overread` produced
`ERROR: AddressSanitizer: heap-buffer-overflow ... in msgpack_be_g7` in the
generated Goose C, which proves ASan instruments the generated code and that the
fuzz input is a real heap allocation rather than a static buffer.

The assertion bridge is verified separately: a forced `assert` aborts with
return code 77 and libFuzzer retains the exact input bytes
(`assertion_bridge.ok = true`, artifact SHA-256 matches the expected input).

**Limit — UBSan.** UBSan is linked, but no injected defect reached it: Goose's
own `--debug` overflow and bounds checks, and the target's property assertions,
fire first. Two attempts (a `sign` multiply overflow and a `push_be` shift
overflow) were caught by assertions instead. The UBSan control was removed
rather than reported as passing. UBSan is instrumented and linked; it is not
demonstrated to catch a defect in this library.

## Mutation testing

`scripts/mutate.py` injects one targeted defect at a time into `msgpack.goose`
and runs both suites. The mutants target real guarantees, not syntax errors and
not always-fail edits.

```sh
env -u LD_LIBRARY_PATH python3 scripts/mutate.py --goose <pinned goose> --cases 20000
```

Pristine passes both suites (`msgpack api ok: 1061 checks`, oracle 22251 cases).
**16 of 16 mutants killed**, no survivors:

| mutant | guarantee | killed by |
| --- | --- | --- |
| `depth-off-by-one` | `max_depth` is exact | api, oracle |
| `ext-fixed-sixteen` | `fixext16` reads 16 payload bytes | api, oracle |
| `float32-byte-order` | `f32` is big-endian on the wire | api, oracle |
| `input-budget-exclusive` | `input.len == max_input_bytes` is accepted | api, oracle |
| `int-negative-fixint` | negative fixint decodes to its value | api |
| `map-frame-counts-pairs` | a map frame counts pairs, not elements | api |
| `node-off-by-one` | `max_nodes` is exact | api, oracle |
| `output-budget-exclusive` | `written == max_output_bytes` is accepted | api, oracle |
| `sign-extension` | `int8`/`int16`/`int32` sign-extend | api, oracle |
| `skip-stops-early` | `skip` consumes the whole value | api |
| `str-budget-after-payload` | the `str` budget is checked before the payload | oracle |
| `trailing-bytes-accepted` | `finish` rejects trailing bytes | api, oracle |
| `uint-shortest-form` | the writer emits the shortest integer form | api |
| `utf8-above-max` | code points above U+10FFFF are rejected | api, oracle |
| `utf8-overlong-three` | 3-byte overlong encodings are rejected | api, oracle |
| `utf8-surrogate` | surrogates U+D800..U+DFFF are rejected | api, oracle |

Three mutants initially **survived**, and each exposed a real gap in the tests
rather than in the library:

1. `uint-shortest-form` and `int-negative-fixint` — the reserve size was off by
   one, invisible unless the output budget is exactly the encoded size. Fixed by
   `output_budget_exact_cases()`, which sweeps 43 boundary values at the exact
   size and at size − 1.
2. `map-frame-counts-pairs` — a map frame counting elements instead of pairs
   closes early and silently accepts a truncated map. Fixed by
   `map_frame_cases()`: a map with keys only must leave the frame `Unbalanced`.
3. `no-array-truncation` (a fuzz control) — survived because the error was still
   `Truncated`, just later. Fixed by the container-count feasibility assertions
   in the fuzz target.

## Benchmark harness

Compiled, not measured.

```
$ env -u LD_LIBRARY_PATH make bench-build CC=clang GOOSE=<pinned goose>
python3 bench/fixtures.py --check
plan-small: 77 bytes fnv1a 168334f5efe050c8
plan-medium: 454 bytes fnv1a 682284dae2d2d172
plan-large: 25674 bytes fnv1a 98dfc2190fe15bf2
strings-16x32: 668 bytes fnv1a 26f0c926a8b77655
strings-4x256: 1116 bytes fnv1a 5211bb0d025f8bab
fixture table sha256 c56b68e11d08ad7af0722c189ee174841a7729b046f7b4bb2cb20cebc42dafa8
python3 bench/fetch.py
competitor: .build/competitor/goose-msgpack at a3d08d25f0260a964f795008ac79468f728a1388 (v0.2.2)
"<goose>" build bench/bench.goose --standalone --cc "clang" -O2 -o .build/bench/msgpack-bench
built .build/bench/msgpack-bench
"<goose>" build bench/bench-competitor.goose --standalone --cc "clang" -O2 -o .build/bench/msgpack-bench-competitor
built .build/bench/msgpack-bench-competitor
exit 0
```

Both `verify` modes, and the cross-check against the independent encoder:

```
$ .build/bench/msgpack-bench verify
$ .build/bench/msgpack-bench-competitor verify

plan-small: 77B sha256 b394b9fe18afcb68 oracle+competitor agree=True
plan-medium: 454B sha256 b159739563f2b380 oracle+competitor agree=True
plan-large: 25674B sha256 52ecf716da30a219 oracle+competitor agree=True
strings-16x32: 668B sha256 4604257be9d0b484 oracle+competitor agree=True
strings-4x256: 1116B sha256 690a42391c7a39f9 oracle+competitor agree=True
VERIFY_OK True
```

All five fixtures are byte-identical between this library, the pinned
competitor, and the independent Python encoder in `tests/oracle.py`. The
workload is therefore proven equal before any timing.

### Content checksums, not lengths

Both binaries also have a `checksum` mode that prints one
`sum <fixture> <op> <value>` row per measured row, computed once. The value is
FNV-1a over the bytes the operation produced or consumed, plus the token
discriminant for the reader, so it depends on every byte and on the reader's
interpretation of each marker. A length alone cannot distinguish a correct
encode from a wrong one of the same size, and a compiler may delete work whose
only observable effect is a length it can prove.

```
$ .build/bench/msgpack-bench checksum
sum plan-small encode-reused 1622198521679597768
sum plan-small encode-fresh 1622198521679597768
sum plan-small decode-fresh -2842979596927942360
sum plan-small decode-reused -2842979596927942360
sum plan-small decode-truncated -3216134144651521000
...
```

Three properties hold and are checked by the runner:

- `encode-reused == encode-fresh` and `decode-fresh == decode-reused` for every
  fixture: the buffer strategy changes the cost, not the answer.
- `decode-truncated` differs from `decode-fresh` on every fixture.
- The encode checksums are **identical between this library and the pinned
  competitor**, which is a second, independent confirmation that both encode the
  same bytes. The decode checksums differ, because the token models differ; the
  runner therefore compares each binary against its own `checksum` mode, never
  across binaries.

A constant-length mutation was also checked: flipping one payload byte of a
12-byte document leaves the length at 12 and changes the checksum from
`-1855317403597202706` to `1265517709396091357`.

### Prepared runner

`bench/measure.py` is prepared and self-tested, not measured:

```sh
python3 bench/measure.py --label baseline  --out .build/bench/baseline.json
python3 bench/measure.py --label optimised --out .build/bench/optimised.json
python3 bench/measure.py --compare .build/bench/baseline.json .build/bench/optimised.json
```

It refuses fewer than 20 measured samples and fewer than 1 warmup pass, keeps
every raw per-sample value, reports median/p10/p90/min/max/MAD/IQR/stdev, the
peak RSS of each pass via `os.wait4`, and hashes the provenance **before and
after** the run, aborting if a source or binary hash changed. `--compare`
refuses to pair two runs whose content checksums differ.

The runner was exercised end to end at a 1 ms window purely to prove it works
(`.build/bench/selftest.json`); those numbers are a harness self-test, not a
measurement, and are not reported as results. The gates were verified: a
tampered checksum is refused, `--samples 19` is refused, `--warmup 0` is
refused.

**No timing was run.** `make bench` is left to the benchmark operator, which
serialises the samples so no other process competes for the CPU.

## Boundary regressions

The public API suite covers uint8 128, float32 1.5, depth limits on nested
arrays, skipping the final nested child, and strict UTF-8. The invalid fixstr
`a1 ff` is rejected rather than exposed as text. Overlong, surrogate and
truncated sequences are rejected; non-characters remain valid UTF-8.

Publication review expanded the API suite from 400 to 420 checks with
explicit stream/framing regressions: the writer may
emit zero or more values, its budget spans all of them, and the reader rejects
empty or concatenated output when a caller requires exactly one document.

The hardening pass took the suite from 420 to **1061 checks**. The added cases
exist because a mutant or a fuzz control survived without them, not to raise a
number:

| case group | what it pins |
| --- | --- |
| `marker_cases` | every marker family, including the reserved `0xc1` |
| `integer_accessor_cases` | `as_i64`/`as_u64` at `u64` max and `i64` min |
| `float_cases` | NaN, ±inf, `-0.0`, `f32` vs `f64` width |
| `exact_limit_cases` | every budget at exactly the limit and one past it |
| `skip_budget_cases` | `skip` still charges nodes, depth and length budgets |
| `state_preservation_cases` | `InvalidOptions` leaves the reader untouched |
| `ownership_cases` | `Str`/`Bin`/`Ext` alias the input, no copy |
| `writer_large_form_cases` | `array32`/`map32`/`str32`/`bin32`/`ext32`, `fixext4/8/16` |
| `depth_empty_child_cases` | depth accounting with an empty last child |
| `output_budget_exact_cases` | 43 boundary values at exact size and size − 1 |
| `map_frame_cases` | a map frame counts pairs; keys only leaves it `Unbalanced` |

## Differential oracle

`tests/oracle.py` is an independent implementation of the same contract in
Python, with its own UTF-8 validator, its own integer decoder and its own
budget accounting. It shares no code with the Goose library.

```
$ python3 tests/oracle.py --goose <goose> --cases 100000
msgpack oracle: 102723 differential cases passed; corpus 453ae1128e2e069b
```

The corpus is seeded and reproducible: the same `--cases` value produces the
same 102723 cases and the same digest. It covers:

- every marker family, including the reserved `0xc1`;
- shortest and non-shortest integer forms, both signs, at every width boundary;
- `fixstr`/`str8`/`str16`/`str32` and `bin`/`ext` at their length boundaries;
- overlong UTF-8, surrogates, truncated sequences, non-characters;
- truncated headers and truncated payloads at every offset;
- containers at and past `max_depth`, `max_nodes` and `max_container_len`;
- trailing bytes after a complete value;
- random valid trees, re-encoded and compared byte for byte.

**Limit:** this is a finite seeded campaign, not coverage-guided fuzzing. It
does not claim to have explored the input space.

## Not executed

- **No performance measurement.** Prepared only; see
  [bench/README.md](../bench/README.md).
- **No Windows or macOS run.** Linux x86-64 only.
- **No 32-bit run.** `i64` and `u64` are assumed 64-bit.
- **No big-endian run.** The float path probes `little_endian()` at runtime,
  but only the little-endian branch has been executed.
- **No UBSan catch demonstrated.** UBSan is linked into the fuzz binary but no
  injected defect reached it; see the limit under Fuzzing.
- **No coverage-guided campaign longer than 120 s per seed.** Two seeds, two
  minutes each, 200000 executions total. That is a floor, not a proof of
  absence.
- **No remote publication.** No tag, no release, no push.
