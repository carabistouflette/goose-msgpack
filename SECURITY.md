# Security policy

Experimental module, validated on Linux x86-64 only. Report sensitive
vulnerabilities privately through GitHub's vulnerability reporting facility when
available, or contact the maintainer privately before public disclosure.

## What the budgets do and do not promise

The limits constrain the bytes, nodes, depth, string, binary and container
counts the reader and writer will accept or emit. They are checked against the
declared length in the header, before the payload is read or reserved, so a
five-byte `str32` header declaring 4 GiB is rejected without allocating 4 GiB.

They do **not** promise:

- exact allocator or RSS bounds. The writer grows a `u8[>..]`; the allocator
  may round up, and a failed allocation is not recoverable.
- protection against a caller that ignores an error and keeps calling. The
  reader is poisoned after a failure, but the writer's output is still readable.
- protection against a caller that sets `max_input_bytes` to 64 MiB and then
  hands the reader 64 MiB of valid data. The budget bounds the work; it does
  not make the work free.

## Trust boundary

The reader treats its input as untrusted. The writer treats its arguments as
trusted: a caller that passes a 1 MiB string with `max_output_bytes` set to
1 MiB gets `OutputLimit`, but a caller that passes a slice it does not own is
outside the contract.

Do not modify or deserialize internal `Reader` or `Writer` state. Public root
owners follow Goose's lifetime and bounds rules.

## Full input

`finish` is the only function that proves the input held exactly one value. A
decoder that stops at `done` accepts a message with a second value appended.
Applications that frame messages must call `finish` and must treat
`TrailingBytes` as a rejection, not a warning.

## UTF-8

`str` is validated on both sides. `bin` and `ext` are opaque and are never
validated. A caller that stores `bin` bytes as text is outside the contract.

## What this library does not do

- It does not authenticate, encrypt or sign anything.
- It does not limit total process memory; it limits one reader or writer.
- It does not protect against a caller that decodes into an unbounded
  application-level structure. The token stream is bounded; what you build from
  it is your budget.
- It does not interpret `ext` type `-1` as a timestamp, so a timestamp
  extension is opaque bytes and carries no validation.
