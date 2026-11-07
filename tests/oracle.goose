// SPDX-License-Identifier: Apache-2.0
// Differential driver: one command per stdin line, one response per line.
//
//   R <max_input> <max_output> <max_nodes> <max_depth> <max_str> <max_bin> <max_container> <hex>
//
// The driver decodes the hex bytes with the reader, re-encodes the token stream
// with the writer, and prints the canonical bytes. A reader failure prints the
// error and its offset; a writer failure prints `W <error>`. The Python oracle
// in tests/oracle.py computes the same response independently.
import msgpack from "..";
import std;
import os;

fn hex_value(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

fn from_hex(text: const u8[:], out: u8[>..]&) -> bool {
    if text.len % 2 != 0 { return false; }
    var i: i64 = 0;
    while i < text.len {
        let hi = hex_value(text[i]);
        let lo = hex_value(text[i + 1]);
        if hi < 0 || lo < 0 { return false; }
        out.push((hi * 16 + lo) as u8);
        i += 2;
    }
    return true;
}

fn to_hex(bytes: const u8[:], out: u8[>..]&) {
    let digits = "0123456789abcdef";
    for b in bytes {
        out.push(digits[b >> 4]);
        out.push(digits[b & 0x0f]);
    }
}

fn parse_i64(text: const u8[:], at: i64&) -> i64 {
    var value: i64 = 0;
    var negative = false;
    while at < text.len && text[at] == ' ' { at += 1; }
    if at < text.len && text[at] == '-' { negative = true; at += 1; }
    while at < text.len && text[at] >= '0' && text[at] <= '9' {
        value = value * 10 + (text[at] - '0');
        at += 1;
    }
    return if negative { -value } else { value };
}

// Re-encode one decoded token. The writer applies the same budgets as the reader.
fn emit(writer: msgpack::Writer&, token: msgpack::Token) -> msgpack::Error {
    match token {
        Nil => { return msgpack::nil(writer); },
        Bool b => { return msgpack::boolean(writer, b.v); },
        Int i => { return msgpack::int(writer, i.v); },
        Uint u => { return msgpack::uint(writer, u.v); },
        F32 f => { return msgpack::float32(writer, f.v); },
        F64 f => { return msgpack::float64(writer, f.v); },
        Str s => { return msgpack::str(writer, s.v); },
        Bin b => { return msgpack::bin(writer, b.v); },
        Array a => { return msgpack::array(writer, a.count); },
        Map m => { return msgpack::map(writer, m.count); },
        Ext e => { return msgpack::ext(writer, e.typ, e.v); },
    }
}

fn main() {
    var line: u8[>..] = [];
    var data: u8[>..] = [];
    var out:  u8[>..] = [];
    var writer = msgpack::Writer { .. };
    while read_line(line) {
        if line.len == 0 { line.clear(); continue; }
        var at: i64 = 0;
        // The command letter is always R.
        at += 1;
        var limits = msgpack::Limits { .. };
        limits.max_input_bytes = parse_i64(line, at);
        limits.max_output_bytes = parse_i64(line, at);
        limits.max_nodes = parse_i64(line, at);
        limits.max_depth = parse_i64(line, at);
        limits.max_str_bytes = parse_i64(line, at);
        limits.max_bin_bytes = parse_i64(line, at);
        limits.max_container_len = parse_i64(line, at);
        data.clear();
        out.clear();
        while at < line.len && line[at] == ' ' { at += 1; }
        if !from_hex(line[at..], data) {
            out.append("E BadCommand 0");
            print(out);
            line.clear();
            continue;
        }
        // A fresh reader per line: it borrows `data`, which the next line clears.
        var reader = msgpack::Reader { .. };
        var error = msgpack::init(reader, data, limits);
        if error != msgpack::Error.None {
            format(out, "E ", error, " ", msgpack::offset(reader));
            print(out);
            line.clear();
            continue;
        }
        error = msgpack::init(writer, limits);
        if error != msgpack::Error.None {
            format(out, "W ", error);
            print(out);
            line.clear();
            continue;
        }
        while !msgpack::done(reader) && error == msgpack::Error.None {
            let token, step = msgpack::next(reader);
            error = step;
            if step != msgpack::Error.None { break; }
            let write_error = emit(writer, token);
            if write_error != msgpack::Error.None {
                format(out, "W ", write_error);
                print(out);
                break;
            }
        }
        if out.len > 0 { line.clear(); continue; }
        error = msgpack::finish(reader);
        if error != msgpack::Error.None {
            format(out, "E ", error, " ", msgpack::offset(reader));
            print(out);
            line.clear();
            continue;
        }
        error = msgpack::finish(writer);
        if error != msgpack::Error.None {
            format(out, "W ", error);
            print(out);
            line.clear();
            continue;
        }
        out.append("OK ");
        to_hex(msgpack::output(writer), out);
        print(out);
        line.clear();
    }
}
