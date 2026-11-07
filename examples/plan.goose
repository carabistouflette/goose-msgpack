// SPDX-License-Identifier: Apache-2.0
// A bounded build-plan manifest, the handoff goose-task's `start` accepts.
//
// goose-task (https://github.com/carabistouflette/goose-task) takes
// `start(scheduler, concurrency, edges, count, limits)`, where `count` is the
// task count and each `Edge { before, after }` is a prerequisite pair. A planner
// and a runner in separate processes need those five numbers on the wire. This
// example writes them as one MessagePack map, reads them back under budgets,
// rejects a manifest that is not exactly one value, and validates the plan
// before anything is scheduled.
//
// Wire contract, version 1:
//
//   map(5) {
//     "format":      str  "goose-task-plan"
//     "version":     uint 1
//     "count":       uint task count, 0..65536
//     "concurrency": uint 1..count
//     "edges":       array of array(2) { uint before, uint after }
//   }
//
// Unknown members are skipped, so a later version can add fields. A missing or
// mistyped member is an error, not a default.
import msgpack from "..";
import std;
import os;

const FORMAT_NAME: const u8[:] = "goose-task-plan";
const VERSION:     i64         = 1;
const MAX_TASKS:   i64         = 65536;
const MAX_EDGES:   i64         = 1048576;

enum Error {
    None,
    Codec,
    NotAMap,
    MissingMember,
    WrongType,
    WrongFormat,
    WrongVersion,
    TaskCount,
    Concurrency,
    EdgeCount,
    EdgeIndex,
    SelfLoop,
}

struct Plan {
    count:       i64      = 0,
    concurrency: i64      = 1,
    edges:       i64[>..] = [],
}

fn edge_count(plan: const Plan&) -> i64 { return plan.edges.len / 2; }

fn encode_plan(writer: msgpack::Writer&, plan: const Plan&) -> msgpack::Error {
    var error = msgpack::map(writer, 5);
    if error != msgpack::Error.None { return error; }
    error = msgpack::str(writer, "format");
    if error != msgpack::Error.None { return error; }
    error = msgpack::str(writer, FORMAT_NAME);
    if error != msgpack::Error.None { return error; }
    error = msgpack::str(writer, "version");
    if error != msgpack::Error.None { return error; }
    error = msgpack::int(writer, VERSION);
    if error != msgpack::Error.None { return error; }
    error = msgpack::str(writer, "count");
    if error != msgpack::Error.None { return error; }
    error = msgpack::int(writer, plan.count);
    if error != msgpack::Error.None { return error; }
    error = msgpack::str(writer, "concurrency");
    if error != msgpack::Error.None { return error; }
    error = msgpack::int(writer, plan.concurrency);
    if error != msgpack::Error.None { return error; }
    error = msgpack::str(writer, "edges");
    if error != msgpack::Error.None { return error; }
    error = msgpack::array(writer, edge_count(plan));
    if error != msgpack::Error.None { return error; }
    for i in edge_count(plan) {
        error = msgpack::array(writer, 2);
        if error != msgpack::Error.None { return error; }
        error = msgpack::int(writer, plan.edges[i * 2]);
        if error != msgpack::Error.None { return error; }
        error = msgpack::int(writer, plan.edges[i * 2 + 1]);
        if error != msgpack::Error.None { return error; }
    }
    return msgpack::Error.None;
}

// Read one unsigned member, rejecting a negative or oversized value.
fn member_uint(reader: msgpack::Reader&, out: i64&) -> Error {
    let token, error = msgpack::next(reader);
    if error != msgpack::Error.None { return Error.Codec; }
    let value, ok = msgpack::as_u64(token);
    if !ok { return Error.WrongType; }
    if value > 0x7fffffffffffffff { return Error.WrongType; }
    out = value as i64;
    return Error.None;
}

fn decode_plan(reader: msgpack::Reader&, plan: Plan&) -> Error {
    let head, error = msgpack::next(reader);
    if error != msgpack::Error.None { return Error.Codec; }
    if msgpack::count(head) < 0 { return Error.NotAMap; }
    match head {
        Map _ => {},
        _ => { return Error.NotAMap; },
    }
    var seen_format = false;
    var seen_version = false;
    var seen_count = false;
    var seen_concurrency = false;
    var seen_edges = false;
    for pair in msgpack::count(head) {
        let key, key_error = msgpack::next(reader);
        if key_error != msgpack::Error.None { return Error.Codec; }
        let name = msgpack::text(key);
        if name == "format" {
            let value, value_error = msgpack::next(reader);
            if value_error != msgpack::Error.None { return Error.Codec; }
            if msgpack::text(value) != FORMAT_NAME { return Error.WrongFormat; }
            seen_format = true;
        } else if name == "version" {
            var version: i64 = 0;
            let version_error = member_uint(reader, version);
            if version_error != Error.None { return version_error; }
            if version != VERSION { return Error.WrongVersion; }
            seen_version = true;
        } else if name == "count" {
            let count_error = member_uint(reader, plan.count);
            if count_error != Error.None { return count_error; }
            seen_count = true;
        } else if name == "concurrency" {
            let concurrency_error = member_uint(reader, plan.concurrency);
            if concurrency_error != Error.None { return concurrency_error; }
            seen_concurrency = true;
        } else if name == "edges" {
            let edges, edges_error = msgpack::next(reader);
            if edges_error != msgpack::Error.None { return Error.Codec; }
            let pairs = msgpack::count(edges);
            if pairs < 0 { return Error.WrongType; }
            if pairs > MAX_EDGES { return Error.EdgeCount; }
            for i in pairs {
                let pair, pair_error = msgpack::next(reader);
                if pair_error != msgpack::Error.None { return Error.Codec; }
                if msgpack::count(pair) != 2 { return Error.WrongType; }
                var before: i64 = 0;
                var after:  i64 = 0;
                let before_error = member_uint(reader, before);
                if before_error != Error.None { return before_error; }
                let after_error = member_uint(reader, after);
                if after_error != Error.None { return after_error; }
                plan.edges.push(before);
                plan.edges.push(after);
            }
            seen_edges = true;
        } else {
            // A member this version does not know: skip it whole.
            let skip_error = msgpack::skip(reader);
            if skip_error != msgpack::Error.None { return Error.Codec; }
        }
    }
    if !seen_format || !seen_version || !seen_count || !seen_concurrency || !seen_edges {
        return Error.MissingMember;
    }
    return Error.None;
}

// The checks goose-task performs before it builds a graph.
fn validate(plan: const Plan&) -> Error {
    if plan.count < 0 || plan.count > MAX_TASKS { return Error.TaskCount; }
    if plan.concurrency < 1 || plan.concurrency > plan.count { return Error.Concurrency; }
    if edge_count(plan) > MAX_EDGES { return Error.EdgeCount; }
    for i in edge_count(plan) {
        let before = plan.edges[i * 2];
        let after = plan.edges[i * 2 + 1];
        if before < 0 || before >= plan.count || after < 0 || after >= plan.count {
            return Error.EdgeIndex;
        }
        if before == after { return Error.SelfLoop; }
    }
    return Error.None;
}

fn describe(plan: const Plan&) -> u8[>..] {
    var out: u8[>..] = [];
    format(out, "plan v", VERSION, ": ", plan.count, " tasks, concurrency ",
           plan.concurrency, ", ", edge_count(plan), " edges");
    for i in edge_count(plan) {
        format(out, " ", plan.edges[i * 2], "->", plan.edges[i * 2 + 1]);
    }
    return out;
}

fn main() {
    // A four-task plan: 0 and 1 are independent, 2 needs both, 3 needs 2.
    var plan = Plan { count: 4, concurrency: 2, edges: [0, 2, 1, 2, 2, 3] };
    var writer = msgpack::Writer { .. };
    var limits = msgpack::Limits { .. };
    limits.max_input_bytes = 65536;
    limits.max_output_bytes = 65536;
    limits.max_nodes = 4096;
    limits.max_depth = 8;
    limits.max_container_len = 4096;
    var error = msgpack::init(writer, limits);
    if error != msgpack::Error.None { write_stderr(str("writer init: ", error, "\n")); exit(1); }
    error = encode_plan(writer, plan);
    if error != msgpack::Error.None { write_stderr(str("encode: ", error, "\n")); exit(1); }
    error = msgpack::finish(writer);
    if error != msgpack::Error.None { write_stderr(str("encode finish: ", error, "\n")); exit(1); }
    let wire = msgpack::output(writer);
    print("manifest: ", wire.len, " bytes");

    // The runner side: decode under the same budgets and require one value.
    var reader = msgpack::Reader { .. };
    var received = Plan { .. };
    error = msgpack::init(reader, wire, limits);
    if error != msgpack::Error.None { write_stderr(str("reader init: ", error, "\n")); exit(1); }
    let plan_error = decode_plan(reader, received);
    if plan_error != Error.None { write_stderr(str("decode: ", plan_error, "\n")); exit(1); }
    error = msgpack::finish(reader);
    if error != msgpack::Error.None { write_stderr(str("trailing bytes: ", error, "\n")); exit(1); }
    let validation = validate(received);
    if validation != Error.None { write_stderr(str("invalid plan: ", validation, "\n")); exit(1); }
    print(describe(received));

    // A manifest with one byte appended is rejected, not silently accepted.
    var padded: u8[>..] = [];
    padded.append(wire);
    padded.push(0x00);
    var strict = msgpack::Reader { .. };
    var ignored = Plan { .. };
    error = msgpack::init(strict, padded, limits);
    if error != msgpack::Error.None { write_stderr(str("reader init: ", error, "\n")); exit(1); }
    let padded_error = decode_plan(strict, ignored);
    if padded_error != Error.None { write_stderr(str("decode: ", padded_error, "\n")); exit(1); }
    error = msgpack::finish(strict);
    if error != msgpack::Error.TrailingBytes {
        write_stderr("a padded manifest was accepted\n");
        exit(1);
    }
    print("padded manifest rejected: ", error);

    // A plan that would schedule a task before itself is rejected.
    var broken = Plan { count: 2, concurrency: 1, edges: [1, 1] };
    let broken_error = validate(broken);
    if broken_error != Error.SelfLoop {
        write_stderr("a self-loop was accepted\n");
        exit(1);
    }
    print("self-loop rejected: ", broken_error);
}
