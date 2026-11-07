// SPDX-License-Identifier: Apache-2.0
// Contract tests for the bounded MessagePack reader and writer.
// Every case names the contract it checks; a failure prints the case and exits 1.
import msgpack from "..";
import std;
import os;

var failures: i64 = 0;
var checks:   i64 = 0;

fn expect(ok: bool, what: const u8[:]) {
    checks += 1;
    if ok { return; }
    failures += 1;
    write_stderr("FAIL ");
    write_stderr(what);
    write_stderr("\n");
}

fn expect_error(actual: msgpack::Error, wanted: msgpack::Error, what: const u8[:]) {
    checks += 1;
    if actual == wanted { return; }
    failures += 1;
    write_stderr("FAIL ");
    write_stderr(what);
    write_stderr(": wanted ");
    write_stderr(str(wanted));
    write_stderr(" got ");
    write_stderr(str(actual));
    write_stderr("\n");
}

fn expect_bytes(actual: const u8[:], wanted: const u8[:], what: const u8[:]) {
    checks += 1;
    if actual == wanted { return; }
    failures += 1;
    write_stderr("FAIL ");
    write_stderr(what);
    write_stderr(": wanted ");
    write_stderr(wanted);
    write_stderr(" got ");
    write_stderr(actual);
    write_stderr("\n");
}

// Encode one value through a fresh writer and compare the bytes.
fn encoded(what: const u8[:], wanted: const u8[:], limits: msgpack::Limits = msgpack::Limits { .. }) {
    var writer = msgpack::Writer { .. };
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, what);
    encode_into(writer, what);
    expect_error(msgpack::finish(writer), msgpack::Error.None, what);
    expect_bytes(msgpack::output(writer), wanted, what);
}

// A container header with no elements yet: the bytes are final, the value is not.
fn encoded_open(what: const u8[:], wanted: const u8[:]) {
    var writer = msgpack::Writer { .. };
    expect_error(msgpack::init(writer), msgpack::Error.None, what);
    encode_into(writer, what);
    expect_bytes(msgpack::output(writer), wanted, what);
    expect_error(msgpack::finish(writer), msgpack::Error.Unbalanced, what);
}

// The value each case writes, selected by the case name. Returns the first
// error, so a caller can drive the same value under a tight budget too.
fn write_case(writer: msgpack::Writer&, what: const u8[:]) -> msgpack::Error {
    if what == "nil" { return msgpack::nil(writer); }
    if what == "false" { return msgpack::boolean(writer, false); }
    if what == "true" { return msgpack::boolean(writer, true); }
    if what == "uint-0" { return msgpack::uint(writer, 0); }
    if what == "uint-127" { return msgpack::uint(writer, 127); }
    if what == "uint-128" { return msgpack::uint(writer, 128); }
    if what == "uint-255" { return msgpack::uint(writer, 255); }
    if what == "uint-256" { return msgpack::uint(writer, 256); }
    if what == "uint-65535" { return msgpack::uint(writer, 65535); }
    if what == "uint-65536" { return msgpack::uint(writer, 65536); }
    if what == "uint-4294967295" { return msgpack::uint(writer, 4294967295); }
    if what == "uint-4294967296" { return msgpack::uint(writer, 4294967296); }
    if what == "uint-max" { return msgpack::uint(writer, 18446744073709551615); }
    if what == "int-neg1" { return msgpack::int(writer, -1); }
    if what == "int-neg32" { return msgpack::int(writer, -32); }
    if what == "int-neg33" { return msgpack::int(writer, -33); }
    if what == "int-neg128" { return msgpack::int(writer, -128); }
    if what == "int-neg129" { return msgpack::int(writer, -129); }
    if what == "int-neg32768" { return msgpack::int(writer, -32768); }
    if what == "int-neg32769" { return msgpack::int(writer, -32769); }
    if what == "int-neg2147483648" { return msgpack::int(writer, -2147483648); }
    if what == "int-neg2147483649" { return msgpack::int(writer, -2147483649); }
    if what == "int-min" { return msgpack::int(writer, -9223372036854775807 - 1); }
    if what == "int-positive-is-uint" { return msgpack::int(writer, 5); }
    if what == "f32-1.5" { return msgpack::float32(writer, 1.5); }
    if what == "f64-1.5" { return msgpack::float64(writer, 1.5); }
    if what == "f64-neg0" { return msgpack::float64(writer, -0.0); }
    if what == "str-empty" { return msgpack::str(writer, ""); }
    if what == "str-a" { return msgpack::str(writer, "a"); }
    if what == "str-31" { return msgpack::str(writer, "0123456789012345678901234567890"); }
    if what == "str-32" { return msgpack::str(writer, "01234567890123456789012345678901"); }
    if what == "str-utf8" { return msgpack::str(writer, "é"); }
    if what == "bin-empty" { return msgpack::bin(writer, ""); }
    if what == "bin-2" { return msgpack::bin(writer, "\x00\xff"); }
    if what == "ext-1" { return msgpack::ext(writer, 1, "\x7f"); }
    if what == "ext-2" { return msgpack::ext(writer, -1, "\x01\x02"); }
    if what == "ext-3" { return msgpack::ext(writer, 5, "\x01\x02\x03"); }
    if what == "array-0" { return msgpack::array(writer, 0); }
    if what == "array-15" { return msgpack::array(writer, 15); }
    if what == "array-16" { return msgpack::array(writer, 16); }
    if what == "map-0" { return msgpack::map(writer, 0); }
    if what == "map-15" { return msgpack::map(writer, 15); }
    if what == "map-16" { return msgpack::map(writer, 16); }
    abort("unknown case");
}

// The same dispatch, asserting that every write succeeds.
fn encode_into(writer: msgpack::Writer&, what: const u8[:]) {
    expect_error(write_case(writer, what), msgpack::Error.None, what);
}

fn writer_cases() {
    encoded("nil", "\xc0");
    encoded("false", "\xc2");
    encoded("true", "\xc3");
    encoded("uint-0", "\x00");
    encoded("uint-127", "\x7f");
    encoded("uint-128", "\xcc\x80");
    encoded("uint-255", "\xcc\xff");
    encoded("uint-256", "\xcd\x01\x00");
    encoded("uint-65535", "\xcd\xff\xff");
    encoded("uint-65536", "\xce\x00\x01\x00\x00");
    encoded("uint-4294967295", "\xce\xff\xff\xff\xff");
    encoded("uint-4294967296", "\xcf\x00\x00\x00\x01\x00\x00\x00\x00");
    encoded("uint-max", "\xcf\xff\xff\xff\xff\xff\xff\xff\xff");
    encoded("int-neg1", "\xff");
    encoded("int-neg32", "\xe0");
    encoded("int-neg33", "\xd0\xdf");
    encoded("int-neg128", "\xd0\x80");
    encoded("int-neg129", "\xd1\xff\x7f");
    encoded("int-neg32768", "\xd1\x80\x00");
    encoded("int-neg32769", "\xd2\xff\xff\x7f\xff");
    encoded("int-neg2147483648", "\xd2\x80\x00\x00\x00");
    encoded("int-neg2147483649", "\xd3\xff\xff\xff\xff\x7f\xff\xff\xff");
    encoded("int-min", "\xd3\x80\x00\x00\x00\x00\x00\x00\x00");
    // A non-negative int uses the unsigned family, as rmp's write_sint does.
    encoded("int-positive-is-uint", "\x05");
    encoded("f32-1.5", "\xca\x3f\xc0\x00\x00");
    encoded("f64-1.5", "\xcb\x3f\xf8\x00\x00\x00\x00\x00\x00");
    encoded("f64-neg0", "\xcb\x80\x00\x00\x00\x00\x00\x00\x00");
    encoded("str-empty", "\xa0");
    encoded("str-a", "\xa1a");
    encoded("str-31", "\xbf0123456789012345678901234567890");
    encoded("str-32", "\xd9\x2001234567890123456789012345678901");
    encoded("str-utf8", "\xa2\xc3\xa9");
    encoded("bin-empty", "\xc4\x00");
    encoded("bin-2", "\xc4\x02\x00\xff");
    encoded("ext-1", "\xd4\x01\x7f");
    encoded("ext-2", "\xd5\xff\x01\x02");
    encoded("ext-3", "\xc7\x03\x05\x01\x02\x03");
    encoded("array-0", "\x90");
    encoded("map-0", "\x80");
    encoded_open("array-15", "\x9f");
    encoded_open("array-16", "\xdc\x00\x10");
    encoded_open("map-15", "\x8f");
    encoded_open("map-16", "\xde\x00\x10");
}

// Decode `data` and return the token stream as a canonical text image.
fn image(data: const u8[:], limits: msgpack::Limits = msgpack::Limits { .. }) -> u8[>..], msgpack::Error {
    var reader = msgpack::Reader { .. };
    var out: u8[>..] = [];
    let error = msgpack::init(reader, data, limits);
    if error != msgpack::Error.None { return out, error; }
    while !msgpack::done(reader) {
        let token, step = msgpack::next(reader);
        if step != msgpack::Error.None { return out, step; }
        match token {
            Nil => { out.append("nil "); },
            Bool b => { format(out, "bool:", b.v, " "); },
            Int i => { format(out, "int:", i.v, " "); },
            Uint u => { format(out, "uint:", u.v, " "); },
            F32 f => { format(out, "f32:", f.v, " "); },
            F64 f => { format(out, "f64:", f.v, " "); },
            Str s => { format(out, "str:", s.v.len, " "); },
            Bin b => { format(out, "bin:", b.v.len, " "); },
            Array a => { format(out, "array:", a.count, " "); },
            Map m => { format(out, "map:", m.count, " "); },
            Ext e => { format(out, "ext:", e.typ, ":", e.v.len, " "); },
        }
    }
    return out, msgpack::finish(reader);
}

fn reader_cases() {
    var text, error = image("\x82\xa1z\x01\xa1a\x02");
    expect_error(error, msgpack::Error.None, "map round trip");
    expect_bytes(text, "map:2 str:1 uint:1 str:1 uint:2 ", "map token stream");

    // Non-shortest forms decode to the same value and re-encode canonically.
    text, error = image("\xcc\x05");
    expect_error(error, msgpack::Error.None, "uint8 5");
    expect_bytes(text, "uint:5 ", "uint8 5 value");
    text, error = image("\xd1\x00\x05");
    expect_error(error, msgpack::Error.None, "int16 5");
    expect_bytes(text, "int:5 ", "int16 5 value");
    text, error = image("\xcf\x00\x00\x00\x00\x00\x00\x00\x05");
    expect_error(error, msgpack::Error.None, "uint64 5");
    expect_bytes(text, "uint:5 ", "uint64 5 value");

    // Every integer width, signed and unsigned, inside one array.
    text, error = image("\x94\xcc\xff\xcd\xff\xff\xce\xff\xff\xff\xff\xcf\xff\xff\xff\xff\xff\xff\xff\xff");
    expect_error(error, msgpack::Error.None, "unsigned widths");
    expect_bytes(text, "array:4 uint:255 uint:65535 uint:4294967295 uint:18446744073709551615 ", "unsigned widths");
    text, error = image("\x94\xd0\x80\xd1\x80\x00\xd2\x80\x00\x00\x00\xd3\x80\x00\x00\x00\x00\x00\x00\x00");
    expect_error(error, msgpack::Error.None, "signed widths");
    expect_bytes(text, "array:4 int:-128 int:-32768 int:-2147483648 int:-9223372036854775808 ", "signed widths");

    // Floats keep their bits, including negative zero.
    text, error = image("\x92\xca\x3f\xc0\x00\x00\xcb\x80\x00\x00\x00\x00\x00\x00\x00");
    expect_error(error, msgpack::Error.None, "floats");
    expect_bytes(text, "array:2 f32:1.5 f64:-0.0 ", "float values");

    // Ext: fixed and variable forms.
    text, error = image("\x92\xd4\x01\x7f\xc7\x03\x05\x01\x02\x03");
    expect_error(error, msgpack::Error.None, "ext forms");
    expect_bytes(text, "array:2 ext:1:1 ext:5:3 ", "ext values");

    // Empty containers complete the top-level value immediately.
    text, error = image("\x90");
    expect_error(error, msgpack::Error.None, "empty array");
    expect_bytes(text, "array:0 ", "empty array token");
    text, error = image("\x80");
    expect_error(error, msgpack::Error.None, "empty map");
    expect_bytes(text, "map:0 ", "empty map token");
}

fn contract_cases() {
    var reader = msgpack::Reader { .. };
    // Empty input: nothing to read, and finish reports the misuse.
    expect_error(msgpack::init(reader, ""), msgpack::Error.None, "init empty");
    var token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.Truncated, "next on empty input");
    expect_error(msgpack::init(reader, ""), msgpack::Error.None, "re-init empty");
    expect_error(msgpack::finish(reader), msgpack::Error.InvalidState, "finish before any token");

    // Trailing bytes are a full-input failure, not a silent success.
    expect_error(msgpack::init(reader, "\x01\x02"), msgpack::Error.None, "init trailing");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "first of two");
    expect(msgpack::done(reader), "done after one value");
    // A second next is a misuse, not a second value.
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.InvalidState, "next after done");
    expect_error(msgpack::init(reader, "\x01\x02"), msgpack::Error.None, "re-init trailing");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "first of two again");
    expect_error(msgpack::finish(reader), msgpack::Error.TrailingBytes, "trailing byte");
    expect(msgpack::consumed(reader) == 1, "trailing byte not consumed");

    // Truncation at every prefix of a nested value.
    let full = "\x92\xa1a\x92\x01\x02";
    for cut in full.len {
        expect_error(msgpack::init(reader, full[..cut]), msgpack::Error.None, "init prefix");
        var step = msgpack::Error.None;
        while !msgpack::done(reader) && step == msgpack::Error.None {
            let t, e = msgpack::next(reader);
            step = e;
        }
        if step == msgpack::Error.None { step = msgpack::finish(reader); }
        expect_error(step, msgpack::Error.Truncated, "truncated prefix");
    }

    // 0xc1 is reserved and never a value.
    expect_error(msgpack::init(reader, "\xc1"), msgpack::Error.None, "init reserved");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.Reserved, "reserved marker");
    expect(msgpack::offset(reader) == 0, "reserved offset");

    // A declared length above the container budget is rejected first; a length
    // the remaining input cannot hold is rejected before the caller loops.
    expect_error(msgpack::init(reader, "\xdd\xff\xff\xff\xff"), msgpack::Error.None, "init huge array");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.ContainerLimit, "array count above the budget");
    expect_error(msgpack::init(reader, "\xdc\x00\x10\x01"), msgpack::Error.None, "init short array");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.Truncated, "array count exceeds the input");
    expect_error(msgpack::init(reader, "\xdf\x00\x00\x00\x02\x01"), msgpack::Error.None, "init short map");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.Truncated, "map count exceeds input");

    // skip consumes one whole value, including a nested last child.
    expect_error(msgpack::init(reader, "\x92\x01\x92\x02\x03"), msgpack::Error.None, "init skip");
    expect_error(msgpack::skip(reader), msgpack::Error.None, "skip nested");
    expect(msgpack::consumed(reader) == 5, "skip consumed the whole value");
    expect(msgpack::done(reader), "skip completed the top-level value");
    expect_error(msgpack::finish(reader), msgpack::Error.None, "skip leaves no trailing byte");
    // A skipped value followed by another value leaves the second one.
    expect_error(msgpack::init(reader, "\x92\x01\x92\x02\x03\x04"), msgpack::Error.None, "init skip then read");
    expect_error(msgpack::skip(reader), msgpack::Error.None, "skip first value");
    expect_error(msgpack::finish(reader), msgpack::Error.TrailingBytes, "second value is trailing");
}

fn utf8_cases() {
    var writer = msgpack::Writer { .. };
    // Valid: ASCII, two-, three- and four-byte sequences, and the boundaries.
    expect_error(msgpack::init(writer), msgpack::Error.None, "init utf8");
    expect_error(msgpack::array(writer, 9), msgpack::Error.None, "utf8 values in one root array");
    expect_error(msgpack::str(writer, "\x7f"), msgpack::Error.None, "ascii");
    expect_error(msgpack::str(writer, "\xc2\x80"), msgpack::Error.None, "U+0080");
    expect_error(msgpack::str(writer, "\xdf\xbf"), msgpack::Error.None, "U+07FF");
    expect_error(msgpack::str(writer, "\xe0\xa0\x80"), msgpack::Error.None, "U+0800");
    expect_error(msgpack::str(writer, "\xed\x9f\xbf"), msgpack::Error.None, "U+D7FF");
    expect_error(msgpack::str(writer, "\xee\x80\x80"), msgpack::Error.None, "U+E000");
    expect_error(msgpack::str(writer, "\xef\xbf\xbf"), msgpack::Error.None, "U+FFFF");
    expect_error(msgpack::str(writer, "\xf0\x90\x80\x80"), msgpack::Error.None, "U+10000");
    expect_error(msgpack::str(writer, "\xf4\x8f\xbf\xbf"), msgpack::Error.None, "U+10FFFF");
    expect_error(msgpack::finish(writer), msgpack::Error.None, "utf8 array complete");

    // Invalid: overlong, surrogate, above U+10FFFF, bare continuation, truncated.
    let invalid: (const u8[:])[10] = ["\x80", "\xc0\x80", "\xc1\xbf", "\xe0\x80\x80",
        "\xed\xa0\x80", "\xf0\x80\x80\x80", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80",
        "\xc2", "\xe1\x80"];
    for i in invalid.len {
        expect_error(msgpack::init(writer), msgpack::Error.None, "init invalid utf8");
        expect_error(msgpack::str(writer, invalid[i]), msgpack::Error.InvalidUtf8, "invalid utf8 rejected");
    }

    // The reader applies the same policy to a str marker.
    var reader = msgpack::Reader { .. };
    expect_error(msgpack::init(reader, "\xa2\xc3\xa9"), msgpack::Error.None, "init valid str");
    var token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "valid str token");
    expect_bytes(msgpack::text(token), "\xc3\xa9", "valid str payload");
    expect_error(msgpack::init(reader, "\xa2\xed\xa0"), msgpack::Error.None, "init surrogate str");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.InvalidUtf8, "surrogate str rejected");
    // bin is the opaque path: the same bytes are accepted.
    expect_error(msgpack::init(reader, "\xc4\x02\xed\xa0"), msgpack::Error.None, "init opaque bin");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "opaque bin accepted");
    expect_bytes(msgpack::bytes(token), "\xed\xa0", "opaque bin payload");
}

// The strict policy, stated as regressions: overlong forms, surrogates,
// truncated sequences and out-of-range leads are rejected; non-characters that
// are well-formed UTF-8 are accepted, because UTF-8 validity is not a
// character-property check.
fn utf8_regressions() {
    var writer = msgpack::Writer { .. };
    var reader = msgpack::Reader { .. };
    // Well-formed non-characters: U+FDD0, U+FFFE, U+FFFF, U+1FFFE, U+10FFFF.
    let noncharacters: (const u8[:])[5] = ["\xef\xb7\x90", "\xef\xbf\xbe", "\xef\xbf\xbf",
        "\xf0\x9f\xbf\xbe", "\xf4\x8f\xbf\xbf"];
    for i in noncharacters.len {
        expect_error(msgpack::init(writer), msgpack::Error.None, "init noncharacter");
        expect_error(msgpack::str(writer, noncharacters[i]), msgpack::Error.None, "noncharacter accepted");
    }
    // Overlong forms at every width, both the shortest and a longer encoding.
    let overlong: (const u8[:])[6] = ["\xc0\xaf", "\xc1\xbf", "\xe0\x80\xaf",
        "\xe0\x9f\xbf", "\xf0\x80\x80\xaf", "\xf0\x8f\xbf\xbf"];
    for i in overlong.len {
        expect_error(msgpack::init(writer), msgpack::Error.None, "init overlong");
        expect_error(msgpack::str(writer, overlong[i]), msgpack::Error.InvalidUtf8, "overlong rejected");
    }
    // Surrogates: the first and last code point of the range.
    let surrogates: (const u8[:])[2] = ["\xed\xa0\x80", "\xed\xbf\xbf"];
    for i in surrogates.len {
        expect_error(msgpack::init(writer), msgpack::Error.None, "init surrogate");
        expect_error(msgpack::str(writer, surrogates[i]), msgpack::Error.InvalidUtf8, "surrogate rejected");
    }
    // Truncated sequences, including a bare lead byte.
    let truncated: (const u8[:])[5] = ["\xc2", "\xe1\x80", "\xf0", "\xf0\x90\x80", "\xf4\x8f\xbf"];
    for i in truncated.len {
        expect_error(msgpack::init(writer), msgpack::Error.None, "init truncated");
        expect_error(msgpack::str(writer, truncated[i]), msgpack::Error.InvalidUtf8, "truncated rejected");
    }
    // The reader applies the same policy to fixstr and to str8/16/32.
    expect_error(msgpack::init(reader, "\xa1\xff"), msgpack::Error.None, "init fixstr invalid");
    var token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.InvalidUtf8, "fixstr invalid rejected");
    expect_error(msgpack::init(reader, "\xd9\x01\xff"), msgpack::Error.None, "init str8 invalid");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.InvalidUtf8, "str8 invalid rejected");
    expect_error(msgpack::init(reader, "\xda\x00\x01\xff"), msgpack::Error.None, "init str16 invalid");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.InvalidUtf8, "str16 invalid rejected");
    expect_error(msgpack::init(reader, "\xdb\x00\x00\x00\x01\xff"), msgpack::Error.None, "init str32 invalid");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.InvalidUtf8, "str32 invalid rejected");
    // A well-formed non-character survives the reader too.
    expect_error(msgpack::init(reader, "\xa3\xef\xbf\xbe"), msgpack::Error.None, "init noncharacter str");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "noncharacter str accepted");
    expect_bytes(msgpack::text(token), "\xef\xbf\xbe", "noncharacter payload");
    // The same bytes as bin are opaque and accepted.
    expect_error(msgpack::init(reader, "\xc4\x01\xff"), msgpack::Error.None, "init opaque bin");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "opaque bin accepted");
}

fn budget_cases() {
    var reader = msgpack::Reader { .. };
    var writer = msgpack::Writer { .. };
    // Input budget: the limit is inclusive, and one byte less fails at init.
    var limits = msgpack::Limits { .. };
    limits.max_input_bytes = 2;
    expect_error(msgpack::init(reader, "\x01\x02", limits), msgpack::Error.None, "input at limit");
    limits.max_input_bytes = 1;
    expect_error(msgpack::init(reader, "\x01\x02", limits), msgpack::Error.InputLimit, "input over limit");

    // Output budget: checked before the byte is appended.
    limits = msgpack::Limits { .. };
    limits.max_output_bytes = 1;
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "output at limit");
    expect_error(msgpack::nil(writer), msgpack::Error.None, "nil fits");
    expect(msgpack::written(writer) == 1, "root at exact output limit");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "reset output budget");
    expect_error(msgpack::array(writer, 1), msgpack::Error.None, "array header at output limit");
    expect_error(msgpack::nil(writer), msgpack::Error.OutputLimit, "child over output limit");
    expect(msgpack::written(writer) == 1, "no byte written past the budget");

    // Node budget counts tokens, not bytes.
    limits = msgpack::Limits { .. };
    limits.max_nodes = 2;
    expect_error(msgpack::init(reader, "\x92\x01\x02", limits), msgpack::Error.None, "nodes at limit");
    var step = msgpack::Error.None;
    var tokens: i64 = 0;
    while !msgpack::done(reader) && step == msgpack::Error.None {
        let t, e = msgpack::next(reader);
        step = e;
        if e == msgpack::Error.None { tokens++; }
    }
    expect_error(step, msgpack::Error.NodeLimit, "third token over the node budget");
    expect(tokens == 2, "two tokens fit two nodes");

    // Depth: a chain of `max_depth` arrays is accepted, one more is not.
    limits = msgpack::Limits { .. };
    limits.max_depth = 3;
    expect_error(msgpack::init(reader, "\x91\x91\x91\x01", limits), msgpack::Error.None, "depth at limit");
    step = msgpack::Error.None;
    while !msgpack::done(reader) && step == msgpack::Error.None {
        let t, e = msgpack::next(reader);
        step = e;
    }
    expect_error(step, msgpack::Error.None, "depth at limit accepted");
    expect_error(msgpack::init(reader, "\x91\x91\x91\x91\x01", limits), msgpack::Error.None, "depth over limit");
    step = msgpack::Error.None;
    while !msgpack::done(reader) && step == msgpack::Error.None {
        let t, e = msgpack::next(reader);
        step = e;
    }
    expect_error(step, msgpack::Error.DepthLimit, "depth over limit rejected");

    // The writer enforces the same depth.
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer depth init");
    expect_error(msgpack::array(writer, 1), msgpack::Error.None, "depth 1");
    expect_error(msgpack::array(writer, 1), msgpack::Error.None, "depth 2");
    expect_error(msgpack::array(writer, 1), msgpack::Error.None, "depth 3");
    expect_error(msgpack::array(writer, 1), msgpack::Error.DepthLimit, "depth 4 rejected");

    // String and binary budgets.
    limits = msgpack::Limits { .. };
    limits.max_str_bytes = 2;
    limits.max_bin_bytes = 2;
    expect_error(msgpack::init(reader, "\xa2ab", limits), msgpack::Error.None, "str at limit");
    var token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "str at limit accepted");
    expect_error(msgpack::init(reader, "\xa3abc", limits), msgpack::Error.None, "str over limit");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.StrLimit, "str over limit rejected");
    expect_error(msgpack::init(reader, "\xc4\x03abc", limits), msgpack::Error.None, "bin over limit");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.BinLimit, "bin over limit rejected");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer str limit");
    expect_error(msgpack::str(writer, "abc"), msgpack::Error.StrLimit, "writer str over limit");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer bin limit");
    expect_error(msgpack::bin(writer, "abc"), msgpack::Error.BinLimit, "writer bin over limit");

    // Container length budget.
    limits = msgpack::Limits { .. };
    limits.max_container_len = 2;
    expect_error(msgpack::init(reader, "\x93\x01\x02\x03", limits), msgpack::Error.None, "array over container limit");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.ContainerLimit, "array count over limit rejected");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer container limit");
    expect_error(msgpack::array(writer, 3), msgpack::Error.ContainerLimit, "writer array over limit");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer map limit");
    expect_error(msgpack::map(writer, 3), msgpack::Error.ContainerLimit, "writer map over limit");

    // Invalid options are rejected before any state changes.
    limits = msgpack::Limits { .. };
    limits.max_depth = msgpack::MAX_DEPTH + 1;
    expect_error(msgpack::init(reader, "", limits), msgpack::Error.InvalidOptions, "depth above hard maximum");
    expect_error(msgpack::init(writer, limits), msgpack::Error.InvalidOptions, "writer depth above hard maximum");
    limits = msgpack::Limits { .. };
    limits.max_nodes = -1;
    expect_error(msgpack::init(reader, "", limits), msgpack::Error.InvalidOptions, "negative node budget");
    // Zero is a valid budget.
    limits = msgpack::Limits { .. };
    limits.max_input_bytes = 0;
    limits.max_output_bytes = 0;
    limits.max_nodes = 0;
    limits.max_depth = 0;
    limits.max_str_bytes = 0;
    limits.max_bin_bytes = 0;
    limits.max_container_len = 0;
    expect_error(msgpack::init(reader, "", limits), msgpack::Error.None, "zero budgets accepted");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "zero writer budgets accepted");
    expect_error(msgpack::nil(writer), msgpack::Error.NodeLimit, "zero node budget rejects a value");
}

fn writer_state_cases() {
    var writer = msgpack::Writer { .. };
    // An unclosed container is not a finished value.
    expect_error(msgpack::init(writer), msgpack::Error.None, "init unbalanced");
    expect_error(msgpack::array(writer, 2), msgpack::Error.None, "open array");
    expect_error(msgpack::uint(writer, 1), msgpack::Error.None, "one element");
    expect_error(msgpack::finish(writer), msgpack::Error.Unbalanced, "unbalanced finish");
    expect_error(msgpack::uint(writer, 2), msgpack::Error.None, "second element");
    expect_error(msgpack::finish(writer), msgpack::Error.None, "balanced finish");
    expect_bytes(msgpack::output(writer), "\x92\x01\x02", "balanced output");

    // A failed write is sticky until re-init.
    var shallow = msgpack::Limits { .. };
    shallow.max_depth = 3;
    expect_error(msgpack::init(writer, shallow), msgpack::Error.None, "re-init shallow");
    expect_error(msgpack::array(writer, 1), msgpack::Error.None, "open for failure");
    expect_error(msgpack::array(writer, 1), msgpack::Error.None, "nested");
    expect_error(msgpack::array(writer, 1), msgpack::Error.None, "nested again");
    expect_error(msgpack::array(writer, 1), msgpack::Error.DepthLimit, "depth failure");
    expect_error(msgpack::nil(writer), msgpack::Error.DepthLimit, "sticky failure");
    expect_error(msgpack::finish(writer), msgpack::Error.DepthLimit, "sticky finish");
    expect_error(msgpack::init(writer), msgpack::Error.None, "re-init clears the failure");
    expect_error(msgpack::nil(writer), msgpack::Error.None, "usable after re-init");

    // A writer that was never initialized refuses to write.
    var fresh = msgpack::Writer { .. };
    expect_error(msgpack::nil(fresh), msgpack::Error.InvalidState, "uninitialized writer");
    expect_error(msgpack::finish(fresh), msgpack::Error.InvalidState, "uninitialized finish");
}

fn writer_stream_cases() {
    var writer = msgpack::Writer { .. };
    var reader = msgpack::Reader { .. };
    expect_error(msgpack::init(writer), msgpack::Error.None, "stream writer init");
    expect_error(msgpack::finish(writer), msgpack::Error.None, "empty stream has no open frames");
    expect_error(msgpack::init(reader, msgpack::output(writer)), msgpack::Error.None, "empty output reader init");
    expect_error(msgpack::finish(reader), msgpack::Error.InvalidState, "empty stream is not one document");
    expect_error(msgpack::nil(writer), msgpack::Error.None, "first stream value");
    expect_error(msgpack::finish(writer), msgpack::Error.None, "one stream value complete");
    expect_error(msgpack::nil(writer), msgpack::Error.None, "second stream value permitted");
    expect_bytes(msgpack::output(writer), "\xc0\xc0", "two stream values");
    expect_error(msgpack::init(reader, msgpack::output(writer)), msgpack::Error.None, "concatenated output reader init");
    expect_error(msgpack::skip(reader), msgpack::Error.None, "read first stream value");
    expect_error(msgpack::finish(reader), msgpack::Error.TrailingBytes, "stream requires explicit framing");
    var limits = msgpack::Limits { max_output_bytes: 1 };
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "stream budget reset");
    expect_error(msgpack::nil(writer), msgpack::Error.None, "stream at exact output limit");
    expect_error(msgpack::nil(writer), msgpack::Error.OutputLimit, "budget spans all stream values");
    expect_bytes(msgpack::output(writer), "\xc0", "failed second value leaves output unchanged");
}

fn accessor_cases() {
    var reader = msgpack::Reader { .. };
    expect_error(msgpack::init(reader, "\x99\x01\xcc\xff\xd0\x80\xcb\x3f\xf8\x00\x00\x00\x00\x00\x00\xc3\xa1a\xc4\x01\x00\xd4\x07\x09\x92\x01\x02"), msgpack::Error.None, "init accessors");
    var token, error = msgpack::next(reader);
    expect(msgpack::count(token) == 9, "accessor array count");
    token, error = msgpack::next(reader);
    let as_int, int_ok = msgpack::as_i64(token);
    expect(int_ok && as_int == 1, "as_i64 on a positive fixint");
    token, error = msgpack::next(reader);
    let as_uint, uint_ok = msgpack::as_u64(token);
    expect(uint_ok && as_uint == 255, "as_u64 on uint8");
    token, error = msgpack::next(reader);
    let negative, negative_ok = msgpack::as_i64(token);
    expect(negative_ok && negative == -128, "as_i64 on int8");
    let unsigned, unsigned_ok = msgpack::as_u64(token);
    expect(!unsigned_ok, "as_u64 rejects a negative");
    token, error = msgpack::next(reader);
    let as_float, float_ok = msgpack::as_f64(token);
    expect(float_ok && as_float == 1.5, "as_f64 on float64");
    token, error = msgpack::next(reader);
    let as_bool, bool_ok = msgpack::as_bool(token);
    expect(bool_ok && as_bool, "as_bool on true");
    token, error = msgpack::next(reader);
    expect_bytes(msgpack::text(token), "a", "text on str");
    token, error = msgpack::next(reader);
    expect_bytes(msgpack::bytes(token), "\x00", "bytes on bin");
    token, error = msgpack::next(reader);
    expect(msgpack::ext_type(token) == 7, "ext_type");
    expect_bytes(msgpack::bytes(token), "\x09", "bytes on ext");
    token, error = msgpack::next(reader);
    expect(msgpack::count(token) == 2, "count on array");
    // The outer array is still open: its last element is this array.
    expect(msgpack::depth(reader) == 2, "depth inside the nested array");
    expect(msgpack::remaining(reader) == 2, "remaining inside the array");
    token, error = msgpack::next(reader);
    expect(msgpack::remaining(reader) == 1, "remaining after one element");
    token, error = msgpack::next(reader);
    expect(msgpack::remaining(reader) == -1, "remaining at the top level");
    expect_error(msgpack::finish(reader), msgpack::Error.None, "accessor stream finished");
    // A mismatched accessor reports false rather than a wrong value.
    expect_error(msgpack::init(reader, "\xc3"), msgpack::Error.None, "init bool");
    let bool_token, bool_error = msgpack::next(reader);
    expect_error(bool_error, msgpack::Error.None, "bool token");
    let wrong, wrong_ok = msgpack::as_i64(bool_token);
    expect(!wrong_ok && wrong == 0, "as_i64 rejects a non-integer");
    let wrong_float, wrong_float_ok = msgpack::as_f64(bool_token);
    expect(!wrong_float_ok && wrong_float == 0.0, "as_f64 rejects a non-float");
}

fn main() {
    writer_cases();
    reader_cases();
    contract_cases();
    utf8_cases();
    utf8_regressions();
    budget_cases();
    writer_state_cases();
    writer_stream_cases();
    accessor_cases();
    marker_cases();
    integer_accessor_cases();
    float_cases();
    exact_limit_cases();
    skip_budget_cases();
    state_preservation_cases();
    ownership_cases();
    writer_large_form_cases();
    depth_empty_child_cases();
    output_budget_exact_cases();
    map_frame_cases();
    if failures > 0 {
        write_stderr(str(failures, " of ", checks, " checks failed\n"));
        exit(1);
    }
    print("msgpack api ok: ", checks, " checks");
}

// ---- hardening: every marker family at its boundary ---------------------
// The oracle covers these too, but a contract test that names the marker is
// what makes a regression readable. Each case decodes one wire value and
// compares the token image.
fn marker_cases() {
    var text, error = image("\xcd\x01\x00");
    expect_error(error, msgpack::Error.None, "uint16");
    expect_bytes(text, "uint:256 ", "uint16 value");
    text, error = image("\xce\x00\x01\x00\x00");
    expect_error(error, msgpack::Error.None, "uint32");
    expect_bytes(text, "uint:65536 ", "uint32 value");
    text, error = image("\xcf\xff\xff\xff\xff\xff\xff\xff\xff");
    expect_error(error, msgpack::Error.None, "uint64");
    expect_bytes(text, "uint:18446744073709551615 ", "uint64 value");
    text, error = image("\xd2\xff\xff\xff\xff");
    expect_error(error, msgpack::Error.None, "int32");
    expect_bytes(text, "int:-1 ", "int32 value");
    text, error = image("\xd3\x80\x00\x00\x00\x00\x00\x00\x00");
    expect_error(error, msgpack::Error.None, "int64");
    expect_bytes(text, "int:-9223372036854775808 ", "int64 value");
    text, error = image("\xca\x3f\xc0\x00\x00");
    expect_error(error, msgpack::Error.None, "float32");
    expect_bytes(text, "f32:1.5 ", "float32 value");
    text, error = image("\xda\x00\x02ab");
    expect_error(error, msgpack::Error.None, "str16");
    expect_bytes(text, "str:2 ", "str16 value");
    text, error = image("\xdb\x00\x00\x00\x02ab");
    expect_error(error, msgpack::Error.None, "str32");
    expect_bytes(text, "str:2 ", "str32 value");
    text, error = image("\xc5\x00\x02\x00\xff");
    expect_error(error, msgpack::Error.None, "bin16");
    expect_bytes(text, "bin:2 ", "bin16 value");
    text, error = image("\xc6\x00\x00\x00\x02\x00\xff");
    expect_error(error, msgpack::Error.None, "bin32");
    expect_bytes(text, "bin:2 ", "bin32 value");
    text, error = image("\xd6\x01\x01\x02\x03\x04");
    expect_error(error, msgpack::Error.None, "fixext4");
    expect_bytes(text, "ext:1:4 ", "fixext4 value");
    text, error = image("\xd7\x01\x01\x02\x03\x04\x05\x06\x07\x08");
    expect_error(error, msgpack::Error.None, "fixext8");
    expect_bytes(text, "ext:1:8 ", "fixext8 value");
    text, error = image("\xd8\x01\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f");
    expect_error(error, msgpack::Error.None, "fixext16");
    expect_bytes(text, "ext:1:16 ", "fixext16 value");
    text, error = image("\xc8\x00\x03\x05\x01\x02\x03");
    expect_error(error, msgpack::Error.None, "ext16");
    expect_bytes(text, "ext:5:3 ", "ext16 value");
    text, error = image("\xc9\x00\x00\x00\x03\x05\x01\x02\x03");
    expect_error(error, msgpack::Error.None, "ext32");
    expect_bytes(text, "ext:5:3 ", "ext32 value");
    text, error = image("\xdc\x00\x02\x01\x02");
    expect_error(error, msgpack::Error.None, "array16");
    expect_bytes(text, "array:2 uint:1 uint:2 ", "array16 value");
    text, error = image("\xdd\x00\x00\x00\x02\x01\x02");
    expect_error(error, msgpack::Error.None, "array32");
    expect_bytes(text, "array:2 uint:1 uint:2 ", "array32 value");
    text, error = image("\xde\x00\x01\xa1a\x01");
    expect_error(error, msgpack::Error.None, "map16");
    expect_bytes(text, "map:1 str:1 uint:1 ", "map16 value");
    text, error = image("\xdf\x00\x00\x00\x01\xa1a\x01");
    expect_error(error, msgpack::Error.None, "map32");
    expect_bytes(text, "map:1 str:1 uint:1 ", "map32 value");
    // The ext type byte is signed: both ends of i8 survive.
    text, error = image("\xd4\x80\x00");
    expect_error(error, msgpack::Error.None, "ext type -128");
    expect_bytes(text, "ext:-128:1 ", "ext type -128 value");
    text, error = image("\xd4\x7f\x00");
    expect_error(error, msgpack::Error.None, "ext type 127");
    expect_bytes(text, "ext:127:1 ", "ext type 127 value");
}

// ---- hardening: integer accessors at the i64/u64 boundary ---------------
fn integer_accessor_cases() {
    var reader = msgpack::Reader { .. };
    // u64 max is a Uint that does not fit i64.
    expect_error(msgpack::init(reader, "\xcf\xff\xff\xff\xff\xff\xff\xff\xff"), msgpack::Error.None, "init u64 max");
    var token, error = msgpack::next(reader);
    let as_int, int_ok = msgpack::as_i64(token);
    let as_uint, uint_ok = msgpack::as_u64(token);
    expect(!int_ok && as_int == 0, "as_i64 rejects u64 max");
    expect(uint_ok && as_uint == 18446744073709551615, "as_u64 accepts u64 max");
    // i64 min is an Int that is not a u64.
    expect_error(msgpack::init(reader, "\xd3\x80\x00\x00\x00\x00\x00\x00\x00"), msgpack::Error.None, "init i64 min");
    token, error = msgpack::next(reader);
    let min_int, min_ok = msgpack::as_i64(token);
    let min_uint, min_uint_ok = msgpack::as_u64(token);
    expect(min_ok && min_int == -9223372036854775807 - 1, "as_i64 accepts i64 min");
    expect(!min_uint_ok && min_uint == 0, "as_u64 rejects i64 min");
    // A positive fixint is Uint on the wire but reads as both.
    expect_error(msgpack::init(reader, "\x05"), msgpack::Error.None, "init fixint");
    token, error = msgpack::next(reader);
    let five_int, five_int_ok = msgpack::as_i64(token);
    let five_uint, five_uint_ok = msgpack::as_u64(token);
    expect(five_int_ok && five_int == 5, "as_i64 on a positive fixint");
    expect(five_uint_ok && five_uint == 5, "as_u64 on a positive fixint");
    // A negative fixint is Int and is not a u64.
    expect_error(msgpack::init(reader, "\xff"), msgpack::Error.None, "init negative fixint");
    token, error = msgpack::next(reader);
    let neg_int, neg_ok = msgpack::as_i64(token);
    let neg_uint, neg_uint_ok = msgpack::as_u64(token);
    expect(neg_ok && neg_int == -1, "as_i64 on a negative fixint");
    expect(!neg_uint_ok, "as_u64 rejects a negative fixint");
    // count on a token that has none is -1, not 0.
    expect_error(msgpack::init(reader, "\xc0"), msgpack::Error.None, "init nil for count");
    token, error = msgpack::next(reader);
    expect(msgpack::count(token) == -1, "count of a non-container is -1");
}

// ---- hardening: floats, including the values that break naive equality ---
fn float_cases() {
    var reader = msgpack::Reader { .. };
    var writer = msgpack::Writer { .. };
    // NaN: the only value that is not equal to itself.
    expect_error(msgpack::init(reader, "\xcb\x7f\xf8\x00\x00\x00\x00\x00\x00"), msgpack::Error.None, "init f64 nan");
    var token, error = msgpack::next(reader);
    let nan, nan_ok = msgpack::as_f64(token);
    expect(nan_ok && nan != nan, "as_f64 returns NaN");
    // +inf and -inf.
    expect_error(msgpack::init(reader, "\xcb\x7f\xf0\x00\x00\x00\x00\x00\x00"), msgpack::Error.None, "init f64 +inf");
    token, error = msgpack::next(reader);
    let plus, plus_ok = msgpack::as_f64(token);
    expect(plus_ok && plus > 1.0e308, "as_f64 returns +inf");
    expect_error(msgpack::init(reader, "\xcb\xff\xf0\x00\x00\x00\x00\x00\x00"), msgpack::Error.None, "init f64 -inf");
    token, error = msgpack::next(reader);
    let minus, minus_ok = msgpack::as_f64(token);
    expect(minus_ok && minus < -1.0e308, "as_f64 returns -inf");
    // -0.0 is zero but keeps its sign bit through a decode/encode round trip.
    expect_error(msgpack::init(reader, "\xcb\x80\x00\x00\x00\x00\x00\x00\x00"), msgpack::Error.None, "init f64 -0");
    token, error = msgpack::next(reader);
    let zero, zero_ok = msgpack::as_f64(token);
    expect(zero_ok && zero == 0.0, "as_f64 returns -0 as zero");
    expect_error(msgpack::init(writer), msgpack::Error.None, "init -0 writer");
    expect_error(msgpack::float64(writer, zero), msgpack::Error.None, "re-encode -0");
    expect_bytes(msgpack::output(writer), "\xcb\x80\x00\x00\x00\x00\x00\x00\x00", "-0 keeps its sign bit");
    // NaN keeps its payload through the same round trip.
    expect_error(msgpack::init(reader, "\xcb\x7f\xf8\x00\x00\x00\x00\x00\x00"), msgpack::Error.None, "init nan round trip");
    token, error = msgpack::next(reader);
    let again, again_ok = msgpack::as_f64(token);
    expect_error(msgpack::init(writer), msgpack::Error.None, "init nan writer");
    expect_error(msgpack::float64(writer, again), msgpack::Error.None, "re-encode nan");
    expect_bytes(msgpack::output(writer), "\xcb\x7f\xf8\x00\x00\x00\x00\x00\x00", "nan keeps its payload");
    // f32 is not widened on the wire: four bytes, and as_f64 widens on read.
    expect_error(msgpack::init(writer), msgpack::Error.None, "init f32 writer");
    expect_error(msgpack::float32(writer, 1.5), msgpack::Error.None, "write f32");
    expect(msgpack::written(writer) == 5, "f32 is five bytes");
    expect_bytes(msgpack::output(writer), "\xca\x3f\xc0\x00\x00", "f32 bytes");
}

// ---- hardening: every budget at exactly N and N+1 ----------------------
// A budget that is off by one in either direction is the defect this catches.
fn exact_limit_cases() {
    var reader = msgpack::Reader { .. };
    var writer = msgpack::Writer { .. };
    var limits = msgpack::Limits { .. };
    var token, error = msgpack::next(reader);

    // max_bin_bytes: N accepted, N+1 rejected, on read and on write.
    limits = msgpack::Limits { .. };
    limits.max_bin_bytes = 2;
    expect_error(msgpack::init(reader, "\xc4\x02ab", limits), msgpack::Error.None, "bin at limit init");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "bin at limit accepted");
    expect(msgpack::bytes(token).len == 2, "bin at limit payload");
    expect_error(msgpack::init(reader, "\xc4\x03abc", limits), msgpack::Error.None, "bin over limit init");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.BinLimit, "bin over limit rejected");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer bin at limit");
    expect_error(msgpack::bin(writer, "ab"), msgpack::Error.None, "writer bin at limit accepted");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer bin over limit");
    expect_error(msgpack::bin(writer, "abc"), msgpack::Error.BinLimit, "writer bin over limit rejected");
    // ext shares max_bin_bytes.
    expect_error(msgpack::init(reader, "\xd5\x01ab", limits), msgpack::Error.None, "ext at limit init");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "ext at limit accepted");
    expect_error(msgpack::init(reader, "\xc7\x03\x01abc", limits), msgpack::Error.None, "ext over limit init");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.BinLimit, "ext over limit rejected");

    // max_container_len: N accepted, N+1 rejected, for arrays and maps.
    limits = msgpack::Limits { .. };
    limits.max_container_len = 2;
    expect_error(msgpack::init(reader, "\x92\x01\x02", limits), msgpack::Error.None, "array at limit init");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "array at limit accepted");
    expect(msgpack::count(token) == 2, "array at limit count");
    expect_error(msgpack::init(reader, "\x93\x01\x02\x03", limits), msgpack::Error.None, "array over limit init");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.ContainerLimit, "array over limit rejected");
    expect_error(msgpack::init(reader, "\x82\xa1a\x01\xa1b\x02", limits), msgpack::Error.None, "map at limit init");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "map at limit accepted");
    expect(msgpack::count(token) == 2, "map at limit count");
    expect_error(msgpack::init(reader, "\x83\xa1a\x01\xa1b\x02\xa1c\x03", limits), msgpack::Error.None, "map over limit init");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.ContainerLimit, "map over limit rejected");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer array at limit");
    expect_error(msgpack::array(writer, 2), msgpack::Error.None, "writer array at limit accepted");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer map at limit");
    expect_error(msgpack::map(writer, 2), msgpack::Error.None, "writer map at limit accepted");

    // max_nodes on the writer: N values accepted, N+1 rejected.
    limits = msgpack::Limits { .. };
    limits.max_nodes = 2;
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer nodes at limit");
    expect_error(msgpack::nil(writer), msgpack::Error.None, "writer node 1");
    expect_error(msgpack::nil(writer), msgpack::Error.None, "writer node 2");
    expect_error(msgpack::nil(writer), msgpack::Error.NodeLimit, "writer node 3 rejected");
    expect(msgpack::written(writer) == 2, "writer node limit wrote two values");

    // max_output_bytes: a multi-byte value that fits exactly, then one less.
    limits = msgpack::Limits { .. };
    limits.max_output_bytes = 4;
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "output exact init");
    expect_error(msgpack::str(writer, "abc"), msgpack::Error.None, "str of 3 fits 4 bytes");
    expect(msgpack::written(writer) == 4, "str of 3 is 4 bytes");
    limits.max_output_bytes = 3;
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "output short init");
    expect_error(msgpack::str(writer, "abc"), msgpack::Error.OutputLimit, "str of 3 needs 4 bytes");
    expect(msgpack::written(writer) == 0, "rejected write appended nothing");

    // max_str_bytes on the writer: N accepted, N+1 rejected.
    limits = msgpack::Limits { .. };
    limits.max_str_bytes = 3;
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer str at limit");
    expect_error(msgpack::str(writer, "abc"), msgpack::Error.None, "writer str at limit accepted");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer str over limit");
    expect_error(msgpack::str(writer, "abcd"), msgpack::Error.StrLimit, "writer str over limit rejected");

    // max_depth on the writer: N accepted, N+1 rejected.
    limits = msgpack::Limits { .. };
    limits.max_depth = 2;
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "writer depth at limit");
    expect_error(msgpack::array(writer, 1), msgpack::Error.None, "writer depth 1");
    expect_error(msgpack::array(writer, 1), msgpack::Error.None, "writer depth 2");
    expect_error(msgpack::array(writer, 1), msgpack::Error.DepthLimit, "writer depth 3 rejected");

    // max_input_bytes: N accepted, N+1 rejected.
    limits = msgpack::Limits { .. };
    limits.max_input_bytes = 2;
    expect_error(msgpack::init(reader, "\x01\x02", limits), msgpack::Error.None, "input at limit accepted");
    limits.max_input_bytes = 1;
    expect_error(msgpack::init(reader, "\x01\x02", limits), msgpack::Error.InputLimit, "input over limit rejected");
}

// ---- hardening: skip applies the same budgets as next ------------------
fn skip_budget_cases() {
    var reader = msgpack::Reader { .. };
    var limits = msgpack::Limits { .. };
    // A skipped value still costs nodes.
    limits.max_nodes = 1;
    expect_error(msgpack::init(reader, "\x92\x01\x02", limits), msgpack::Error.None, "skip nodes init");
    expect_error(msgpack::skip(reader), msgpack::Error.NodeLimit, "skip honours max_nodes");
    // A skipped value still costs depth.
    limits = msgpack::Limits { .. };
    limits.max_depth = 1;
    expect_error(msgpack::init(reader, "\x91\x91\x01", limits), msgpack::Error.None, "skip depth init");
    expect_error(msgpack::skip(reader), msgpack::Error.DepthLimit, "skip honours max_depth");
    // A skipped value still costs str and bin budget.
    limits = msgpack::Limits { .. };
    limits.max_str_bytes = 1;
    expect_error(msgpack::init(reader, "\x91\xa2ab", limits), msgpack::Error.None, "skip str init");
    expect_error(msgpack::skip(reader), msgpack::Error.StrLimit, "skip honours max_str_bytes");
    limits = msgpack::Limits { .. };
    limits.max_bin_bytes = 1;
    expect_error(msgpack::init(reader, "\x91\xc4\x02ab", limits), msgpack::Error.None, "skip bin init");
    expect_error(msgpack::skip(reader), msgpack::Error.BinLimit, "skip honours max_bin_bytes");
    // A skipped value still costs container budget.
    limits = msgpack::Limits { .. };
    limits.max_container_len = 1;
    expect_error(msgpack::init(reader, "\x91\x92\x01\x02", limits), msgpack::Error.None, "skip container init");
    expect_error(msgpack::skip(reader), msgpack::Error.ContainerLimit, "skip honours max_container_len");
    // A truncated value is reported, not silently skipped.
    expect_error(msgpack::init(reader, "\x92\x01"), msgpack::Error.None, "skip truncated init");
    expect_error(msgpack::skip(reader), msgpack::Error.Truncated, "skip reports truncation");
    // Skipping a scalar at the top level consumes exactly one byte.
    expect_error(msgpack::init(reader, "\x01\x02"), msgpack::Error.None, "skip scalar init");
    expect_error(msgpack::skip(reader), msgpack::Error.None, "skip scalar");
    expect(msgpack::consumed(reader) == 1, "skip scalar consumed one byte");
    expect_error(msgpack::finish(reader), msgpack::Error.TrailingBytes, "skip scalar leaves the second value");
}

// ---- hardening: state is preserved on a rejected init, and finish is pure
fn state_preservation_cases() {
    var reader = msgpack::Reader { .. };
    var writer = msgpack::Writer { .. };
    var bad = msgpack::Limits { .. };
    bad.max_depth = msgpack::MAX_DEPTH + 1;

    // A rejected writer init leaves the previous output and limits in place.
    expect_error(msgpack::init(writer), msgpack::Error.None, "preserve writer init");
    expect_error(msgpack::nil(writer), msgpack::Error.None, "preserve writer value");
    expect_error(msgpack::init(writer, bad), msgpack::Error.InvalidOptions, "preserve writer bad init");
    expect(msgpack::written(writer) == 1, "rejected init kept the output");
    expect_error(msgpack::nil(writer), msgpack::Error.None, "writer still usable after a rejected init");
    expect_bytes(msgpack::output(writer), "\xc0\xc0", "writer appended after a rejected init");

    // A rejected reader init leaves the previous input and cursor in place.
    expect_error(msgpack::init(reader, "\x01"), msgpack::Error.None, "preserve reader init");
    expect_error(msgpack::init(reader, "\x02", bad), msgpack::Error.InvalidOptions, "preserve reader bad init");
    var token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "reader still usable after a rejected init");
    let value, ok = msgpack::as_u64(token);
    expect(ok && value == 1, "rejected init kept the old input");

    // finish is a pure check: it does not poison either side.
    expect_error(msgpack::init(writer), msgpack::Error.None, "pure finish writer init");
    expect_error(msgpack::array(writer, 2), msgpack::Error.None, "pure finish open");
    expect_error(msgpack::finish(writer), msgpack::Error.Unbalanced, "pure finish unbalanced");
    expect_error(msgpack::uint(writer, 1), msgpack::Error.None, "writer continues after unbalanced finish");
    expect_error(msgpack::uint(writer, 2), msgpack::Error.None, "writer closes the frame");
    expect_error(msgpack::finish(writer), msgpack::Error.None, "pure finish balanced");
    expect_error(msgpack::init(reader, "\x01\x02"), msgpack::Error.None, "pure finish reader init");
    token, error = msgpack::next(reader);
    expect_error(msgpack::finish(reader), msgpack::Error.TrailingBytes, "pure finish trailing");
    expect_error(msgpack::finish(reader), msgpack::Error.TrailingBytes, "pure finish is repeatable");
    expect(msgpack::consumed(reader) == 1, "pure finish did not consume the trailing byte");

    // A next after the value completed poisons with InvalidState, and the
    // poison is sticky.
    expect_error(msgpack::init(reader, "\x01"), msgpack::Error.None, "poison init");
    token, error = msgpack::next(reader);
    expect(msgpack::done(reader), "poison done");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.InvalidState, "next after done");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.InvalidState, "next after done is sticky");
    expect_error(msgpack::finish(reader), msgpack::Error.InvalidState, "finish reports the poison");
}

// ---- hardening: ownership and aliasing ---------------------------------
// The reader borrows the input, so a payload is a view that ends exactly at
// the cursor. The writer owns its buffer, so output is a view that a later
// write may move.
fn ownership_cases() {
    var reader = msgpack::Reader { .. };
    var writer = msgpack::Writer { .. };
    let input = "\x92\xa3abc\xc4\x02\x00\xff";
    expect_error(msgpack::init(reader, input), msgpack::Error.None, "ownership init");
    var token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "ownership array");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "ownership str");
    let text = msgpack::text(token);
    expect(text.len == 3, "str payload length");
    expect(text == input[2..5], "str payload is the input slice");
    expect(msgpack::consumed(reader) == 5, "str payload ends at the cursor");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "ownership bin");
    let bytes = msgpack::bytes(token);
    expect(bytes.len == 2, "bin payload length");
    expect(bytes == input[7..9], "bin payload is the input slice");
    expect(msgpack::consumed(reader) == 9, "bin payload ends at the cursor");
    expect_error(msgpack::finish(reader), msgpack::Error.None, "ownership finish");

    // The writer's output is a view: it grows, so a caller copies before the
    // next write. The length is always the bytes written.
    expect_error(msgpack::init(writer), msgpack::Error.None, "ownership writer init");
    expect_error(msgpack::str(writer, "abc"), msgpack::Error.None, "ownership write");
    expect(msgpack::output(writer).len == msgpack::written(writer), "output length is written");
    expect_bytes(msgpack::output(writer), "\xa3abc", "output bytes");
    expect_error(msgpack::str(writer, "de"), msgpack::Error.None, "ownership second write");
    expect(msgpack::written(writer) == 7, "written spans both values");
    expect_bytes(msgpack::output(writer), "\xa3abc\xa2de", "output spans both values");
}

// ---- hardening: the writer's large forms -------------------------------
fn writer_large_form_cases() {
    var writer = msgpack::Writer { .. };
    var limits = msgpack::Limits { .. };
    limits.max_container_len = 65536;
    limits.max_str_bytes = 65536;
    limits.max_bin_bytes = 65536;
    limits.max_output_bytes = 1048576;
    var big: u8[>..] = [];
    var i:   i64     = 0;
    while i < 65536 { big.push(0x61); i += 1; }

    // array16 and array32 headers.
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "large array16 init");
    expect_error(msgpack::array(writer, 65535), msgpack::Error.None, "array16 header");
    expect_bytes(msgpack::output(writer), "\xdc\xff\xff", "array16 bytes");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "large array32 init");
    expect_error(msgpack::array(writer, 65536), msgpack::Error.None, "array32 header");
    expect_bytes(msgpack::output(writer), "\xdd\x00\x01\x00\x00", "array32 bytes");
    // map16 and map32 headers.
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "large map16 init");
    expect_error(msgpack::map(writer, 65535), msgpack::Error.None, "map16 header");
    expect_bytes(msgpack::output(writer), "\xde\xff\xff", "map16 bytes");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "large map32 init");
    expect_error(msgpack::map(writer, 65536), msgpack::Error.None, "map32 header");
    expect_bytes(msgpack::output(writer), "\xdf\x00\x01\x00\x00", "map32 bytes");
    // str32, bin32 and ext32 headers, with the payload length checked.
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "large str32 init");
    expect_error(msgpack::str(writer, big), msgpack::Error.None, "str32 header");
    expect(msgpack::written(writer) == 65541, "str32 is five header bytes plus the payload");
    expect_bytes(msgpack::output(writer)[..5], "\xdb\x00\x01\x00\x00", "str32 header bytes");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "large bin32 init");
    expect_error(msgpack::bin(writer, big), msgpack::Error.None, "bin32 header");
    expect(msgpack::written(writer) == 65541, "bin32 is five header bytes plus the payload");
    expect_bytes(msgpack::output(writer)[..5], "\xc6\x00\x01\x00\x00", "bin32 header bytes");
    expect_error(msgpack::init(writer, limits), msgpack::Error.None, "large ext32 init");
    expect_error(msgpack::ext(writer, 3, big), msgpack::Error.None, "ext32 header");
    expect(msgpack::written(writer) == 65542, "ext32 is six header bytes plus the payload");
    expect_bytes(msgpack::output(writer)[..6], "\xc9\x00\x01\x00\x00\x03", "ext32 header bytes");
    // The fixed ext forms are used for 1, 2, 4, 8 and 16 bytes only.
    let four: u8[>..] = [1, 2, 3, 4];
    expect_error(msgpack::init(writer), msgpack::Error.None, "fixext4 init");
    expect_error(msgpack::ext(writer, 1, four), msgpack::Error.None, "fixext4 write");
    expect_bytes(msgpack::output(writer), "\xd6\x01\x01\x02\x03\x04", "fixext4 bytes");
    let eight: u8[>..] = [1, 2, 3, 4, 5, 6, 7, 8];
    expect_error(msgpack::init(writer), msgpack::Error.None, "fixext8 init");
    expect_error(msgpack::ext(writer, 1, eight), msgpack::Error.None, "fixext8 write");
    expect_bytes(msgpack::output(writer), "\xd7\x01\x01\x02\x03\x04\x05\x06\x07\x08", "fixext8 bytes");
    let sixteen: u8[>..] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
    expect_error(msgpack::init(writer), msgpack::Error.None, "fixext16 init");
    expect_error(msgpack::ext(writer, 1, sixteen), msgpack::Error.None, "fixext16 write");
    expect_bytes(msgpack::output(writer)[..2], "\xd8\x01", "fixext16 header bytes");
    expect(msgpack::written(writer) == 18, "fixext16 is two header bytes plus the payload");
}

// ---- hardening: depth with an empty last child -------------------------
// An empty container does not open a frame, so it must not consume depth.
fn depth_empty_child_cases() {
    var reader = msgpack::Reader { .. };
    var limits = msgpack::Limits { .. };
    limits.max_depth = 1;
    expect_error(msgpack::init(reader, "\x91\x90", limits), msgpack::Error.None, "empty child init");
    var token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "empty child outer");
    expect(msgpack::depth(reader) == 1, "empty child outer depth");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "empty child inner");
    expect(msgpack::count(token) == 0, "empty child count");
    expect(msgpack::depth(reader) == 0, "an empty container does not open a frame");
    expect(msgpack::done(reader), "empty child completes the value");
    expect_error(msgpack::finish(reader), msgpack::Error.None, "empty child finish");
    // The same shape one level deeper is rejected at max_depth 1.
    expect_error(msgpack::init(reader, "\x91\x91\x90", limits), msgpack::Error.None, "deep empty init");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.None, "deep empty outer");
    token, error = msgpack::next(reader);
    expect_error(error, msgpack::Error.DepthLimit, "deep empty rejected");
    // remaining is -1 exactly at the top level, and >= 1 inside a frame.
    expect_error(msgpack::init(reader, "\x82\xa1a\x01\xa1b\x02"), msgpack::Error.None, "remaining map init");
    token, error = msgpack::next(reader);
    expect(msgpack::remaining(reader) == 4, "a map frame holds 2 * count elements");
    expect(msgpack::depth(reader) == 1, "map depth");
}

// ---- hardening: the output budget is exact for every writer case --------
// The size a writer reserves must be the size it emits. A reserve that is one
// byte too large rejects a value that fits; one too small appends past the
// budget. Both are caught here, for every boundary value.
fn output_budget_exact_cases() {
    var writer = msgpack::Writer { .. };
    var limits = msgpack::Limits { .. };
    let cases: (const u8[:])[43] = [
        "nil", "false", "true",
        "uint-0", "uint-127", "uint-128", "uint-255", "uint-256",
        "uint-65535", "uint-65536", "uint-4294967295", "uint-4294967296", "uint-max",
        "int-neg1", "int-neg32", "int-neg33", "int-neg128", "int-neg129",
        "int-neg32768", "int-neg32769", "int-neg2147483648", "int-neg2147483649",
        "int-min", "int-positive-is-uint",
        "f32-1.5", "f64-1.5", "f64-neg0",
        "str-empty", "str-a", "str-31", "str-32", "str-utf8",
        "bin-empty", "bin-2", "ext-1", "ext-2", "ext-3",
        "array-0", "array-15", "array-16", "map-0", "map-15", "map-16",
    ];
    for i in cases.len {
        // Measure what the value actually emits under the default budget.
        expect_error(msgpack::init(writer), msgpack::Error.None, cases[i]);
        expect_error(write_case(writer, cases[i]), msgpack::Error.None, cases[i]);
        let size = msgpack::written(writer);
        expect(size >= 1, cases[i]);
        // The exact size fits.
        limits = msgpack::Limits { .. };
        limits.max_output_bytes = size;
        expect_error(msgpack::init(writer, limits), msgpack::Error.None, cases[i]);
        expect_error(write_case(writer, cases[i]), msgpack::Error.None, cases[i]);
        expect(msgpack::written(writer) == size, cases[i]);
        // One byte less does not, and appends nothing.
        limits.max_output_bytes = size - 1;
        expect_error(msgpack::init(writer, limits), msgpack::Error.None, cases[i]);
        expect_error(write_case(writer, cases[i]), msgpack::Error.OutputLimit, cases[i]);
        expect(msgpack::written(writer) == 0, cases[i]);
    }
}

// ---- hardening: a map frame holds 2 * count elements -------------------
// Writing only the keys must leave the frame open. A frame that counts pairs
// instead of elements closes early and silently accepts a truncated map.
fn map_frame_cases() {
    var writer = msgpack::Writer { .. };
    expect_error(msgpack::init(writer), msgpack::Error.None, "map frame init");
    expect_error(msgpack::map(writer, 1), msgpack::Error.None, "map frame open");
    expect_error(msgpack::str(writer, "k"), msgpack::Error.None, "map frame key");
    expect_error(msgpack::finish(writer), msgpack::Error.Unbalanced, "a map needs its value too");
    expect_error(msgpack::uint(writer, 1), msgpack::Error.None, "map frame value");
    expect_error(msgpack::finish(writer), msgpack::Error.None, "map frame complete");
    expect_bytes(msgpack::output(writer), "\x81\xa1k\x01", "map frame bytes");

    // Two pairs need four elements, not two.
    expect_error(msgpack::init(writer), msgpack::Error.None, "map frame 2 init");
    expect_error(msgpack::map(writer, 2), msgpack::Error.None, "map frame 2 open");
    expect_error(msgpack::str(writer, "a"), msgpack::Error.None, "map frame 2 key 1");
    expect_error(msgpack::uint(writer, 1), msgpack::Error.None, "map frame 2 value 1");
    expect_error(msgpack::str(writer, "b"), msgpack::Error.None, "map frame 2 key 2");
    expect_error(msgpack::finish(writer), msgpack::Error.Unbalanced, "a map of two pairs needs four elements");
    expect_error(msgpack::uint(writer, 2), msgpack::Error.None, "map frame 2 value 2");
    expect_error(msgpack::finish(writer), msgpack::Error.None, "map frame 2 complete");
    expect_bytes(msgpack::output(writer), "\x82\xa1a\x01\xa1b\x02", "map frame 2 bytes");

    // A nested map inside an array keeps both frames open until both close.
    expect_error(msgpack::init(writer), msgpack::Error.None, "nested map init");
    expect_error(msgpack::array(writer, 1), msgpack::Error.None, "nested map array");
    expect_error(msgpack::map(writer, 1), msgpack::Error.None, "nested map open");
    expect_error(msgpack::str(writer, "k"), msgpack::Error.None, "nested map key");
    expect_error(msgpack::finish(writer), msgpack::Error.Unbalanced, "nested map needs its value");
    expect_error(msgpack::nil(writer), msgpack::Error.None, "nested map value");
    expect_error(msgpack::finish(writer), msgpack::Error.None, "nested map complete");
    expect_bytes(msgpack::output(writer), "\x91\x81\xa1k\xc0", "nested map bytes");
}
