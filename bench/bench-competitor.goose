// SPDX-License-Identifier: Apache-2.0
// The same five fixtures, built with Macho0x/goose-msgpack at the pinned
// commit, so bench/measure.py can pair the rows with bench/bench.goose.
//
//   python3 bench/fetch.py
//   goose build -o .build/bench/msgpack-bench-competitor bench/bench-competitor.goose --cc clang
//   .build/bench/msgpack-bench-competitor verify
//   .build/bench/msgpack-bench-competitor <batch> <ms>
//
// This file is a separate program on purpose. Both packages are named
// `msgpack`, and a Goose import alias must equal the entry file's basename, so
// one program cannot import both. Two binaries with one shared fixture table
// and one shared row format is the honest alternative: `verify` proves the two
// encode the same bytes, and measure.py refuses to pair rows that disagree.
//
// Equal contract: the workloads are identical. The contracts are not. The
// competitor has no input, output, node, depth, str, bin or container budget,
// no full-input check, and no UTF-8 validation, and its `decode::*` primitives
// are typed rather than a token stream. Those differences are the subject of
// the comparison, not something this harness can equalise away.
import msgpack from "../.build/competitor/goose-msgpack";
import msgpack.encode;
import msgpack.decode;
import std;
import os;

var g_data:    u8[>..] = [];
var g_out:     u8[>..] = [];
var g_fixture: i64     = 0;

fn fixture_count() -> i64 { return 5; }

fn fixture_name(i: i64) -> const u8[:] {
    if i == 0 { return "plan-small"; }
    if i == 1 { return "plan-medium"; }
    if i == 2 { return "plan-large"; }
    if i == 3 { return "strings-16x32"; }
    return "strings-4x256";
}

fn fixture_tasks(i: i64) -> i64 {
    if i == 0 { return 4; }
    if i == 1 { return 64; }
    if i == 2 { return 1024; }
    return 0;
}

fn fixture_edges(i: i64) -> i64 {
    if i == 0 { return 3; }
    if i == 1 { return 128; }
    if i == 2 { return 4096; }
    return 0;
}

fn fixture_members(i: i64) -> i64 {
    if i == 3 { return 16; }
    if i == 4 { return 4; }
    return 0;
}

fn fixture_member_bytes(i: i64) -> i64 {
    if i == 3 { return 32; }
    if i == 4 { return 256; }
    return 0;
}

fn encode_plan(i: i64, out: u8[>..]&) -> bool {
    let tasks = fixture_tasks(i);
    let edges = fixture_edges(i);
    let members = fixture_members(i);
    let member_bytes = fixture_member_bytes(i);
    var concurrency = tasks / 2;
    if concurrency < 1 { concurrency = 1; }
    encode::map(out, 6);
    encode::str(out, "format");
    encode::str(out, "goose-task-plan");
    encode::str(out, "version");
    encode::uint(out, 1);
    encode::str(out, "count");
    encode::uint(out, tasks as u64);
    encode::str(out, "concurrency");
    encode::uint(out, concurrency as u64);
    encode::str(out, "edges");
    encode::array(out, edges);
    var k: i64 = 0;
    while k < edges {
        encode::array(out, 2);
        encode::uint(out, (k % tasks) as u64);
        encode::uint(out, ((k * 7 + 1) % tasks) as u64);
        k += 1;
    }
    encode::str(out, "labels");
    encode::map(out, members);
    var m: i64 = 0;
    while m < members {
        var key: u8[>..] = [];
        key.push('k');
        format_int(key, m, 10, 0, ' ');
        encode::str(out, key[..]);
        var value: u8[>..] = [];
        var j:     i64     = 0;
        while j < member_bytes {
            value.push('x');
            j += 1;
        }
        encode::str(out, value[..]);
        m += 1;
    }
    return true;
}

// FNV-1a over the bytes a primitive consumed. A token count is not a checksum:
// it cannot tell a correct walk from one that read the wrong spans, and the
// compiler may delete work whose only effect is a counter it can prove.
fn fold(h: u64, src: u8[:], from: i64, to: i64) -> u64 {
    var x = h;
    var i = from;
    while i < to {
        x = (x ^ src[i]) * 1099511628211;
        i += 1;
    }
    return x;
}

const FNV_OFFSET: u64 = 14695981039346656037;

fn take_str(src: u8[:], at: i64&, h: u64&) -> bool {
    let before = at;
    let s, ok = decode::str(src, at);
    if !ok { return false; }
    h = fold(h, src, before, at);
    return true;
}

fn take_uint(src: u8[:], at: i64&, h: u64&) -> bool {
    let before = at;
    let v, ok = decode::uint(src, at);
    if !ok { return false; }
    h = fold(h, src, before, at);
    return true;
}

// The same schema walk bench.goose performs with the token reader. The
// competitor has no generic token, so each field is read with its typed
// primitive; the token reader dispatches once per value instead.
fn dec_plan(src: u8[:]) -> u64 {
    var at: i64 = 0;
    var h:  u64 = FNV_OFFSET;
    let before_map = at;
    let members, ok = decode::map(src, at);
    if !ok { return 0; }
    h = fold(h, src, before_map, at);
    if !take_str(src, at, h) { return h; }
    if !take_str(src, at, h) { return h; }
    if !take_str(src, at, h) { return h; }
    if !take_uint(src, at, h) { return h; }
    if !take_str(src, at, h) { return h; }
    if !take_uint(src, at, h) { return h; }
    if !take_str(src, at, h) { return h; }
    if !take_uint(src, at, h) { return h; }
    if !take_str(src, at, h) { return h; }
    let before_edges = at;
    let edges, ok_edges = decode::array(src, at);
    if !ok_edges { return h; }
    h = fold(h, src, before_edges, at);
    var k: i64 = 0;
    while k < edges {
        let before_pair = at;
        let pair, ok_pair = decode::array(src, at);
        if !ok_pair { return h; }
        h = fold(h, src, before_pair, at);
        var e: i64 = 0;
        while e < pair {
            if !take_uint(src, at, h) { return h; }
            e += 1;
        }
        k += 1;
    }
    if !take_str(src, at, h) { return h; }
    let before_labels = at;
    let labels, ok_labels = decode::map(src, at);
    if !ok_labels { return h; }
    h = fold(h, src, before_labels, at);
    var m: i64 = 0;
    while m < labels {
        if !take_str(src, at, h) { return h; }
        if !take_str(src, at, h) { return h; }
        m += 1;
    }
    return (h ^ (at as u64)) * 1099511628211;
}

fn hex(out: u8[>..]&, data: const u8[:]) {
    var digits: u8[16] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
    for i in 0..data.len {
        out.push(digits[(data[i] >> 4) & 0xf]);
        out.push(digits[data[i] & 0xf]);
    }
}

fn verify() -> i64 {
    var bad: i64 = 0;
    var i:   i64 = 0;
    while i < fixture_count() {
        g_out.clear();
        if !encode_plan(i, g_out) {
            write_stderr("FAIL encode ");
            write_stderr(fixture_name(i));
            write_stderr("\n");
            bad += 1;
            i += 1;
            continue;
        }
        var row: u8[>..] = [];
        row.append("fixture ");
        row.append(fixture_name(i));
        row.append(" bytes ");
        format_int(row, g_out.len, 10, 0, ' ');
        row.append(" hex ");
        hex(row, g_out[..]);
        row.push('\n');
        write_stdout(row[..]);
        i += 1;
    }
    return bad;
}

fn time_batch<F>(batch: i64, ms: i64) -> i64, u64 {
    var sink: u64 = 0;
    var k:    i64 = 0;
    while k < batch {
        sink += F();
        k += 1;
    }
    var n:  i64 = 0;
    var dt: i64 = 0;
    let end = clock_ns() + ms * 1000000;
    while true {
        let t0 = clock_ns();
        k = 0;
        while k < batch {
            sink += F();
            k += 1;
        }
        dt += clock_ns() - t0;
        n += batch;
        if clock_ns() >= end { break; }
    }
    return dt / n, sink;
}

fn row<F>(name: const u8[:], op: const u8[:], batch: i64, ms: i64) -> u64 {
    let ns, part = time_batch(batch, ms, F);
    var out: u8[>..] = [];
    out.append("time ");
    out.append(name);
    out.push(' ');
    out.append(op);
    out.push(' ');
    format_int(out, batch, 10, 0, ' ');
    out.push(' ');
    format_int(out, ns, 10, 0, ' ');
    out.push('\n');
    write_stdout(out[..]);
    return part;
}

// Reused output buffer: one allocation, appended to every iteration.
fn enc() -> u64 {
    g_out.clear();
    if !encode_plan(g_fixture, g_out) { return 0; }
    return fold(FNV_OFFSET, g_out[..], 0, g_out.len);
}

// Fresh output buffer: one allocation per document.
fn enc_fresh() -> u64 {
    var out: u8[>..] = [];
    if !encode_plan(g_fixture, out) { return 0; }
    return fold(FNV_OFFSET, out[..], 0, out.len);
}

fn dec() -> u64 {
    return dec_plan(g_data[..]);
}

fn dec_truncated() -> u64 {
    if g_data.len < 2 { return 0; }
    return dec_plan(g_data[..g_data.len - 1]);
}

// One `sum <fixture> <op> <value>` row per measured row, computed once, so the
// runner can prove this binary's own checksums are stable across samples.
fn checksums() -> i64 {
    var i: i64 = 0;
    while i < fixture_count() {
        g_fixture = i;
        g_out.clear();
        if !encode_plan(i, g_out) {
            write_stderr("FAIL encode ");
            write_stderr(fixture_name(i));
            write_stderr("\n");
            return 1;
        }
        g_data.clear();
        g_data.append(g_out[..]);
        sum_row(fixture_name(i), "encode-reused", enc());
        sum_row(fixture_name(i), "encode-fresh", enc_fresh());
        sum_row(fixture_name(i), "decode-fresh", dec());
        na(fixture_name(i), "decode-reused");
        sum_row(fixture_name(i), "decode-truncated", dec_truncated());
        i += 1;
    }
    return 0;
}

fn sum_row(name: const u8[:], op: const u8[:], value: u64) {
    var out: u8[>..] = [];
    out.append("sum ");
    out.append(name);
    out.push(' ');
    out.append(op);
    out.push(' ');
    format_int(out, value as i64, 10, 0, ' ');
    out.push('\n');
    write_stdout(out[..]);
}

// An explicitly not-applicable cell. The runner prints it as `n/a` instead of
// inventing a number, so the table never implies a comparison that was not run.
fn na(name: const u8[:], op: const u8[:]) {
    var out: u8[>..] = [];
    out.append("na ");
    out.append(name);
    out.push(' ');
    out.append(op);
    out.push('\n');
    write_stdout(out[..]);
}

fn ::main() {
    var args: u8[>..] = [];
    if arg_count() > 1 { arg(1, args); }
    if args[..] == "verify" {
        let bad = verify();
        if bad != 0 { exit(1); }
        return;
    }
    if args[..] == "checksum" {
        let bad = checksums();
        if bad != 0 { exit(1); }
        return;
    }
    var batch: i64 = 64;
    var ms:    i64 = 200;
    if arg_count() > 1 {
        var a: u8[>..] = [];
        arg(1, a);
        let parsed, ok = parse_int(a[..]);
        if !ok { write_stderr("bench: batch is not an integer\n"); exit(2); }
        batch = parsed;
    }
    if arg_count() > 2 {
        var b: u8[>..] = [];
        arg(2, b);
        let parsed, ok = parse_int(b[..]);
        if !ok { write_stderr("bench: ms is not an integer\n"); exit(2); }
        ms = parsed;
    }
    if batch < 1 || ms < 1 {
        write_stderr("usage: msgpack-bench-competitor [verify | <batch> <ms>]\n");
        exit(2);
    }
    var sink: u64 = 0;
    var i:    i64 = 0;
    while i < fixture_count() {
        g_fixture = i;
        g_out.clear();
        if !encode_plan(i, g_out) {
            write_stderr("FAIL encode ");
            write_stderr(fixture_name(i));
            write_stderr("\n");
            exit(1);
        }
        g_data.clear();
        g_data.append(g_out[..]);
        sink += row(fixture_name(i), "encode-reused", batch, ms, enc);
        sink += row(fixture_name(i), "encode-fresh", batch, ms, enc_fresh);
        sink += row(fixture_name(i), "decode-fresh", batch, ms, dec);
        // The competitor's decoder is stateless: `at` is a caller-owned cursor
        // and there is no reader object to reuse, so this cell is not
        // applicable rather than equal to decode-fresh.
        na(fixture_name(i), "decode-reused");
        sink += row(fixture_name(i), "decode-truncated", batch, ms, dec_truncated);
        i += 1;
    }
    if sink == 0 { write_stderr("bench: empty sink\n"); exit(1); }
}
