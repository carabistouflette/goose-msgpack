// SPDX-License-Identifier: Apache-2.0
// Benchmark harness for goose-msgpack.
//
// The benchmark operator runs the samples serially, with no other process
// competing for the CPU, so this file only has to be correct and reproducible.
// It never runs as part of `make test`.
//
//   goose build -o .build/bench/msgpack-bench bench/bench.goose --cc clang
//   .build/bench/msgpack-bench verify
//   .build/bench/msgpack-bench checksum
//   .build/bench/msgpack-bench <batch> <ms>
//
// `verify` prints one `fixture <name> bytes <n> hex <hex>` row per fixture.
// `checksum` prints one `sum <fixture> <op> <value>` row per measured row,
// computed once, outside any timing. Timing mode prints
// `time <name> <op> <iterations> <ns_total>` rows.
//
// Checksums outside the loop, barrier inside it
// ---------------------------------------------
//
// An earlier version of this harness folded a byte-at-a-time FNV-1a over every
// produced and consumed byte *inside* the timed loop. A profile showed that
// fold taking 45% of the samples: the harness was measuring its own checksum,
// and a change to the codec would have been diluted by a constant.
//
// The two jobs are now separate, which is what they always were:
//
// - **Correctness** is the full byte-wise FNV-1a content checksum, computed
//   once per row by `checksum` mode, outside any timing. `bench/measure.py`
//   runs it before and after the timing passes and refuses to compare two runs
//   whose checksums differ, so a faster wrong answer is rejected rather than
//   reported.
// - **Anti-elimination** is a cheap barrier inside the loop: the token
//   discriminant and the exact byte span of every token, plus one word-wise
//   `std::hash` of the whole document. It depends on every byte and on the
//   parse, so the compiler cannot delete the work, and it costs about an eighth
//   of the byte-wise fold it replaces.
//
// The residual risk is a compiler proving that only the last iteration's bytes
// matter and collapsing the loop. That is checked empirically: the measured
// time per row scales with the fixture size and with the token count, and a
// collapsed loop would not. The `checksum` mode is the independent proof that
// the work happened.
//
// Equal contract: bench/bench-competitor.goose builds the same five fixtures
// with Macho0x/goose-msgpack and prints the same rows. The workloads are
// identical; the contracts are not. This harness additionally enforces input,
// output, node, depth, str, bin and container budgets and a full-input
// `finish`, which the competitor has no equivalent of. Those checks are part of
// the contract under test and cannot be removed to make the numbers match.
import msgpack from "..";
import std;
import os;

var g_data:    u8[>..] = [];
var g_out:     u8[>..] = [];
var g_fixture: i64     = 0;

// The invalid inputs, built once per fixture so the timed loop measures the
// reader and not the buffer construction.
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

// FNV-1a, byte at a time. Used only by `checksum` mode, outside any timing, so
// its cost does not matter and its exactness does.
fn fnv1a(seed: u64, data: const u8[:]) -> u64 {
    var h = seed;
    for i in 0..data.len {
        h = (h ^ data[i]) * 1099511628211;
    }
    return h;
}

const FNV_OFFSET: u64 = 14695981039346656037;

// The token discriminant, so the barrier binds the reader's *interpretation* of
// a marker and not only the bytes it happened to consume.
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
    }
}

// The error code, so a refusal is distinguishable from a different refusal and
// from an acceptance. A library that accepted a corrupted document would fold a
// different value here.
fn error_code(e: msgpack::Error) -> u64 {
    if e == msgpack::Error.None { return 0; }
    if e == msgpack::Error.InvalidOptions { return 1; }
    if e == msgpack::Error.InvalidState { return 2; }
    if e == msgpack::Error.Truncated { return 3; }
    if e == msgpack::Error.Reserved { return 4; }
    if e == msgpack::Error.DepthLimit { return 5; }
    if e == msgpack::Error.NodeLimit { return 6; }
    if e == msgpack::Error.InputLimit { return 7; }
    if e == msgpack::Error.OutputLimit { return 8; }
    if e == msgpack::Error.StrLimit { return 9; }
    if e == msgpack::Error.BinLimit { return 10; }
    if e == msgpack::Error.ContainerLimit { return 11; }
    if e == msgpack::Error.TrailingBytes { return 12; }
    if e == msgpack::Error.Unbalanced { return 13; }
    return 14;
}

// Drain the token stream into a caller-owned reader. The barrier folds the
// token kind and the exact byte span each token consumed, then one word-wise
// hash of the whole document, so it depends on every byte and on the parse.
// Big-endian bits at `at`, used to recover a float's wire pattern.
fn be_bits(data: const u8[:], at: i64, width: i64) -> u64 {
    var v: u64 = 0;
    var i: i64 = 0;
    while i < width {
        v = (v << 8) | data[at + i];
        i += 1;
    }
    return v;
}

// The first and last byte of a payload, so a fold depends on the content and
// not only on its length.
fn sample(payload: const u8[:]) -> u64 {
    if payload.len == 0 { return 0; }
    return ((payload[0] as u64) << 8) | payload[payload.len - 1];
}

// Fold one token into the running hash: its kind, the exact wire span it
// consumed, and **the value the reader decoded**.
//
// The value is the part that matters. Folding only the kind and the span leaves
// the checksum unchanged for a reader that returns the right token type at the
// right offset with the wrong value: `Token.Uint { v: 0 }` after reading a
// `0xcd` header consumes the same bytes and reports the same kind, so a
// benchmark could measure a broken decoder and still agree with the reference.
// `mutant` zeroes the value before folding, which is the negative control for
// exactly that failure.
fn fold_token(h: u64, token: msgpack::Token, data: const u8[:],
              prev: i64, at: i64, mutant: bool) -> u64 {
    var g = h;
    g = (g ^ kind_of(token)) * 1099511628211;
    g = (g ^ (at - prev) as u64) * 1099511628211;

    var value: u64 = 0;
    var extra: u64 = 0;
    match token {
        Nil => { value = 0; },
        Bool b => { if b.v { value = 1; } },
        Int i => { value = i.v as u64; },
        Uint u => { value = u.v; },
        F32 f => {
            // The wire bits are the value. The equality bit makes the fold
            // depend on the decoded float and not only on the bytes it came
            // from, so a reader that returns a different float is caught.
            let wire = be_bits(data, prev + 1, 4);
            value = wire;
            if f.v != binary::f32_of_bits(wire as u32) { extra = 0xffff; }
        },
        F64 f => {
            let wire = be_bits(data, prev + 1, 8);
            value = wire;
            if f.v != binary::f64_of_bits(wire) { extra = 0xffff; }
        },
        Str s => { value = s.v.len as u64; extra = sample(s.v); },
        Bin b => { value = b.v.len as u64; extra = sample(b.v); },
        Array a => { value = a.count as u64; },
        Map m => { value = m.count as u64; },
        Ext e => {
            value = (e.typ as u64) << 32 | (e.v.len as u64);
            extra = sample(e.v);
        },
    }
    if mutant {
        value = 0;
        extra = 0;
    }
    g = (g ^ value) * 1099511628211;
    g = (g ^ extra) * 1099511628211;
    return g;
}

fn drain_into(r: msgpack::Reader&, data: const u8[:]) -> u64 {
    if msgpack::init(r, data) != msgpack::Error.None { return 0; }
    var h:    u64 = FNV_OFFSET;
    var prev: i64 = 0;
    while !msgpack::done(r) {
        let token, err = msgpack::next(r);
        if err != msgpack::Error.None { return h ^ (0x100 + error_code(err)); }
        let at = msgpack::consumed(r);
        h = fold_token(h, token, data, prev, at, false);
        prev = at;
    }
    let finished = msgpack::finish(r);
    if finished != msgpack::Error.None { return h ^ (0x200 + error_code(finished)); }
    return h ^ hash(data);
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

        // The invalid variants are published too. A comparator that builds
        // different invalid inputs is not measuring the same rows, and a
        // difference in the refusal path would be read as a performance
        // difference. Publishing the bytes makes that checkable instead of
        // assumed.
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

// Returns the raw totals, never a pre-divided rate. Dividing here would round
// to whole nanoseconds before the caller sees the number, and a caller that
// then divided by the batch again would be off by the batch size. The output
// contract is `time <fixture> <op> <n> <dt_ns>`: total elapsed nanoseconds for
// n calls, and the reader divides exactly once.
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
    emit(name, op, n, dt);
    return part;
}

// `time <fixture> <op> <n> <dt_ns>`. Both numbers are totals; the reader
// divides once. Printing a rate here and a batch there invites the reader to
// divide twice, which is a silent factor-of-batch error.
fn emit(name: const u8[:], op: const u8[:], n: i64, dt: i64) {
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
    emit(name, op, n, dt);
    return sink;
}

// Reused output buffer: the writer appends into the same allocation every
// iteration, which is what a caller streaming many documents does.
fn enc() -> u64 {
    g_out.clear();
    let e = encode_plan(g_fixture, g_out);
    if e != msgpack::Error.None { return 0; }
    return hash(g_out[..]);
}

// Fresh output buffer: one allocation per document, which is what a caller
// producing one message per request does. The two rows separate allocator cost
// from encoder cost.
fn enc_fresh() -> u64 {
    var out: u8[>..] = [];
    let e = encode_plan(g_fixture, out);
    if e != msgpack::Error.None { return 0; }
    return hash(out[..]);
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

fn dec_truncated_end() -> u64 { return drain(g_truncated_end[..]); }
fn dec_truncated_start() -> u64 { return drain(g_truncated_start[..]); }
fn dec_truncated_middle() -> u64 { return drain(g_truncated_middle[..]); }
fn dec_corrupt_start() -> u64 { return drain(g_corrupt_start[..]); }
fn dec_corrupt_middle() -> u64 { return drain(g_corrupt_middle[..]); }
fn dec_corrupt_end() -> u64 { return drain(g_corrupt_end[..]); }

// Build the invalid inputs for the current fixture. Called once per fixture,
// outside the timed loop.
fn build_invalid() {
    let n = g_data.len;
    g_truncated_end.clear();
    g_truncated_start.clear();
    g_truncated_middle.clear();
    g_corrupt_start.clear();
    g_corrupt_middle.clear();
    g_corrupt_end.clear();
    if n < 4 { return; }
    // Truncation at the end, the start and the middle. Each removes one byte,
    // so the document is one byte short of a complete value.
    g_truncated_end.append(g_data[..n - 1]);
    g_truncated_start.append(g_data[1..]);
    let middle = n / 2;
    g_truncated_middle.append(g_data[..middle]);
    g_truncated_middle.append(g_data[middle + 1..]);
    // The reserved marker 0xc1 at the start, the middle and the end. A decoder
    // that accepts it is wrong, and its checksum says so.
    g_corrupt_start.append(g_data[..]);
    g_corrupt_start[0] = 0xc1;
    g_corrupt_middle.append(g_data[..]);
    g_corrupt_middle[middle] = 0xc1;
    g_corrupt_end.append(g_data[..]);
    g_corrupt_end[n - 1] = 0xc1;
}

// One `sum <fixture> <op> <value>` row per measured row, computed once, outside
// any timing. The runner compares these between the baseline and the optimised
// binary: a speed-up that changes a checksum is a wrong answer, not a faster
// one.
fn checksums(mutant: bool) -> i64 {
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
        build_invalid();
        var r = msgpack::Reader { .. };
        sum_row(fixture_name(i), "encode-reused", fnv1a(FNV_OFFSET, g_out[..]));
        sum_row(fixture_name(i), "encode-fresh", fnv1a(FNV_OFFSET, g_out[..]));
        sum_row(fixture_name(i), "decode-fresh", content_sum(g_data[..], mutant));
        sum_row(fixture_name(i), "decode-reused", content_sum(g_data[..], mutant));
        sum_row(fixture_name(i), "decode-truncated-end", content_sum(g_truncated_end[..], mutant));
        sum_row(fixture_name(i), "decode-truncated-start", content_sum(g_truncated_start[..], mutant));
        sum_row(fixture_name(i), "decode-truncated-middle", content_sum(g_truncated_middle[..], mutant));
        sum_row(fixture_name(i), "decode-corrupt-start", content_sum(g_corrupt_start[..], mutant));
        sum_row(fixture_name(i), "decode-corrupt-middle", content_sum(g_corrupt_middle[..], mutant));
        sum_row(fixture_name(i), "decode-corrupt-end", content_sum(g_corrupt_end[..], mutant));
        i += 1;
    }
    return bad;
}

// The full content checksum of one decode: the token kind and the exact byte
// span of every token, byte-wise, plus the verdict. Computed once, outside any
// timing, so it can afford to be exact.
fn content_sum(data: const u8[:], mutant: bool) -> u64 {
    var r = msgpack::Reader { .. };
    if msgpack::init(r, data) != msgpack::Error.None { return 0; }
    var h:    u64 = FNV_OFFSET;
    var prev: i64 = 0;
    while !msgpack::done(r) {
        let token, err = msgpack::next(r);
        if err != msgpack::Error.None { return h ^ (0x100 + error_code(err)); }
        let at = msgpack::consumed(r);
        // The decoded value, then the exact bytes of the span. The bytes alone
        // would not notice a wrong value; the value alone would not notice a
        // wrong span.
        h = fold_token(h, token, data, prev, at, mutant);
        h = fnv1a(h, data[prev..at]);
        prev = at;
    }
    let finished = msgpack::finish(r);
    if finished != msgpack::Error.None { return h ^ (0x200 + error_code(finished)); }
    return h ^ (msgpack::consumed(r) as u64);
}

// A u64 printed as unsigned decimal. format_int takes a signed value, so a
// checksum with the high bit set would print negative; a checksum is an
// unsigned 64-bit value and has to print as one, or the same bytes hash to two
// different-looking numbers across implementations.
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
    // value zeroed before it is folded. Every decode row must differ from the
    // `checksum` mode, or the checksum does not depend on the values and a
    // reader that returned the wrong value would pass.
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
        write_stderr("usage: msgpack-bench [verify | checksum | checksum-mutant | <batch> <ms>]\n");
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
        build_invalid();
        // Declared after `g_data` is final for this fixture and dropped before
        // the next `clear()`, so the reader never outlives its input.
        var r = msgpack::Reader { .. };
        sink += row(fixture_name(i), "encode-reused", batch, ms, enc);
        sink += row(fixture_name(i), "encode-fresh", batch, ms, enc_fresh);
        sink += row(fixture_name(i), "decode-fresh", batch, ms, dec);
        sink += row_reused(r, fixture_name(i), "decode-reused", batch, ms);
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
