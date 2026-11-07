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
msgpack api ok: 400 checks
python3 tests/oracle.py --goose "<goose>" --cases 100000 --output .build/oracle.json
msgpack oracle: 102723 differential cases passed; corpus 453ae1128e2e069b
"<goose>" build tests/api.goose --standalone --cc "cc" -O2 -o .build/api
built .build/api
./.build/api
msgpack api ok: 400 checks
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
msgpack api ok: 400 checks
python3 tests/oracle.py --goose "<goose>" --debug --cases 100000 --output .build/oracle-debug.json
msgpack oracle: 102723 differential cases passed; corpus 453ae1128e2e069b
"<goose>" build tests/api.goose --standalone --debug --cc "cc" -o .build/api-debug
built .build/api-debug
./.build/api-debug
msgpack api ok: 400 checks
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

**No timing was run.** `make bench` is left to the benchmark operator, which
serialises the samples so no other process competes for the CPU.

## Boundary regressions

The public API suite covers uint8 128, float32 1.5, depth limits on nested
arrays, skipping the final nested child, and strict UTF-8. The invalid fixstr
`a1 ff` is rejected rather than exposed as text. Overlong, surrogate and
truncated sequences are rejected; non-characters remain valid UTF-8.

Publication review added explicit stream/framing regressions: the writer may
emit zero or more values, its budget spans all of them, and the reader rejects
empty or concatenated output when a caller requires exactly one document.

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
- **No fuzzing.** The corpus is seeded and finite.
- **No remote publication.** No tag, no release, no push.
