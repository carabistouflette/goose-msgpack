// SPDX-License-Identifier: Apache-2.0
// Fuzz target for the bounded MessagePack reader and writer.
//
// This calls the real `msgpack::Reader` and `msgpack::Writer`, not a model of
// them. Every assertion below is a guarantee stated in docs/api.md, so a
// violated assertion is a contract defect and not a fuzzer artefact. The
// driver in tests/fuzz.c feeds arbitrary bytes and keeps the input that
// aborted; scripts/fuzz.py builds it with ASan and UBSan.
//
// The target is deliberately a *property* test rather than a crash hunt: for
// every input it checks the state invariants, the payload aliasing, the
// canonical fixed point, and that each budget fails at exactly one unit below
// the value the input needs.
import msgpack from "..";
import std;

// What one full drain of the input observed. The maxima are what the budget
// checks below reproduce one unit lower.
struct Scan {
    tokens:        i64            = 0,
    max_depth:     i64            = 0,
    max_container: i64            = 0,
    max_str:       i64            = 0,
    max_bin:       i64            = 0,
    consumed:      i64            = 0,
    error:         msgpack::Error = msgpack::Error.None,
    finish:        msgpack::Error = msgpack::Error.None,
}

// Drain `data` under `limits`, asserting the per-token state invariants.
fn scan(data: const u8[:], limits: msgpack::Limits) -> Scan {
    var result = Scan { .. };
    var reader = msgpack::Reader { .. };
    let error = msgpack::init(reader, data, limits);
    if error != msgpack::Error.None {
        result.error = error;
        return result;
    }
    while !msgpack::done(reader) {
        let token, step = msgpack::next(reader);
        if step != msgpack::Error.None {
            result.error = step;
            result.consumed = msgpack::consumed(reader);
            return result;
        }
        result.tokens += 1;
        let at = msgpack::consumed(reader);
        let depth = msgpack::depth(reader);
        let remaining = msgpack::remaining(reader);
        // State invariants: the cursor never passes the input, the depth never
        // passes the budget, and `remaining` is -1 exactly at the top level.
        assert(at >= 0 && at <= data.len);
        assert(depth >= 0 && depth <= limits.max_depth);
        assert(msgpack::offset(reader) >= 0 && msgpack::offset(reader) <= data.len);
        if depth == 0 {
            assert(remaining == -1);
        } else {
            assert(remaining >= 1);
        }
        if depth > result.max_depth { result.max_depth = depth; }
        // Payload aliasing: a Str, Bin or Ext payload is a view into the input
        // that ends exactly at the cursor. The reader copies nothing.
        match token {
            Nil => {},
            Bool b => {},
            Int i => {},
            Uint u => {},
            F32 f => {},
            F64 f => {},
            Str s => {
                assert(s.v.len <= limits.max_str_bytes);
                assert(s.v == data[at - s.v.len..at]);
                if s.v.len > result.max_str { result.max_str = s.v.len; }
            },
            Bin b => {
                assert(b.v.len <= limits.max_bin_bytes);
                assert(b.v == data[at - b.v.len..at]);
                if b.v.len > result.max_bin { result.max_bin = b.v.len; }
            },
            Ext e => {
                assert(e.v.len <= limits.max_bin_bytes);
                assert(e.v == data[at - e.v.len..at]);
                if e.v.len > result.max_bin { result.max_bin = e.v.len; }
            },
            Array a => {
                assert(a.count >= 0 && a.count <= limits.max_container_len);
                // Every element needs at least one byte. A count the input
                // cannot hold is rejected at its header, never handed to the
                // caller to loop over.
                assert(a.count <= data.len - at);
                if a.count > result.max_container { result.max_container = a.count; }
            },
            Map m => {
                assert(m.count >= 0 && m.count <= limits.max_container_len);
                // A pair needs two bytes, so the same bound is half the rest.
                assert(m.count <= (data.len - at) / 2);
                if m.count > result.max_container { result.max_container = m.count; }
            },
        }
    }
    result.finish = msgpack::finish(reader);
    result.consumed = msgpack::consumed(reader);
    return result;
}

// Write one token through the public writer API.
fn write_token(out: msgpack::Writer&, token: msgpack::Token) -> msgpack::Error {
    match token {
        Nil => { return msgpack::nil(out); },
        Bool b => { return msgpack::boolean(out, b.v); },
        Int i => { return msgpack::int(out, i.v); },
        Uint u => { return msgpack::uint(out, u.v); },
        F32 f => { return msgpack::float32(out, f.v); },
        F64 f => { return msgpack::float64(out, f.v); },
        Str s => { return msgpack::str(out, s.v); },
        Bin b => { return msgpack::bin(out, b.v); },
        Array a => { return msgpack::array(out, a.count); },
        Map m => { return msgpack::map(out, m.count); },
        Ext e => { return msgpack::ext(out, e.typ, e.v); },
    }
}

// Decode `data` and re-encode the token stream into `out`.
fn encode_stream(data: const u8[:], out: msgpack::Writer&, limits: msgpack::Limits) -> msgpack::Error {
    var reader = msgpack::Reader { .. };
    let error = msgpack::init(reader, data, limits);
    if error != msgpack::Error.None { return error; }
    while !msgpack::done(reader) {
        let token, step = msgpack::next(reader);
        if step != msgpack::Error.None { return step; }
        let written = write_token(out, token);
        if written != msgpack::Error.None { return written; }
    }
    return msgpack::finish(reader);
}

export fn fuzz_parse(data: const u8[:]) -> i64 {
    let limits = msgpack::Limits { .. };
    let first = scan(data, limits);
    if first.error != msgpack::Error.None { return 1; }
    if first.finish != msgpack::Error.None { return 2; }
    // `finish` returned None: exactly one value, and the whole input was used.
    assert(first.consumed == data.len);

    // Canonical re-encoding: a fixed point, and never longer than the input.
    var canonical = msgpack::Writer { .. };
    assert(msgpack::init(canonical) == msgpack::Error.None);
    assert(encode_stream(data, canonical, limits) == msgpack::Error.None);
    assert(msgpack::finish(canonical) == msgpack::Error.None);
    let bytes = msgpack::output(canonical);
    assert(bytes.len == msgpack::written(canonical));
    assert(bytes.len <= data.len);

    var again = msgpack::Writer { .. };
    assert(msgpack::init(again) == msgpack::Error.None);
    assert(encode_stream(bytes, again, limits) == msgpack::Error.None);
    assert(msgpack::finish(again) == msgpack::Error.None);
    assert(msgpack::output(again) == bytes);

    // `skip` consumes exactly one complete value, children included.
    var skipper = msgpack::Reader { .. };
    assert(msgpack::init(skipper, data) == msgpack::Error.None);
    assert(msgpack::skip(skipper) == msgpack::Error.None);
    assert(msgpack::consumed(skipper) == data.len);
    assert(msgpack::done(skipper));
    assert(msgpack::finish(skipper) == msgpack::Error.None);

    // A `next` after the value completed is InvalidState, and it poisons the
    // reader with that same error rather than a different one.
    let _, after = msgpack::next(skipper);
    assert(after == msgpack::Error.InvalidState);
    let _, after_again = msgpack::next(skipper);
    assert(after_again == msgpack::Error.InvalidState);

    // Input budget: one byte less than the input is InputLimit at init.
    if data.len >= 1 {
        var tight = msgpack::Limits { .. };
        tight.max_input_bytes = data.len - 1;
        var reader = msgpack::Reader { .. };
        assert(msgpack::init(reader, data, tight) == msgpack::Error.InputLimit);
    }
    // Node budget: one node less than the stream must fail with NodeLimit.
    if first.tokens >= 1 {
        var tight = msgpack::Limits { .. };
        tight.max_nodes = first.tokens - 1;
        assert(scan(data, tight).error == msgpack::Error.NodeLimit);
    }
    // Depth budget: one level less than the deepest open container.
    if first.max_depth >= 1 {
        var tight = msgpack::Limits { .. };
        tight.max_depth = first.max_depth - 1;
        assert(scan(data, tight).error == msgpack::Error.DepthLimit);
    }
    // Container length budget: one element less than the widest container.
    if first.max_container >= 1 {
        var tight = msgpack::Limits { .. };
        tight.max_container_len = first.max_container - 1;
        assert(scan(data, tight).error == msgpack::Error.ContainerLimit);
    }
    // String budget: one byte less than the longest str payload.
    if first.max_str >= 1 {
        var tight = msgpack::Limits { .. };
        tight.max_str_bytes = first.max_str - 1;
        assert(scan(data, tight).error == msgpack::Error.StrLimit);
    }
    // Binary and extension budget: one byte less than the longest payload.
    if first.max_bin >= 1 {
        var tight = msgpack::Limits { .. };
        tight.max_bin_bytes = first.max_bin - 1;
        assert(scan(data, tight).error == msgpack::Error.BinLimit);
    }
    // Output budget: one byte less must fail with OutputLimit, and the bytes
    // already written must be a prefix of the full encoding. A writer that
    // appended past the budget, or that lost a byte, breaks this.
    if bytes.len >= 1 {
        var tight = msgpack::Limits { .. };
        tight.max_output_bytes = bytes.len - 1;
        var partial = msgpack::Writer { .. };
        assert(msgpack::init(partial, tight) == msgpack::Error.None);
        assert(encode_stream(data, partial, limits) == msgpack::Error.OutputLimit);
        let kept = msgpack::written(partial);
        assert(kept >= 0 && kept <= bytes.len - 1);
        assert(msgpack::output(partial) == bytes[..kept]);
    }
    return 0;
}

// The driver calls this with 0 when the input is the self-test probe. It must
// abort, so libFuzzer retains the exact bytes: that proves the Goose assertion
// path is wired to the fuzzer and not swallowed.
export fn fuzz_assertion_probe(value: i64) { assert(value != 0); }

fn main() {}
