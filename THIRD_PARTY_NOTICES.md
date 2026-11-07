# Third-party notices

No third-party runtime source or native backend is vendored. The separately
fetched pinned Goose compiler and standard library retain their source
licenses.

## Specification

The wire format is the MessagePack specification,
<https://github.com/msgpack/msgpack/blob/master/spec.md>. It is documentation,
not source; no specification text or reference implementation source is copied
into this repository. The integer and float encoding choices follow the
conventions of the Rust `rmp` crate so that output is byte-compatible with
`rmp-serde` peers; no `rmp` source is copied.

## Independent oracle

`tests/oracle.py` is an independent implementation of the same contract in
Python, written for this repository. It uses only the Python standard library.
It shares no code with the Goose library and no code with any third-party
MessagePack implementation.

## Benchmark dependency

`bench/fetch.py` clones <https://github.com/Macho0x/goose-msgpack> at
`a3d08d25f0260a964f795008ac79468f728a1388` (v0.2.2) into `.build/competitor/`
for the benchmark only. It is a benchmark dependency, not a Goose library
runtime dependency. The clone is not redistributed here: `.build/` is ignored,
and the competitor's own `LICENSE` applies to its source. The competitor's
source is not modified.

## Compiler

The pinned Goose compiler and its standard library are fetched by
`scripts/setup-goose.sh` at the revision in `GOOSE_REVISION`. They retain their
own licences and are not redistributed here.

See LICENSE for this repository's Apache-2.0 terms.
