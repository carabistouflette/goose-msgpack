// SPDX-License-Identifier: Apache-2.0
// Third-party triangulation: emit a canonical token form for every record in a
// corpus, so an independent maintained MessagePack implementation can be
// compared with this reader on exactly the same bytes.
//
//   goose build tests/triangulate.goose --standalone --cc clang -O2 -o .build/triangulate
//   .build/triangulate <corpus>
//
// Corpus format: repeated `u32 little-endian length` + that many bytes.
// Output: `record <i>` then one canonical line per token in pre-order, then
// `end`; or `reject <ErrorName>` when the reader refuses the record. Token
// lines emitted before a refusal are discarded by the driver, because a token
// stream is only meaningful when the whole document is accepted.
//
// The canonical form is the one in tests/triangulate_msgpackc.c. Floats are
// printed as raw bytes in memory order so NaN payloads, -0.0 and both widths
// survive the comparison exactly.
import msgpack from "..";
import std;
import os;

fn put_u64(out: u8[>..]&, v: u64) {
    if v == 0 { out.push(48); return; }
    let start = out.len;
    var x = v;
    while x > 0 {
        out.push(48 + (x % 10) as u8);
        x /= 10;
    }
    // The digits were pushed least-significant first; reverse them in place.
    var i = start;
    var j = out.len - 1;
    while i < j {
        let t = out[i];
        out[i] = out[j];
        out[j] = t;
        i += 1;
        j -= 1;
    }
}

fn put_hex(out: u8[>..]&, data: const u8[:]) {
    var digits: u8[16] = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 97, 98, 99, 100, 101, 102];
    for i in 0..data.len {
        out.push(digits[(data[i] >> 4) & 0xf]);
        out.push(digits[data[i] & 0xf]);
    }
}

fn error_name(e: msgpack::Error) -> const u8[:] {
    if e == msgpack::Error.None { return "None"; }
    if e == msgpack::Error.InvalidOptions { return "InvalidOptions"; }
    if e == msgpack::Error.InvalidState { return "InvalidState"; }
    if e == msgpack::Error.Truncated { return "Truncated"; }
    if e == msgpack::Error.Reserved { return "Reserved"; }
    if e == msgpack::Error.DepthLimit { return "DepthLimit"; }
    if e == msgpack::Error.NodeLimit { return "NodeLimit"; }
    if e == msgpack::Error.InputLimit { return "InputLimit"; }
    if e == msgpack::Error.OutputLimit { return "OutputLimit"; }
    if e == msgpack::Error.StrLimit { return "StrLimit"; }
    if e == msgpack::Error.BinLimit { return "BinLimit"; }
    if e == msgpack::Error.ContainerLimit { return "ContainerLimit"; }
    if e == msgpack::Error.TrailingBytes { return "TrailingBytes"; }
    if e == msgpack::Error.Unbalanced { return "Unbalanced"; }
    return "InvalidUtf8";
}

fn emit_token(out: u8[>..]&, token: msgpack::Token) {
    // Statement-block arms need a comma separator in this compiler; a block
    // that ends in `return` does not.
    match token {
        Nil => { out.append("nil\n"); },
        Bool b => {
            out.append("bool ");
            out.push(if b.v { 49 } else { 48 });
            out.push(10);
        },
        Int i => {
            out.append("int ");
            format_int(out, i.v, 10, 0, ' ');
            out.push(10);
        },
        Uint u => {
            // Canonicalised by mathematical value, not by wire family: the
            // family is this library's API choice, the value is the wire fact.
            if u.v <= 0x7fffffffffffffff {
                out.append("int ");
                format_int(out, u.v as i64, 10, 0, ' ');
                out.push(10);
            } else {
                out.append("uint ");
                put_u64(out, u.v);
                out.push(10);
            }
        },
        F32 f => {
            out.append("f32 ");
            let image: f32[1] = [f.v];
            put_hex(out, bytes_of(image));
            out.push(10);
        },
        F64 f => {
            out.append("f64 ");
            let image: f64[1] = [f.v];
            put_hex(out, bytes_of(image));
            out.push(10);
        },
        Str s => {
            out.append("str ");
            format_int(out, s.v.len, 10, 0, ' ');
            out.push(32);
            put_hex(out, s.v);
            out.push(10);
        },
        Bin b => {
            out.append("bin ");
            format_int(out, b.v.len, 10, 0, ' ');
            out.push(32);
            put_hex(out, b.v);
            out.push(10);
        },
        Ext e => {
            out.append("ext ");
            format_int(out, e.typ as i64, 10, 0, ' ');
            out.push(32);
            format_int(out, e.v.len, 10, 0, ' ');
            out.push(32);
            put_hex(out, e.v);
            out.push(10);
        },
        Array a => {
            out.append("array ");
            format_int(out, a.count, 10, 0, ' ');
            out.push(10);
        },
        Map m => {
            out.append("map ");
            format_int(out, m.count, 10, 0, ' ');
            out.push(10);
        },
    }
}

fn ::main() {
    if arg_count() < 2 {
        write_stderr("usage: triangulate <corpus>\n");
        exit(2);
    }
    var path: u8[>..] = [];
    arg(1, path);
    var corpus: u8[>..] = [];
    if !read_file(path[..], corpus) {
        write_stderr("triangulate: cannot read the corpus\n");
        exit(2);
    }
    var out:   u8[>..] = [];
    var at:    i64     = 0;
    var index: i64     = 0;
    while at + 4 <= corpus.len {
        let len = (corpus[at] as i64) | ((corpus[at + 1] as i64) << 8) |
            ((corpus[at + 2] as i64) << 16) | ((corpus[at + 3] as i64) << 24);
        at += 4;
        if len < 0 || at + len > corpus.len {
            write_stderr("triangulate: short record\n");
            exit(2);
        }
        let record = corpus[at..at + len];
        at += len;
        out.append("record ");
        format_int(out, index, 10, 0, ' ');
        out.push(10);

        // The widest limits the library allows, so a refusal is a contract
        // refusal and not an artefact of a small default budget.
        var limits = msgpack::Limits { .. };
        limits.max_input_bytes = msgpack::MAX_INPUT_BYTES;
        limits.max_nodes = msgpack::MAX_NODES;
        limits.max_depth = msgpack::MAX_DEPTH;
        limits.max_str_bytes = msgpack::MAX_STR_BYTES;
        limits.max_bin_bytes = msgpack::MAX_BIN_BYTES;
        limits.max_container_len = msgpack::MAX_CONTAINER_LEN;

        var reader = msgpack::Reader { .. };
        let started = msgpack::init(reader, record, limits);
        if started != msgpack::Error.None {
            out.append("reject ");
            out.append(error_name(started));
            out.push(10);
            index += 1;
            continue;
        }
        var failed = msgpack::Error.None;
        while !msgpack::done(reader) {
            let token, error = msgpack::next(reader);
            if error != msgpack::Error.None { failed = error; break; }
            emit_token(out, token);
        }
        if failed == msgpack::Error.None { failed = msgpack::finish(reader); }
        if failed != msgpack::Error.None {
            out.append("reject ");
            out.append(error_name(failed));
            out.push(10);
        } else {
            out.append("end\n");
        }
        index += 1;
    }
    write_stdout(out[..]);
}
