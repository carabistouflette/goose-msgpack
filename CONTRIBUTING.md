# Contributing

Keep the module pure, small, bounded and explicit. Applications own I/O,
framing, schema and policy. Preserve the documented wire contract, the
budget-before-allocation order, the zero-allocation reader, the full-input
`finish` and the UTF-8 policy. No native accelerator without profiling and a
reviewed portable Goose fallback.

Use focused branches and Conventional Commits with imperative subjects. Commit
one coherent change at a time. No compatibility promise before 1.0. Never commit
credentials, binaries, generated compiler output, toolchains or private notes.

## What a behaviour change needs

A change to the reader or writer needs, at minimum:

- a public-interface regression in [tests/api.goose](tests/api.goose) for the
  new behaviour, and for the malformed input that must still be rejected;
- a case in the differential corpus in [tests/oracle.py](tests/oracle.py) if
  the change affects what the oracle can observe;
- the same result from `make test` and `make test-debug`. Debug mode catches
  narrowing casts that release mode truncates silently; a change that only
  passes in release is not done.

Run `make format check test test-debug`, then
`make sanitize SANITIZER_CC=gcc` and `make sanitize SANITIZER_CC=clang`.

## Budgets are not negotiable

Every limit is checked against the **declared** length in the header, before
the payload is read or reserved. A change that moves a check after an
allocation, or that derives a bound from the buffer instead of the header, is a
regression even if every test passes. Add the test that would have caught it.

## UTF-8

`str` is validated on both sides. `bin` and `ext` are never validated. A change
that makes `text()` return unvalidated bytes must change the documentation in
the same commit, because the promise is the reason the check exists.

## Benchmarks

Profile before optimising. Preserve every fixture, its expected bytes and its
checksum. A benchmark change must keep the equal-contract statement in
[bench/README.md](bench/README.md) true, and must not add a timing threshold to
CI. Measurements are serialised: do not run `make bench` while another build or
test is running on the machine.

## Compiler changes

A compiler change requires a reviewed full upstream pin in
[GOOSE_REVISION](GOOSE_REVISION) and a full validation run. Do not bump the pin
to make a test pass.

## Setup

Development needs Git, Make, CMake >= 3.27, a C/C++20 toolchain and Python
>= 3.11. Clang is also needed for the Clang sanitizer check. Build the pinned
Goose compiler with `make setup`, or pass `GOOSE=/absolute/path/to/matching/goose`.

No pip packages are required. The differential oracle uses only the Python
standard library. The benchmark fetches the pinned competitor with
`bench/fetch.py`; it is a benchmark dependency, not a library runtime
dependency.

Report vulnerabilities privately; see [SECURITY.md](SECURITY.md).
