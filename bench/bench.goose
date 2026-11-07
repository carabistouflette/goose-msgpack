// SPDX-License-Identifier: Apache-2.0
// Benchmark harness for goose-msgpack. Prepared, not measured.
//
// The benchmark operator runs the samples serially, with no other process competing
// for the CPU, so this file only has to be correct and reproducible. It never
// runs as part of `make test`.
//
//   goose build -o .build/bench/msgpack-bench bench/bench.goose --cc clang
//   .build/bench/msgpack-bench verify
//   .build/bench/msgpack-bench <batch> <ms>
//
// `verify` prints one `fixture <name> bytes <n> hex <hex>` row per fixture.
// bench/measure.py recomputes the checksums from bench/fixtures.py and fails
// if a single byte differs, so the two harnesses provably encode the same
// value. Timing mode prints `time <name> <op> <iterations> <ns_total>` rows.
//
// Equal contract: bench/bench-competitor.goose builds the same five fixtures
// with Macho0x/goose-msgpack and prints the same rows. The workloads are
// identical; the contracts are not. This harness additionally enforces input,
// output, node, depth, str, bin and container budgets and a full-input
// `finish`, which the competitor has no equivalent of. Those checks are part
// of the contract under test and cannot be removed to make the numbers match.
import msgpack from "..";
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

// The value bench/fixtures.py builds: a goose-task plan manifest, version 1.
fn encode_plan(i: i64, out: u8[>..]&) -> msgpack::Error {
    var w = msgpack::Writer { .. };
    let started = msgpack::init(w);
    if started != msgpack::Error.None { return started; }
    let tasks = fixture_tasks(i);
    let edges = fixture_edges(i);
    let members = fixture_members(i);
    let member_bytes = fixture_member_bytes(i);
    var e = msgpack::map(w, 6);
    if e != msgpack::Error.None { return e; }
    e = msgpack::str(w, "format");
    if e != msgpack::Error.None { return e; }
    e = msgpack::str(w, "goose-task-plan");
    if e != msgpack::Error.None { return e; }
    e = msgpack::str(w, "version");
    if e != msgpack::Error.None { return e; }
    e = msgpack::uint(w, 1);
    if e != msgpack::Error.None { return e; }
    e = msgpack::str(w, "count");
    if e != msgpack::Error.None { return e; }
    e = msgpack::uint(w, tasks as u64);
    if e != msgpack::Error.None { return e; }
    e = msgpack::str(w, "concurrency");
    if e != msgpack::Error.None { return e; }
    var concurrency = tasks / 2;
    if concurrency < 1 { concurrency = 1; }
    e = msgpack::uint(w, concurrency as u64);
    if e != msgpack::Error.None { return e; }
    e = msgpack::str(w, "edges");
    if e != msgpack::Error.None { return e; }
    e = msgpack::array(w, edges);
    if e != msgpack::Error.None { return e; }
    var k: i64 = 0;
    while k < edges {
        e = msgpack::array(w, 2);
        if e != msgpack::Error.None { return e; }
        e = msgpack::uint(w, (k % tasks) as u64);
        if e != msgpack::Error.None { return e; }
        e = msgpack::uint(w, ((k * 7 + 1) % tasks) as u64);
        if e != msgpack::Error.None { return e; }
        k += 1;
    }
    e = msgpack::str(w, "labels");
    if e != msgpack::Error.None { return e; }
    e = msgpack::map(w, members);
    if e != msgpack::Error.None { return e; }
    var m: i64 = 0;
    while m < members {
        var key: u8[>..] = [];
        key.push('k');
        format_int(key, m, 10, 0, ' ');
        e = msgpack::str(w, key[..]);
        if e != msgpack::Error.None { return e; }
        var value: u8[>..] = [];
        var j:     i64     = 0;
        while j < member_bytes {
            value.push('x');
            j += 1;
        }
        e = msgpack::str(w, value[..]);
        if e != msgpack::Error.None { return e; }
        m += 1;
    }
    e = msgpack::finish(w);
    if e != msgpack::Error.None { return e; }
    out.append(msgpack::output(w));
    return msgpack::Error.None;
}

// FNV-1a. A length is not a checksum: two different encodings of the same size
// are indistinguishable to it, and a compiler may delete work whose only
// observable effect is a length it can prove. Folding the bytes makes the
// result depend on every byte the harness produced or consumed.
fn fnv1a(seed: u64, data: const u8[:]) -> u64 {
    var h = seed;
    for i in 0..data.len {
        h = (h ^ data[i]) * 1099511628211;
    }
    return h;
}

const FNV_OFFSET: u64 = 14695981039346656037;

// The token discriminant, so the sink binds the reader's *interpretation* of a
// marker and not only the bytes it happened to consume.
fn kind_of(token: msgpack::Token) -> u64 {
    match token {
        Nil => { return 0; },
        Bool b => { if b.v { return 2; } return 1; },
        Int i => { return 3; },
        Uint u => { return 4; },
        F32 f => { return 5; },
        F64 f => { return 6; },
        Str s => { return 7; },
        Bin b => { return 8; },
        Array a => { return 9; },
        Map m => { return 10; },
        Ext e => { return 11; },
        _ => { return 12; },
    }
}

// Drain the token stream into a caller-owned reader. The sink folds the token
// kind and the exact byte span each token consumed, so a reader that splits the
// input differently, or reinterprets a marker, changes the checksum.
fn drain_into(r: msgpack::Reader&, data: const u8[:]) -> u64 {
    if msgpack::init(r, data) != msgpack::Error.None { return 0; }
    var h:    u64 = FNV_OFFSET;
    var prev: i64 = 0;
    while !msgpack::done(r) {
        let token, err = msgpack::next(r);
        if err != msgpack::Error.None { return h ^ 0xffffffffffffffff; }
        let at = msgpack::consumed(r);
        h = (h ^ kind_of(token)) * 1099511628211;
        h = fnv1a(h, data[prev..at]);
        prev = at;
    }
    h = (h ^ (msgpack::consumed(r) as u64)) * 1099511628211;
    return h;
}

fn drain(data: const u8[:]) -> u64 {
    var r = msgpack::Reader { .. };
    return drain_into(r, data);
}

fn hex(out: u8[>..]&, data: const u8[:]) {
    var digits: u8[16] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
    for i in 0..data.len {
        out.push(digits[(data[i] >> 4) & 0xf]);
        out.push(digits[data[i] & 0xf]);
    }
}

fn line(out: u8[>..]&, a: const u8[:], b: const u8[:], c: const u8[:]) {
    out.append(a);
    out.append(b);
    out.append(c);
    out.push('\n');
}

fn verify() -> i64 {
    var bad: i64 = 0;
    var i:   i64 = 0;
    while i < fixture_count() {
        g_out.clear();
        let e = encode_plan(i, g_out);
        if e != msgpack::Error.None {
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
    emit(name, op, batch, ns);
    return part;
}

fn emit(name: const u8[:], op: const u8[:], batch: i64, ns: i64) {
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
}

// The reader-reusing row. Same measurement loop as `time_batch`, but the reader
// is owned by the caller so its depth stack survives across iterations.
fn row_reused(r: msgpack::Reader&, name: const u8[:], op: const u8[:], batch: i64, ms: i64) -> u64 {
    var sink: u64 = 0;
    var k:    i64 = 0;
    while k < batch {
        sink += dec_reused(r);
        k += 1;
    }
    var n:  i64 = 0;
    var dt: i64 = 0;
    let end = clock_ns() + ms * 1000000;
    while true {
        let t0 = clock_ns();
        k = 0;
        while k < batch {
            sink += dec_reused(r);
            k += 1;
        }
        dt += clock_ns() - t0;
        n += batch;
        if clock_ns() >= end { break; }
    }
    emit(name, op, batch, dt / n);
    return sink;
}

// Reused output buffer: the writer appends into the same allocation every
// iteration, which is what a caller streaming many documents does.
fn enc() -> u64 {
    g_out.clear();
    let e = encode_plan(g_fixture, g_out);
    if e != msgpack::Error.None { return 0; }
    return fnv1a(FNV_OFFSET, g_out[..]);
}

// Fresh output buffer: one allocation per document, which is what a caller
// producing one message per request does. The two rows separate allocator cost
// from encoder cost.
fn enc_fresh() -> u64 {
    var out: u8[>..] = [];
    let e = encode_plan(g_fixture, out);
    if e != msgpack::Error.None { return 0; }
    return fnv1a(FNV_OFFSET, out[..]);
}

// Fresh reader: the 2 KiB depth stack is a new value each call.
fn dec() -> u64 {
    return drain(g_data[..]);
}

// Reused reader: the same depth stack is re-initialised each call. The reader
// is a local of the caller, not a global, because a global reader would hold a
// reference into `g_data` across the `clear()` that rebuilds it for the next
// fixture -- which the borrow checker rejects, correctly.
fn dec_reused(r: msgpack::Reader&) -> u64 {
    return drain_into(r, g_data[..]);
}

fn dec_truncated() -> u64 {
    if g_data.len < 2 { return 0; }
    return drain(g_data[..g_data.len - 1]);
}

// One `sum <fixture> <op> <value>` row per measured row, computed once. The
// runner compares these between the baseline and the optimised binary: a
// speed-up that changes a checksum is a wrong answer, not a faster one.
fn checksums() -> i64 {
    var bad: i64 = 0;
    var i:   i64 = 0;
    while i < fixture_count() {
        g_fixture = i;
        g_out.clear();
        let e = encode_plan(i, g_out);
        if e != msgpack::Error.None {
            write_stderr("FAIL encode ");
            write_stderr(fixture_name(i));
            write_stderr("\n");
            return 1;
        }
        g_data.clear();
        g_data.append(g_out[..]);
        var r = msgpack::Reader { .. };
        sum_row(fixture_name(i), "encode-reused", enc());
        sum_row(fixture_name(i), "encode-fresh", enc_fresh());
        sum_row(fixture_name(i), "decode-fresh", dec());
        sum_row(fixture_name(i), "decode-reused", dec_reused(r));
        sum_row(fixture_name(i), "decode-truncated", dec_truncated());
        i += 1;
    }
    return bad;
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
        write_stderr("usage: msgpack-bench [verify | <batch> <ms>]\n");
        exit(2);
    }
    var sink: u64 = 0;
    var i:    i64 = 0;
    while i < fixture_count() {
        g_fixture = i;
        g_out.clear();
        let e = encode_plan(i, g_out);
        if e != msgpack::Error.None {
            write_stderr("FAIL encode ");
            write_stderr(fixture_name(i));
            write_stderr("\n");
            exit(1);
        }
        g_data.clear();
        g_data.append(g_out[..]);
        // Declared after `g_data` is final for this fixture and dropped before
        // the next `clear()`, so the reader never outlives its input.
        var r = msgpack::Reader { .. };
        sink += row(fixture_name(i), "encode-reused", batch, ms, enc);
        sink += row(fixture_name(i), "encode-fresh", batch, ms, enc_fresh);
        sink += row(fixture_name(i), "decode-fresh", batch, ms, dec);
        sink += row_reused(r, fixture_name(i), "decode-reused", batch, ms);
        sink += row(fixture_name(i), "decode-truncated", batch, ms, dec_truncated);
        i += 1;
    }
    if sink == 0 { write_stderr("bench: empty sink\n"); exit(1); }
}
