// SPDX-License-Identifier: Apache-2.0
// Bounded MessagePack tokens for Goose: a reader and a writer, no value tree.
// Spec: https://github.com/msgpack/msgpack/blob/master/spec.md
//
// The reader borrows the caller's bytes and returns one token at a time, so a
// container costs one stack entry, never a node. Every budget is checked before
// the work it bounds: the input length before the first token, a declared
// container length against the bytes that remain, a string length before the
// payload is validated, and the output length before a byte is appended.
//
// The full-input contract is explicit: `finish` succeeds only when the whole
// input was consumed by exactly one top-level value. A caller that wants one
// value out of a longer stream stops at `done` and reads the rest itself.
namespace msgpack;
import std;
import binary;

// Hard maxima. A Limits field above its maximum is InvalidOptions.
const MAX_INPUT_BYTES:   i64 = 67108864;
const MAX_OUTPUT_BYTES:  i64 = 67108864;
const MAX_NODES:         i64 = 1048576;
const MAX_DEPTH:         i64 = 256;
const MAX_STR_BYTES:     i64 = 16777216;
const MAX_BIN_BYTES:     i64 = 16777216;
const MAX_CONTAINER_LEN: i64 = 1048576;

// Defaults are deliberately small: a task manifest or a protocol frame, not a
// bulk data file. Raise them per call site rather than globally.
struct Limits {
    max_input_bytes:   i64 = 1048576,
    max_output_bytes:  i64 = 1048576,
    max_nodes:         i64 = 65536,
    max_depth:         i64 = 32,
    max_str_bytes:     i64 = 262144,
    max_bin_bytes:     i64 = 262144,
    max_container_len: i64 = 65536,
}

enum Error {
    None,
    InvalidOptions,
    InvalidState,
    Truncated,
    Reserved,
    DepthLimit,
    NodeLimit,
    InputLimit,
    OutputLimit,
    StrLimit,
    BinLimit,
    ContainerLimit,
    TrailingBytes,
    Unbalanced,
    InvalidUtf8,
}

// One wire value. `Int` and `Uint` report the marker family that was read, not
// the mathematical sign: a positive fixint is `Uint`, a negative fixint is
// `Int`. `Str`, `Bin` and `Ext` payloads are views into the reader's input.
enum Token {
    Nil,
    Bool { v: bool },
    Int { v: i64 },
    Uint { v: u64 },
    F32 { v: f32 },
    F64 { v: f64 },
    Str { v: const u8[:] },
    Bin { v: const u8[:] },
    Array { count: i64 },
    Map { count: i64 },
    Ext { typ: i8, v: const u8[:] },
}

// The depth stack is a fixed array: the reader allocates nothing, and a
// container costs one i64 slot, never a node.
struct Reader {
    _limits:    Limits      = Limits { .. },
    _input:     const u8[:] = "",
    _at:        i64         = 0,
    _nodes:     i64         = 0,
    _depth:     i64         = 0,
    _remaining: i64[..256]  = [],
    _error:     Error       = Error.None,
    _offset:    i64         = 0,
    _started:   bool        = false,
    _complete:  bool        = false,
}

root struct Writer {
    _limits:      Limits     = Limits { .. },
    _out:         u8[>..]    = [],
    _nodes:       i64        = 0,
    _depth:       i64        = 0,
    _remaining:   i64[..256] = [],
    _error:       Error      = Error.None,
    _initialized: bool       = false,
}

fn valid_limits(limits: Limits) -> bool {
    return limits.max_input_bytes >= 0 && limits.max_input_bytes <= MAX_INPUT_BYTES &&
        limits.max_output_bytes >= 0 && limits.max_output_bytes <= MAX_OUTPUT_BYTES &&
        limits.max_nodes >= 0 && limits.max_nodes <= MAX_NODES &&
        limits.max_depth >= 0 && limits.max_depth <= MAX_DEPTH &&
        limits.max_str_bytes >= 0 && limits.max_str_bytes <= MAX_STR_BYTES &&
        limits.max_bin_bytes >= 0 && limits.max_bin_bytes <= MAX_BIN_BYTES &&
        limits.max_container_len >= 0 && limits.max_container_len <= MAX_CONTAINER_LEN;
}

// ---- reader ------------------------------------------------------------

fn init(reader: Reader&, input: const u8[:], limits: Limits = Limits { .. }) -> Error {
    if !valid_limits(limits) { return Error.InvalidOptions; }
    reader._limits = limits;
    reader._input = input;
    reader._at = 0;
    reader._nodes = 0;
    reader._depth = 0;
    reader._remaining.clear();
    reader._error = Error.None;
    reader._offset = 0;
    reader._started = false;
    reader._complete = false;
    // The input budget is checked before any token is decoded.
    if input.len > limits.max_input_bytes {
        reader._error = Error.InputLimit;
        return Error.InputLimit;
    }
    return Error.None;
}

fn fail(reader: Reader&, error: Error, offset: i64) -> Error {
    reader._error = error;
    reader._offset = offset;
    return error;
}

// True once exactly one top-level value has been read. Trailing bytes are not
// consumed and are reported by `finish`.
fn done(reader: const Reader&) -> bool { return reader._complete; }
fn offset(reader: const Reader&) -> i64 { return reader._offset; }
fn consumed(reader: const Reader&) -> i64 { return reader._at; }
fn depth(reader: const Reader&) -> i64 { return reader._depth; }
// Elements left in the innermost open container, or -1 at the top level.
fn remaining(reader: const Reader&) -> i64 {
    if reader._remaining.len == 0 { return -1; }
    return reader._remaining[reader._remaining.len - 1];
}

// The full-input contract. None means one complete value and no trailing byte.
fn finish(reader: Reader&) -> Error {
    if reader._error != Error.None { return reader._error; }
    reader._offset = reader._at;
    if !reader._started { return Error.InvalidState; }
    if !reader._complete {
        if reader._at >= reader._input.len { return Error.Truncated; }
        return Error.Unbalanced;
    }
    if reader._at < reader._input.len { return Error.TrailingBytes; }
    return Error.None;
}

fn need(reader: const Reader&, n: i64) -> bool {
    return n >= 0 && reader._input.len - reader._at >= n;
}

fn be(reader: const Reader&, at: i64, width: i64) -> u64 {
    var raw: u64 = 0;
    for i in width { raw = (raw << 8) | reader._input[at + i]; }
    return raw;
}

// Sign-extend a big-endian field of `width` bytes.
fn sign(raw: u64, width: i64) -> i64 {
    if width == 1 {
        if raw >= 0x80 { return (raw as! i64) - 0x100; }
        return raw as! i64;
    }
    if width == 2 {
        if raw >= 0x8000 { return (raw as! i64) - 0x10000; }
        return raw as! i64;
    }
    if width == 4 {
        if raw >= 0x80000000 { return (raw as! i64) - 0x100000000; }
        return raw as! i64;
    }
    return raw as! i64;
}

// Account for one produced value in its parent, then drop containers whose
// elements are all read.
// Close every container whose elements are all read. `_depth` counts open
// containers, so a container whose last element is another container keeps its
// slot until that child closes.
fn close_completed(reader: Reader&) {
    while reader._remaining.len > 0 && reader._remaining[reader._remaining.len - 1] == 0 {
        reader._remaining.pop();
        reader._depth -= 1;
    }
}

fn scalar(reader: Reader&, token: Token) -> Token, Error {
    if reader._remaining.len > 0 { reader._remaining[reader._remaining.len - 1] -= 1; }
    close_completed(reader);
    if reader._depth == 0 { reader._complete = true; }
    return token, Error.None;
}

fn open(reader: Reader&, token: Token, elements: i64, start: i64) -> Token, Error {
    if reader._remaining.len > 0 { reader._remaining[reader._remaining.len - 1] -= 1; }
    if elements > 0 {
        if reader._depth >= reader._limits.max_depth {
            return Token.Nil, fail(reader, Error.DepthLimit, start);
        }
        reader._remaining.push(elements);
        reader._depth += 1;
    } else {
        close_completed(reader);
        if reader._depth == 0 { reader._complete = true; }
    }
    return token, Error.None;
}

// `n` bytes at the cursor. The budget and the remaining input are checked
// before the view is taken, so no oversized value is accepted.
fn take(reader: Reader&, n: i64, limit: i64, error: Error, start: i64) -> const u8[:], Error {
    if n > limit { return "", fail(reader, error, start); }
    if !need(reader, n) { return "", fail(reader, Error.Truncated, start); }
    let view = reader._input[reader._at..reader._at + n];
    reader._at += n;
    return view, Error.None;
}

// A length-prefixed payload: the cursor is on the length field.
fn payload(reader: Reader&, width: i64, limit: i64, error: Error, start: i64) -> const u8[:], Error {
    if !need(reader, width) { return "", fail(reader, Error.Truncated, start); }
    let n = be(reader, reader._at, width) as i64;
    reader._at += width;
    return take(reader, n, limit, error, start);
}

// A str payload is validated before it becomes a token.
fn str_body(reader: Reader&, view: const u8[:], start: i64) -> Token, Error {
    if !valid_utf8(view) { return Token.Nil, fail(reader, Error.InvalidUtf8, start); }
    return scalar(reader, Token.Str { v: view });
}

fn ext_body(reader: Reader&, n: i64, start: i64) -> Token, Error {
    if n > reader._limits.max_bin_bytes { return Token.Nil, fail(reader, Error.BinLimit, start); }
    if !need(reader, n + 1) { return Token.Nil, fail(reader, Error.Truncated, start); }
    let typ = reader._input[reader._at] as! i8;
    reader._at += 1;
    let view = reader._input[reader._at..reader._at + n];
    reader._at += n;
    return scalar(reader, Token.Ext { typ: typ, v: view });
}

fn array_body(reader: Reader&, n: i64, start: i64) -> Token, Error {
    if n > reader._limits.max_container_len { return Token.Nil, fail(reader, Error.ContainerLimit, start); }
    // Every element needs at least one byte: reject an impossible count before
    // the caller loops over it.
    if n > reader._input.len - reader._at { return Token.Nil, fail(reader, Error.Truncated, start); }
    return open(reader, Token.Array { count: n }, n, start);
}

fn map_body(reader: Reader&, n: i64, start: i64) -> Token, Error {
    if n > reader._limits.max_container_len { return Token.Nil, fail(reader, Error.ContainerLimit, start); }
    if n > (reader._input.len - reader._at) / 2 { return Token.Nil, fail(reader, Error.Truncated, start); }
    return open(reader, Token.Map { count: n }, n * 2, start);
}

fn next(reader: Reader&) -> Token, Error {
    if reader._error != Error.None { return Token.Nil, reader._error; }
    if reader._complete { return Token.Nil, fail(reader, Error.InvalidState, reader._at); }
    if reader._at >= reader._input.len { return Token.Nil, fail(reader, Error.Truncated, reader._at); }
    if reader._nodes >= reader._limits.max_nodes { return Token.Nil, fail(reader, Error.NodeLimit, reader._at); }
    let start = reader._at;
    let marker = reader._input[reader._at];
    reader._nodes += 1;
    reader._started = true;
    if marker <= 0x7f {
        reader._at += 1;
        return scalar(reader, Token.Uint { v: marker });
    }
    if marker >= 0xe0 {
        reader._at += 1;
        return scalar(reader, Token.Int { v: (marker as! i64) - 0x100 });
    }
    if marker >= 0xa0 && marker <= 0xbf {
        let n = marker & 0x1f;
        reader._at += 1;
        let view, error = take(reader, n, reader._limits.max_str_bytes, Error.StrLimit, start);
        if error != Error.None { return Token.Nil, error; }
        return str_body(reader, view, start);
    }
    if marker >= 0x90 && marker <= 0x9f {
        reader._at += 1;
        return array_body(reader, marker & 0x0f, start);
    }
    if marker >= 0x80 && marker <= 0x8f {
        reader._at += 1;
        return map_body(reader, marker & 0x0f, start);
    }
    if marker == 0xc0 { reader._at += 1; return scalar(reader, Token.Nil); }
    if marker == 0xc1 { return Token.Nil, fail(reader, Error.Reserved, start); }
    if marker == 0xc2 { reader._at += 1; return scalar(reader, Token.Bool { v: false }); }
    if marker == 0xc3 { reader._at += 1; return scalar(reader, Token.Bool { v: true }); }
    if marker >= 0xc4 && marker <= 0xc6 {
        let width = 1 << (marker - 0xc4);
        reader._at += 1;
        let view, error = payload(reader, width, reader._limits.max_bin_bytes, Error.BinLimit, start);
        if error != Error.None { return Token.Nil, error; }
        return scalar(reader, Token.Bin { v: view });
    }
    if marker >= 0xc7 && marker <= 0xc9 {
        let width = 1 << (marker - 0xc7);
        reader._at += 1;
        if !need(reader, width) { return Token.Nil, fail(reader, Error.Truncated, start); }
        let n = be(reader, reader._at, width) as i64;
        reader._at += width;
        return ext_body(reader, n, start);
    }
    if marker == 0xca {
        reader._at += 1;
        if !need(reader, 4) { return Token.Nil, fail(reader, Error.Truncated, start); }
        let bits = be(reader, reader._at, 4) as u32;
        reader._at += 4;
        return scalar(reader, Token.F32 { v: binary::f32_of_bits(bits) });
    }
    if marker == 0xcb {
        reader._at += 1;
        if !need(reader, 8) { return Token.Nil, fail(reader, Error.Truncated, start); }
        let bits = be(reader, reader._at, 8);
        reader._at += 8;
        return scalar(reader, Token.F64 { v: binary::f64_of_bits(bits) });
    }
    if marker >= 0xcc && marker <= 0xcf {
        let width = 1 << (marker - 0xcc);
        reader._at += 1;
        if !need(reader, width) { return Token.Nil, fail(reader, Error.Truncated, start); }
        let raw = be(reader, reader._at, width);
        reader._at += width;
        return scalar(reader, Token.Uint { v: raw });
    }
    if marker >= 0xd0 && marker <= 0xd3 {
        let width = 1 << (marker - 0xd0);
        reader._at += 1;
        if !need(reader, width) { return Token.Nil, fail(reader, Error.Truncated, start); }
        let raw = be(reader, reader._at, width);
        reader._at += width;
        return scalar(reader, Token.Int { v: sign(raw, width) });
    }
    if marker >= 0xd4 && marker <= 0xd8 {
        reader._at += 1;
        return ext_body(reader, 1 << (marker - 0xd4), start);
    }
    if marker >= 0xd9 && marker <= 0xdb {
        let width = 1 << (marker - 0xd9);
        reader._at += 1;
        let view, error = payload(reader, width, reader._limits.max_str_bytes, Error.StrLimit, start);
        if error != Error.None { return Token.Nil, error; }
        return str_body(reader, view, start);
    }
    if marker == 0xdc || marker == 0xdd {
        let width = if marker == 0xdc { 2 } else { 4 };
        reader._at += 1;
        if !need(reader, width) { return Token.Nil, fail(reader, Error.Truncated, start); }
        let n = be(reader, reader._at, width) as i64;
        reader._at += width;
        return array_body(reader, n, start);
    }
    // 0xde, 0xdf: the only markers left.
    let width = if marker == 0xde { 2 } else { 4 };
    reader._at += 1;
    if !need(reader, width) { return Token.Nil, fail(reader, Error.Truncated, start); }
    let n = be(reader, reader._at, width) as i64;
    reader._at += width;
    return map_body(reader, n, start);
}

// Skip exactly one complete value, children included. Useful for a member a
// caller does not understand; the budgets still apply.
fn skip(reader: Reader&) -> Error {
    let base = reader._depth;
    let token, error = next(reader);
    if error != Error.None { return error; }
    while reader._depth > base {
        let inner, inner_error = next(reader);
        if inner_error != Error.None { return inner_error; }
    }
    return Error.None;
}

// ---- token accessors ---------------------------------------------------

// An integer of either family, when it fits i64.
fn as_i64(token: Token) -> i64, bool {
    match token {
        Int i => { return i.v, true; },
        Uint u => {
            if u.v <= 0x7fffffffffffffff { return u.v as i64, true; }
            return 0, false;
        },
        _ => { return 0, false; },
    }
}

// A non-negative integer of either family.
fn as_u64(token: Token) -> u64, bool {
    match token {
        Uint u => { return u.v, true; },
        Int i => {
            if i.v >= 0 { return i.v as u64, true; }
            return 0, false;
        },
        _ => { return 0, false; },
    }
}

// A float of either width, widened. Integers are not converted.
fn as_f64(token: Token) -> f64, bool {
    match token {
        F32 f => { return f.v, true; },
        F64 f => { return f.v, true; },
        _ => { return 0.0, false; },
    }
}

fn as_bool(token: Token) -> bool, bool {
    match token {
        Bool b => { return b.v, true; },
        _ => { return false, false; },
    }
}

// The payload of a Str token, already validated as UTF-8.
fn text(token: Token) -> const u8[:] {
    match token {
        Str s => { return s.v; },
        _ => { return ""; },
    }
}

// The payload of a Bin or Ext token, opaque bytes.
fn bytes(token: Token) -> const u8[:] {
    match token {
        Bin b => { return b.v; },
        Ext e => { return e.v; },
        _ => { return ""; },
    }
}

fn ext_type(token: Token) -> i8 {
    match token {
        Ext e => { return e.typ; },
        _ => { return 0; },
    }
}

// The declared element count of an Array, or pair count of a Map.
fn count(token: Token) -> i64 {
    match token {
        Array a => { return a.count; },
        Map m => { return m.count; },
        _ => { return -1; },
    }
}

// ---- writer ------------------------------------------------------------

fn init(writer: Writer&, limits: Limits = Limits { .. }) -> Error {
    if !valid_limits(limits) { return Error.InvalidOptions; }
    writer._limits = limits;
    writer._out.clear();
    writer._nodes = 0;
    writer._depth = 0;
    writer._remaining.clear();
    writer._error = Error.None;
    writer._initialized = true;
    return Error.None;
}

fn fail_w(writer: Writer&, error: Error) -> Error {
    writer._error = error;
    return error;
}

fn begin(writer: Writer&) -> Error {
    if !writer._initialized { return fail_w(writer, Error.InvalidState); }
    if writer._error != Error.None { return writer._error; }
    if writer._nodes >= writer._limits.max_nodes { return fail_w(writer, Error.NodeLimit); }
    writer._nodes += 1;
    return Error.None;
}

// The output budget is checked before a byte is appended.
fn reserve(writer: Writer&, size: i64) -> Error {
    if size < 0 { return fail_w(writer, Error.InvalidState); }
    if size > writer._limits.max_output_bytes - writer._out.len {
        return fail_w(writer, Error.OutputLimit);
    }
    return Error.None;
}

fn push_be(writer: Writer&, value: u64, width: i64) {
    var i = width - 1;
    while i >= 0 {
        writer._out.push(((value >> (i * 8)) & 0xff) as u8);
        i -= 1;
    }
}

fn close_completed_w(writer: Writer&) {
    while writer._remaining.len > 0 && writer._remaining[writer._remaining.len - 1] == 0 {
        writer._remaining.pop();
        writer._depth -= 1;
    }
}

fn close_w(writer: Writer&) {
    if writer._remaining.len > 0 { writer._remaining[writer._remaining.len - 1] -= 1; }
    close_completed_w(writer);
}

fn open_w(writer: Writer&, elements: i64) -> Error {
    if writer._remaining.len > 0 { writer._remaining[writer._remaining.len - 1] -= 1; }
    if elements > 0 {
        if writer._depth >= writer._limits.max_depth { return fail_w(writer, Error.DepthLimit); }
        writer._remaining.push(elements);
        writer._depth += 1;
    } else {
        close_completed_w(writer);
    }
    return Error.None;
}

fn nil(writer: Writer&) -> Error {
    let error = begin(writer);
    if error != Error.None { return error; }
    let error = reserve(writer, 1);
    if error != Error.None { return error; }
    writer._out.push(0xc0);
    close_w(writer);
    return Error.None;
}

fn boolean(writer: Writer&, v: bool) -> Error {
    let error = begin(writer);
    if error != Error.None { return error; }
    let error = reserve(writer, 1);
    if error != Error.None { return error; }
    writer._out.push(if v { 0xc3 } else { 0xc2 });
    close_w(writer);
    return Error.None;
}

// Shortest form, as rmp's write_uint: a non-negative value uses the unsigned
// family, so `int(5)` and `uint(5)` produce the same byte.
fn uint(writer: Writer&, v: u64) -> Error {
    let error = begin(writer);
    if error != Error.None { return error; }
    let size = if v <= 0x7f { 1 } else if v <= 0xff { 2 } else if v <= 0xffff { 3 } else if v <= 0xffffffff { 5 } else { 9 };
    let error = reserve(writer, size);
    if error != Error.None { return error; }
    if v <= 0x7f {
        writer._out.push(v as u8);
    } else if v <= 0xff {
        writer._out.push(0xcc);
        writer._out.push(v as u8);
    } else if v <= 0xffff {
        writer._out.push(0xcd);
        push_be(writer, v, 2);
    } else if v <= 0xffffffff {
        writer._out.push(0xce);
        push_be(writer, v, 4);
    } else {
        writer._out.push(0xcf);
        push_be(writer, v, 8);
    }
    close_w(writer);
    return Error.None;
}

// Shortest form, as rmp's write_sint: negative values use the negative fixint
// or the signed family; non-negative values delegate to `uint`.
fn int(writer: Writer&, v: i64) -> Error {
    if v >= 0 { return uint(writer, v as u64); }
    let error = begin(writer);
    if error != Error.None { return error; }
    let size = if v >= -32 { 1 } else if v >= -128 { 2 } else if v >= -32768 { 3 } else if v >= -2147483648 { 5 } else { 9 };
    let error = reserve(writer, size);
    if error != Error.None { return error; }
    if v >= -32 {
        writer._out.push(v as! u8);
    } else if v >= -128 {
        writer._out.push(0xd0);
        writer._out.push(v as! u8);
    } else if v >= -32768 {
        writer._out.push(0xd1);
        push_be(writer, (v as! u64) & 0xffff, 2);
    } else if v >= -2147483648 {
        writer._out.push(0xd2);
        push_be(writer, (v as! u64) & 0xffffffff, 4);
    } else {
        writer._out.push(0xd3);
        push_be(writer, v as! u64, 8);
    }
    close_w(writer);
    return Error.None;
}

// IEEE-754 big-endian. The bytes come from the value's own image, reversed on a
// little-endian host, so no bit-cast builtin is needed.
fn float32(writer: Writer&, v: f32) -> Error {
    let error = begin(writer);
    if error != Error.None { return error; }
    let error = reserve(writer, 5);
    if error != Error.None { return error; }
    let image: f32[1] = [v];
    let raw = bytes_of(image);
    writer._out.push(0xca);
    if little_endian() {
        var i: i64 = 3;
        while i >= 0 { writer._out.push(raw[i]); i -= 1; }
    } else {
        for i in 4 { writer._out.push(raw[i]); }
    }
    close_w(writer);
    return Error.None;
}

fn float64(writer: Writer&, v: f64) -> Error {
    let error = begin(writer);
    if error != Error.None { return error; }
    let error = reserve(writer, 9);
    if error != Error.None { return error; }
    let image: f64[1] = [v];
    let raw = bytes_of(image);
    writer._out.push(0xcb);
    if little_endian() {
        var i: i64 = 7;
        while i >= 0 { writer._out.push(raw[i]); i -= 1; }
    } else {
        for i in 8 { writer._out.push(raw[i]); }
    }
    close_w(writer);
    return Error.None;
}

fn str_header_size(n: i64) -> i64 {
    if n <= 31 { return 1; }
    if n <= 0xff { return 2; }
    if n <= 0xffff { return 3; }
    return 5;
}

// A UTF-8 string. The payload is validated before any byte is written, so a
// malformed string never reaches the output.
fn str(writer: Writer&, v: const u8[:]) -> Error {
    let error = begin(writer);
    if error != Error.None { return error; }
    if v.len > writer._limits.max_str_bytes { return fail_w(writer, Error.StrLimit); }
    if !valid_utf8(v) { return fail_w(writer, Error.InvalidUtf8); }
    let error = reserve(writer, str_header_size(v.len) + v.len);
    if error != Error.None { return error; }
    if v.len <= 31 {
        writer._out.push(0xa0 | (v.len as u8));
    } else if v.len <= 0xff {
        writer._out.push(0xd9);
        writer._out.push(v.len as u8);
    } else if v.len <= 0xffff {
        writer._out.push(0xda);
        push_be(writer, v.len as u64, 2);
    } else {
        writer._out.push(0xdb);
        push_be(writer, v.len as u64, 4);
    }
    writer._out.append(v);
    close_w(writer);
    return Error.None;
}

fn bin_header_size(n: i64) -> i64 {
    if n <= 0xff { return 2; }
    if n <= 0xffff { return 3; }
    return 5;
}

// Opaque bytes: no encoding is assumed or checked.
fn bin(writer: Writer&, v: const u8[:]) -> Error {
    let error = begin(writer);
    if error != Error.None { return error; }
    if v.len > writer._limits.max_bin_bytes { return fail_w(writer, Error.BinLimit); }
    let error = reserve(writer, bin_header_size(v.len) + v.len);
    if error != Error.None { return error; }
    if v.len <= 0xff {
        writer._out.push(0xc4);
        writer._out.push(v.len as u8);
    } else if v.len <= 0xffff {
        writer._out.push(0xc5);
        push_be(writer, v.len as u64, 2);
    } else {
        writer._out.push(0xc6);
        push_be(writer, v.len as u64, 4);
    }
    writer._out.append(v);
    close_w(writer);
    return Error.None;
}

// An extension value. The fixed forms are used for 1, 2, 4, 8 and 16 bytes.
fn ext(writer: Writer&, typ: i8, v: const u8[:]) -> Error {
    let error = begin(writer);
    if error != Error.None { return error; }
    if v.len > writer._limits.max_bin_bytes { return fail_w(writer, Error.BinLimit); }
    let fixed = v.len == 1 || v.len == 2 || v.len == 4 || v.len == 8 || v.len == 16;
    let header = if fixed { 2 } else if v.len <= 0xff { 3 } else if v.len <= 0xffff { 4 } else { 6 };
    let error = reserve(writer, header + v.len);
    if error != Error.None { return error; }
    if fixed {
        let marker = if v.len == 1 { 0xd4 } else if v.len == 2 { 0xd5 } else if v.len == 4 { 0xd6 } else if v.len == 8 { 0xd7 } else { 0xd8 };
        writer._out.push(marker as u8);
    } else if v.len <= 0xff {
        writer._out.push(0xc7);
        writer._out.push(v.len as u8);
    } else if v.len <= 0xffff {
        writer._out.push(0xc8);
        push_be(writer, v.len as u64, 2);
    } else {
        writer._out.push(0xc9);
        push_be(writer, v.len as u64, 4);
    }
    writer._out.push(typ as! u8);
    writer._out.append(v);
    close_w(writer);
    return Error.None;
}

fn array(writer: Writer&, n: i64) -> Error {
    if n < 0 { return fail_w(writer, Error.InvalidOptions); }
    let error = begin(writer);
    if error != Error.None { return error; }
    if n > writer._limits.max_container_len { return fail_w(writer, Error.ContainerLimit); }
    if n > 0 && writer._depth >= writer._limits.max_depth { return fail_w(writer, Error.DepthLimit); }
    let size = if n <= 15 { 1 } else if n <= 0xffff { 3 } else { 5 };
    let error = reserve(writer, size);
    if error != Error.None { return error; }
    if n <= 15 {
        writer._out.push(0x90 | (n as u8));
    } else if n <= 0xffff {
        writer._out.push(0xdc);
        push_be(writer, n as u64, 2);
    } else {
        writer._out.push(0xdd);
        push_be(writer, n as u64, 4);
    }
    return open_w(writer, n);
}

fn map(writer: Writer&, n: i64) -> Error {
    if n < 0 { return fail_w(writer, Error.InvalidOptions); }
    let error = begin(writer);
    if error != Error.None { return error; }
    if n > writer._limits.max_container_len { return fail_w(writer, Error.ContainerLimit); }
    if n > 0 && writer._depth >= writer._limits.max_depth { return fail_w(writer, Error.DepthLimit); }
    let size = if n <= 15 { 1 } else if n <= 0xffff { 3 } else { 5 };
    let error = reserve(writer, size);
    if error != Error.None { return error; }
    if n <= 15 {
        writer._out.push(0x80 | (n as u8));
    } else if n <= 0xffff {
        writer._out.push(0xde);
        push_be(writer, n as u64, 2);
    } else {
        writer._out.push(0xdf);
        push_be(writer, n as u64, 4);
    }
    return open_w(writer, n * 2);
}

// None only when every container was closed. Output is meaningful only then.
fn finish(writer: Writer&) -> Error {
    if !writer._initialized { return Error.InvalidState; }
    if writer._error != Error.None { return writer._error; }
    close_completed_w(writer);
    if writer._depth > 0 { return Error.Unbalanced; }
    return Error.None;
}

fn output(writer: const Writer&) -> const u8[:] { return writer._out[..] }
fn written(writer: const Writer&) -> i64 { return writer._out.len; }

// ---- UTF-8 -------------------------------------------------------------

fn continuation(b: u8) -> bool { return b >= 0x80 && b <= 0xbf; }

// Strict UTF-8: rejects overlong forms, surrogates, values above U+10FFFF and
// truncated sequences. `bin` is the path for bytes that are not text.
fn valid_utf8(bytes: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < bytes.len {
        let b = bytes[i];
        if b < 0x80 { i += 1; continue; }
        if b < 0xc2 { return false; }
        if b < 0xe0 {
            if i + 1 >= bytes.len { return false; }
            if !continuation(bytes[i + 1]) { return false; }
            i += 2; continue;
        }
        if b < 0xf0 {
            if i + 2 >= bytes.len { return false; }
            let b1 = bytes[i + 1];
            if !continuation(b1) { return false; }
            if b == 0xe0 && b1 < 0xa0 { return false; }
            if b == 0xed && b1 > 0x9f { return false; }
            if !continuation(bytes[i + 2]) { return false; }
            i += 3; continue;
        }
        if b < 0xf5 {
            if i + 3 >= bytes.len { return false; }
            let b1 = bytes[i + 1];
            if !continuation(b1) { return false; }
            if b == 0xf0 && b1 < 0x90 { return false; }
            if b == 0xf4 && b1 > 0x8f { return false; }
            if !continuation(bytes[i + 2]) || !continuation(bytes[i + 3]) { return false; }
            i += 4; continue;
        }
        return false;
    }
    return true;
}

// Host byte order, probed once. Only the float writers depend on it.
fn little_endian() -> bool {
    let probe: u16[1] = [1];
    let raw = bytes_of(probe);
    return raw[0] == 1;
}
