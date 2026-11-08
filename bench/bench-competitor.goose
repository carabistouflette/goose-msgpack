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

// The invalid inputs, built once per fixture so the timed loop measures the
// decoder and not the buffer construction.
var g_truncated_end:    u8[>..] = [];
var g_truncated_start:  u8[>..] = [];
var g_truncated_middle: u8[>..] = [];
var g_corrupt_start:    u8[>..] = [];
var g_corrupt_middle:   u8[>..] = [];
var g_corrupt_end:      u8[>..] = [];

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

// The anti-elimination barrier: a word-wise hash of the bytes a primitive
// consumed, folded into the running value. A token count is not a barrier: it
// cannot tell a correct walk from one that read the wrong spans, and the
// compiler may delete work whose only effect is a counter it can prove.
//
// This used to be a byte-at-a-time FNV-1a. A profile of the goose-msgpack
// harness showed that fold taking 45% of the samples, so the harness was
// measuring its own checksum. The full byte-wise content checksum now lives in
// `checksum` mode, outside any timing, and the loop carries this word-wise
// barrier instead. See the header of bench/bench.goose.
fn fold(h: u64, src: u8[:], from: i64, to: i64) -> u64 {
    return (h ^ hash(src[from..to])) * 1099511628211;
}

const FNV_OFFSET: u64 = 14695981039346656037;

// The first and last byte of a payload, so the fold depends on the content and
// not only on its length.
fn sample(payload: u8[:]) -> u64 {
    if payload.len == 0 { return 0; }
    return ((payload[0] as u64) << 8) | payload[payload.len - 1];
}

// Fold the decoded value as well as the wire span. A barrier that folds only the
// span leaves the checksum unchanged for a decoder that returns the right type
// at the right offset with the wrong value, so a broken decoder would benchmark
// as a fast one. `g_mutant` zeroes the value, which is the negative control.
var g_mutant: bool = false;

fn fold_value(h: u64, value: u64, extra: u64) -> u64 {
    var v = value;
    var e = extra;
    if g_mutant {
        v = 0;
        e = 0;
    }
    var g = (h ^ v) * 1099511628211;
    g = (g ^ e) * 1099511628211;
    return g;
}

fn take_str(src: u8[:], at: i64&, h: u64&) -> bool {
    let before = at;
    let s, ok = decode::str(src, at);
    if !ok { return false; }
    h = fold(h, src, before, at);
    h = fold_value(h, s.len as u64, sample(s));
    return true;
}

fn take_uint(src: u8[:], at: i64&, h: u64&) -> bool {
    let before = at;
    let v, ok = decode::uint(src, at);
    if !ok { return false; }
    h = fold(h, src, before, at);
    h = fold_value(h, v, 0);
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
    h = fold_value(h, edges as u64, 0);
    var k: i64 = 0;
    while k < edges {
        let before_pair = at;
        let pair, ok_pair = decode::array(src, at);
        if !ok_pair { return h; }
        h = fold(h, src, before_pair, at);
        h = fold_value(h, pair as u64, 0);
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
    h = fold_value(h, labels as u64, 0);
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

        // The invalid variants are published too, so the reader can prove both
        // binaries measure the same invalid inputs rather than assuming it.
        g_data.clear();
        g_data.append(g_out[..]);
        build_invalid();
        invalid_row(fixture_name(i), "truncated-end", g_truncated_end[..]);
        invalid_row(fixture_name(i), "truncated-start", g_truncated_start[..]);
        invalid_row(fixture_name(i), "truncated-middle", g_truncated_middle[..]);
        invalid_row(fixture_name(i), "corrupt-start", g_corrupt_start[..]);
        invalid_row(fixture_name(i), "corrupt-middle", g_corrupt_middle[..]);
        invalid_row(fixture_name(i), "corrupt-end", g_corrupt_end[..]);
        i += 1;
    }
    return bad;
}

fn invalid_row(name: const u8[:], op: const u8[:], data: const u8[:]) {
    var row: u8[>..] = [];
    row.append("invalid ");
    row.append(name);
    row.push(' ');
    row.append(op);
    row.append(" bytes ");
    format_int(row, data.len, 10, 0, ' ');
    row.append(" hex ");
    hex(row, data);
    row.push('\n');
    write_stdout(row[..]);
}

// Returns the raw totals, never a pre-divided rate. The output contract is
// `time <fixture> <op> <n> <dt_ns>`: total elapsed nanoseconds for n calls, and
// the reader divides exactly once. Printing a rate here and a batch there
// invites the reader to divide twice, which is a silent factor-of-batch error.
fn time_batch<F>(batch: i64, ms: i64) -> i64, i64, u64 {
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
    return dt, n, sink;
}

fn row<F>(name: const u8[:], op: const u8[:], batch: i64, ms: i64) -> u64 {
    let dt, n, part = time_batch(batch, ms, F);
    var out: u8[>..] = [];
    out.append("time ");
    out.append(name);
    out.push(' ');
    out.append(op);
    out.push(' ');
    format_int(out, n, 10, 0, ' ');
    out.push(' ');
    format_int(out, dt, 10, 0, ' ');
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

fn dec_truncated_end() -> u64 { return dec_plan(g_truncated_end[..]); }
fn dec_truncated_start() -> u64 { return dec_plan(g_truncated_start[..]); }
fn dec_truncated_middle() -> u64 { return dec_plan(g_truncated_middle[..]); }
fn dec_corrupt_start() -> u64 { return dec_plan(g_corrupt_start[..]); }
fn dec_corrupt_middle() -> u64 { return dec_plan(g_corrupt_middle[..]); }
fn dec_corrupt_end() -> u64 { return dec_plan(g_corrupt_end[..]); }

// Build the invalid inputs for the current fixture, once, outside the loop.
// The competitor has no full-input check and no UTF-8 check, so some of these
// documents are accepted by it and refused by goose-msgpack. That is the
// contract difference under test, and the per-binary checksum records it.
fn build_invalid() {
    let n = g_data.len;
    g_truncated_end.clear();
    g_truncated_start.clear();
    g_truncated_middle.clear();
    g_corrupt_start.clear();
    g_corrupt_middle.clear();
    g_corrupt_end.clear();
    if n < 4 { return; }
    g_truncated_end.append(g_data[..n - 1]);
    g_truncated_start.append(g_data[1..]);
    let middle = n / 2;
    g_truncated_middle.append(g_data[..middle]);
    g_truncated_middle.append(g_data[middle + 1..]);
    g_corrupt_start.append(g_data[..]);
    g_corrupt_start[0] = 0xc1;
    g_corrupt_middle.append(g_data[..]);
    g_corrupt_middle[middle] = 0xc1;
    g_corrupt_end.append(g_data[..]);
    g_corrupt_end[n - 1] = 0xc1;
}

// One `sum <fixture> <op> <value>` row per measured row, computed once, so the
// runner can prove this binary's own checksums are stable across samples.
fn checksums(mutant: bool) -> i64 {
    g_mutant = mutant;
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
        build_invalid();
        sum_row(fixture_name(i), "encode-reused", enc());
        sum_row(fixture_name(i), "encode-fresh", enc_fresh());
        sum_row(fixture_name(i), "decode-fresh", dec());
        na(fixture_name(i), "decode-reused");
        sum_row(fixture_name(i), "decode-truncated-end", dec_truncated_end());
        sum_row(fixture_name(i), "decode-truncated-start", dec_truncated_start());
        sum_row(fixture_name(i), "decode-truncated-middle", dec_truncated_middle());
        sum_row(fixture_name(i), "decode-corrupt-start", dec_corrupt_start());
        sum_row(fixture_name(i), "decode-corrupt-middle", dec_corrupt_middle());
        sum_row(fixture_name(i), "decode-corrupt-end", dec_corrupt_end());
        i += 1;
    }
    return 0;
}

// A u64 printed as unsigned decimal; see bench/bench.goose for why.
fn format_u64(out: u8[>..]&, value: u64) {
    if value == 0 {
        out.push('0');
        return;
    }
    var digits: u8[20] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    var n:      i64    = 0;
    var v = value;
    while v > 0 {
        digits[n] = 48 + ((v % 10) as u8);
        v = v / 10;
        n += 1;
    }
    while n > 0 {
        n -= 1;
        out.append(digits[n..n + 1]);
    }
}

fn sum_row(name: const u8[:], op: const u8[:], value: u64) {
    var out: u8[>..] = [];
    out.append("sum ");
    out.append(name);
    out.push(' ');
    out.append(op);
    out.push(' ');
    format_u64(out, value);
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
        let bad = checksums(false);
        if bad != 0 { exit(1); }
        return;
    }
    // The negative control for the barrier: the same walk with every decoded
    // value zeroed before it is folded.
    if args[..] == "checksum-mutant" {
        let bad = checksums(true);
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
        build_invalid();
        sink += row(fixture_name(i), "encode-reused", batch, ms, enc);
        sink += row(fixture_name(i), "encode-fresh", batch, ms, enc_fresh);
        sink += row(fixture_name(i), "decode-fresh", batch, ms, dec);
        // The competitor's decoder is stateless: `at` is a caller-owned cursor
        // and there is no reader object to reuse, so this cell is not
        // applicable rather than equal to decode-fresh.
        na(fixture_name(i), "decode-reused");
        sink += row(fixture_name(i), "decode-truncated-end", batch, ms, dec_truncated_end);
        sink += row(fixture_name(i), "decode-truncated-start", batch, ms, dec_truncated_start);
        sink += row(fixture_name(i), "decode-truncated-middle", batch, ms, dec_truncated_middle);
        sink += row(fixture_name(i), "decode-corrupt-start", batch, ms, dec_corrupt_start);
        sink += row(fixture_name(i), "decode-corrupt-middle", batch, ms, dec_corrupt_middle);
        sink += row(fixture_name(i), "decode-corrupt-end", batch, ms, dec_corrupt_end);
        i += 1;
    }
    if sink == 0 { write_stderr("bench: empty sink\n"); exit(1); }
}
