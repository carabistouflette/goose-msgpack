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

// The value each `encoded` case writes, selected by the case name.
fn encode_into(writer: msgpack::Writer&, what: const u8[:]) {
    if what == "nil" { expect_error(msgpack::nil(writer), msgpack::Error.None, what); return; }
    if what == "false" { expect_error(msgpack::boolean(writer, false), msgpack::Error.None, what); return; }
    if what == "true" { expect_error(msgpack::boolean(writer, true), msgpack::Error.None, what); return; }
    if what == "uint-0" { expect_error(msgpack::uint(writer, 0), msgpack::Error.None, what); return; }
    if what == "uint-127" { expect_error(msgpack::uint(writer, 127), msgpack::Error.None, what); return; }
    if what == "uint-128" { expect_error(msgpack::uint(writer, 128), msgpack::Error.None, what); return; }
    if what == "uint-255" { expect_error(msgpack::uint(writer, 255), msgpack::Error.None, what); return; }
    if what == "uint-256" { expect_error(msgpack::uint(writer, 256), msgpack::Error.None, what); return; }
    if what == "uint-65535" { expect_error(msgpack::uint(writer, 65535), msgpack::Error.None, what); return; }
    if what == "uint-65536" { expect_error(msgpack::uint(writer, 65536), msgpack::Error.None, what); return; }
    if what == "uint-4294967295" { expect_error(msgpack::uint(writer, 4294967295), msgpack::Error.None, what); return; }
    if what == "uint-4294967296" { expect_error(msgpack::uint(writer, 4294967296), msgpack::Error.None, what); return; }
    if what == "uint-max" { expect_error(msgpack::uint(writer, 18446744073709551615), msgpack::Error.None, what); return; }
    if what == "int-neg1" { expect_error(msgpack::int(writer, -1), msgpack::Error.None, what); return; }
    if what == "int-neg32" { expect_error(msgpack::int(writer, -32), msgpack::Error.None, what); return; }
    if what == "int-neg33" { expect_error(msgpack::int(writer, -33), msgpack::Error.None, what); return; }
    if what == "int-neg128" { expect_error(msgpack::int(writer, -128), msgpack::Error.None, what); return; }
    if what == "int-neg129" { expect_error(msgpack::int(writer, -129), msgpack::Error.None, what); return; }
    if what == "int-neg32768" { expect_error(msgpack::int(writer, -32768), msgpack::Error.None, what); return; }
    if what == "int-neg32769" { expect_error(msgpack::int(writer, -32769), msgpack::Error.None, what); return; }
    if what == "int-neg2147483648" { expect_error(msgpack::int(writer, -2147483648), msgpack::Error.None, what); return; }
    if what == "int-neg2147483649" { expect_error(msgpack::int(writer, -2147483649), msgpack::Error.None, what); return; }
    if what == "int-min" { expect_error(msgpack::int(writer, -9223372036854775807 - 1), msgpack::Error.None, what); return; }
    if what == "int-positive-is-uint" { expect_error(msgpack::int(writer, 5), msgpack::Error.None, what); return; }
    if what == "f32-1.5" { expect_error(msgpack::float32(writer, 1.5), msgpack::Error.None, what); return; }
    if what == "f64-1.5" { expect_error(msgpack::float64(writer, 1.5), msgpack::Error.None, what); return; }
    if what == "f64-neg0" { expect_error(msgpack::float64(writer, -0.0), msgpack::Error.None, what); return; }
    if what == "str-empty" { expect_error(msgpack::str(writer, ""), msgpack::Error.None, what); return; }
    if what == "str-a" { expect_error(msgpack::str(writer, "a"), msgpack::Error.None, what); return; }
    if what == "str-31" { expect_error(msgpack::str(writer, "0123456789012345678901234567890"), msgpack::Error.None, what); return; }
    if what == "str-32" { expect_error(msgpack::str(writer, "01234567890123456789012345678901"), msgpack::Error.None, what); return; }
    if what == "str-utf8" { expect_error(msgpack::str(writer, "é"), msgpack::Error.None, what); return; }
    if what == "bin-empty" { expect_error(msgpack::bin(writer, ""), msgpack::Error.None, what); return; }
    if what == "bin-2" { expect_error(msgpack::bin(writer, "\x00\xff"), msgpack::Error.None, what); return; }
    if what == "ext-1" { expect_error(msgpack::ext(writer, 1, "\x7f"), msgpack::Error.None, what); return; }
    if what == "ext-2" { expect_error(msgpack::ext(writer, -1, "\x01\x02"), msgpack::Error.None, what); return; }
    if what == "ext-3" { expect_error(msgpack::ext(writer, 5, "\x01\x02\x03"), msgpack::Error.None, what); return; }
    if what == "array-0" { expect_error(msgpack::array(writer, 0), msgpack::Error.None, what); return; }
    if what == "array-15" { expect_error(msgpack::array(writer, 15), msgpack::Error.None, what); return; }
    if what == "array-16" { expect_error(msgpack::array(writer, 16), msgpack::Error.None, what); return; }
    if what == "map-0" { expect_error(msgpack::map(writer, 0), msgpack::Error.None, what); return; }
    if what == "map-15" { expect_error(msgpack::map(writer, 15), msgpack::Error.None, what); return; }
    if what == "map-16" { expect_error(msgpack::map(writer, 16), msgpack::Error.None, what); return; }
    abort("unknown case");
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
    if failures > 0 {
        write_stderr(str(failures, " of ", checks, " checks failed\n"));
        exit(1);
    }
    print("msgpack api ok: ", checks, " checks");
}
