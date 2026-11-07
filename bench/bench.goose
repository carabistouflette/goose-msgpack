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

// Drain the token stream. The payload lengths are folded into the sink so the
// reads cannot be optimised away.
fn drain(data: const u8[:]) -> u64 {
    var r = msgpack::Reader { .. };
    if msgpack::init(r, data) != msgpack::Error.None { return 0; }
    var n: u64 = 0;
    while !msgpack::done(r) {
        let token, err = msgpack::next(r);
        if err != msgpack::Error.None { return n + 1; }
        n += 1;
        match token {
            Str s => { n += s.v.len as u64; },
            Bin b => { n += b.v.len as u64; },
            _ => {},
        }
    }
    return n;
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

fn enc() -> u64 {
    g_out.clear();
    let e = encode_plan(g_fixture, g_out);
    if e != msgpack::Error.None { return 0; }
    return g_out.len as u64;
}

fn dec() -> u64 {
    return drain(g_data[..]);
}

fn dec_truncated() -> u64 {
    if g_data.len < 2 { return 0; }
    return drain(g_data[..g_data.len - 1]);
}

fn ::main() {
    var args: u8[>..] = [];
    if arg_count() > 1 { arg(1, args); }
    if args[..] == "verify" {
        let bad = verify();
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
        sink += row(fixture_name(i), "encode", batch, ms, enc);
        sink += row(fixture_name(i), "decode", batch, ms, dec);
        sink += row(fixture_name(i), "decode-truncated", batch, ms, dec_truncated);
        i += 1;
    }
    if sink == 0 { write_stderr("bench: empty sink\n"); exit(1); }
}
