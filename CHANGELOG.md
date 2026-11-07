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

No release. No performance measurement recorded yet.
