# Design

## The problem this solves

A MessagePack decoder that trusts its input is a denial-of-service primitive.
Three shapes of attack need no bug at all, only a well-formed header:

1. **A declared length that is never delivered.** `str32` with length
   `0xffffffff` in a five-byte buffer. A decoder that reserves the declared
   length before checking the buffer allocates 4 GiB and then fails.
2. **Deep nesting.** `0x91` repeated a million times is a million-element
   array of one-element arrays. A recursive decoder exhausts the stack; the
   input is 1 MiB.
3. **A container count that is never delivered.** `0xdd` with count
   `0xffffffff` asks for four billion map entries from nine bytes.

None of these is a malformed message. Each is a valid header followed by
nothing, and each is cheap to send. The defence is a budget checked against
the **declared** value, before the allocation or the recursion.

## Budgets before allocation

Every limit is compared against the length in the header, at the point the
header is read:

```goose
fn payload(reader: Reader&, width: i64, limit: i64, error: Error, start: i64) -> const u8[:], Error {
    if !need(reader, width) { return "", fail(reader, Error.Truncated, start); }
    let n = be(reader, reader._at, width) as i64;
    if n < 0 || n > limit { return "", fail(reader, error, start); }
    ...
}
```

The order matters. `need` first, so a truncated header is `Truncated` and not a
budget error. Then the budget, so a 4 GiB `str32` is `StrLimit` after five
bytes. Only then is the payload view taken, and it is a view: the reader never
copies a payload, so there is no allocation to bound in the first place.

The writer mirrors this. `reserve(writer, size)` checks
`_out.len + size <= max_output_bytes` before pushing anything, so a writer
cannot grow past its budget even if the caller writes a 1 MiB string into a
1 KiB budget.

## Depth accounting

The reader keeps a fixed `i64[..256]` stack of remaining element counts. A
container costs one slot, never a node, and the stack cannot grow, so the
reader allocates nothing and `max_depth` is bounded by the array length as well
as by the limit.

The subtle part is when a frame closes. A container whose **last** element is
itself a container must keep its slot until the child closes, otherwise the
parent's remaining count is decremented twice. The implementation separates
the two:

```goose
fn close_completed(reader: Reader&) {
    while reader._remaining.len > 0 && reader._remaining[reader._remaining.len - 1] == 0 {
        reader._remaining.pop();
        reader._depth -= 1;
    }
}
```

`close_completed` pops every frame that has reached zero, in a loop, so a chain
of containers each ending in a container unwinds in one call. `_depth` is a
separate counter rather than `_remaining.len` because the two disagree for the
duration of that loop.

This was a real bug during development: with `_depth` derived from the stack
length, a container whose last child was a container reported one level too
shallow, and `max_depth` was off by one on exactly that shape. The regression
is in [tests/api.goose](../tests/api.goose) as the nested-final-child case.

## Token reader, not a DOM

The reader returns one `Token` per wire value and never builds a tree. A
caller that wants a tree builds it; a caller that wants to validate, filter or
forward a message does not pay for one. This is the difference from a
`value::decode`-style API, and it is why the reader can promise zero
allocation: a tree needs a pool, a token stream needs a cursor.

The cost is that the caller drives the structure. `next` reports
`Array { count }` and the caller reads `count` elements; `Map { count }`
counts pairs, so the caller reads `2 * count`. `skip` exists so a caller can
ignore a member it does not understand without writing a recursive walk.

## Full-input contract

`finish` is separate from `done` on purpose. `done` answers "is the top-level
value complete"; `finish` answers "was the input exactly one value". A protocol
that frames messages needs the second: a decoder that stops at the end of the
first value silently accepts a message with a second value appended, which is
how request smuggling works.

`finish` is a pure check. It does not set the sticky error, so a caller can
call it, see `TrailingBytes`, and decide to read the next value from the same
buffer. That is the streaming case, and poisoning the reader would make it
impossible.

## Integer policy

Shortest form, matching `rmp`'s `write_uint` and `write_sint`, so a
non-negative value always uses the unsigned family and `int(5) == uint(5)`.
This is the choice that makes the output byte-identical to the Rust ecosystem's
default encoder, which is what a Goose service talking to an `rmp-serde` peer
needs.

On read, `Int` and `Uint` report the marker family rather than the sign,
because the wire form is what a forwarding proxy must preserve. `as_i64` and
`as_u64` do the conversion when the caller wants a number.

## UTF-8 policy

`str` is validated on both sides. The MessagePack specification calls `str` a
"UTF-8 string" but does not require a decoder to check, and most decoders do
not. This library does, for one reason: `text(token)` is documented to return
validated UTF-8, and a promise like that is worth more than the few cycles it
costs. A caller that wants opaque bytes uses `bin`, which is never validated.

The validator is a private function in `msgpack.goose` rather than a call into
`goose-text`, which already exposes `validate_utf8`. The reason is that this
library has no dependencies at all: a consumer that wants a bounded codec
should not have to pull in a text library to get one. The duplication is about
forty lines and is covered by the same differential corpus.

Rejected: overlong encodings, surrogates (U+D800..U+DFFF), truncated
sequences, code points above U+10FFFF, and a continuation byte without a lead.
Accepted: non-characters such as U+FFFE and U+FFFF, which are valid UTF-8 and
which the specification does not forbid.

## What is deliberately absent

- **No DOM.** A tree builder is a different library with a different budget
  model (a node pool, not a cursor).
- **No map key uniqueness check.** Detecting a duplicate key needs a hash set,
  which is an allocation the reader promises not to make. The caller has the
  count and the keys.
- **No canonical-form enforcement on read.** A non-shortest integer is valid
  MessagePack and is accepted. The writer always emits the shortest form, so a
  decode-then-encode round trip canonicalises.
- **No timestamp interpretation.** `ext` type `-1` is returned as opaque
  bytes. A timestamp is a policy, not a wire format.
- **No streaming writer.** The writer owns one buffer and grows it. A caller
  that needs to flush incrementally takes `output` and clears.
