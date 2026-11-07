// SPDX-License-Identifier: Apache-2.0
// Example-owned schema; neither codec nor scheduler API depends on this module.
namespace plan_manifest;
import msgpack from "..";
import task from "../vendor/goose-task";
import std;
const MAX_TASKS = 64;
const MAX_EDGES = 256;
const MAX_MEMBERS = 16;
const FORMAT = "goose-task-plan";
enum Error { None, Codec, Type, Duplicate, Missing, Format, Version, TaskLimit, EdgeLimit, Parallelism, Members, Graph }
struct Status { error: Error = Error.None, codec: msgpack::Error = msgpack::Error.None, graph: task::Error = task::Error { .. } }
struct Plan { count: i64 = 0, concurrency: i64 = 1, edges: task::Edge[>..] }
fn budgets() -> msgpack::Limits {
    return msgpack::Limits { max_input_bytes: 65536, max_output_bytes: 65536, max_nodes: 4096, max_depth: 8, max_str_bytes: 65536, max_bin_bytes: 65536, max_container_len: MAX_EDGES };
}
fn codec(error: msgpack::Error) -> Status { Status { error: Error.Codec, codec: error, .. } }
fn number(reader: msgpack::Reader&) -> i64, Status {
    let token, error = msgpack::next(reader);
    if error != msgpack::Error.None { return 0, codec(error); }
    let value, ok = msgpack::as_u64(token);
    if !ok || value > 0x7fffffffffffffff { return 0, Status { error: Error.Type, .. }; }
    return value as i64, Status { .. };
}
fn body(reader: msgpack::Reader&, plan: Plan&) -> Status {
    let head, error = msgpack::next(reader);
    if error != msgpack::Error.None { return codec(error); }
    match head { Map _ => {}, _ => { return Status { error: Error.Type, .. }; } }
    let members = msgpack::count(head);
    if members > MAX_MEMBERS { return Status { error: Error.Members, .. }; }
    var seen: bool[5] = [false; 5];
    for member in members {
        let key, key_error = msgpack::next(reader);
        if key_error != msgpack::Error.None { return codec(key_error); }
        match key { Str _ => {}, _ => { return Status { error: Error.Type, .. }; } }
        let name = msgpack::text(key);
        var id = -1;
        for field, i in ["format", "version", "count", "concurrency", "edges"] { if name == field { id = i; } }
        if id < 0 {
            let skipped = msgpack::skip(reader);
            if skipped != msgpack::Error.None { return codec(skipped); }
            continue;
        }
        if seen[id] { return Status { error: Error.Duplicate, .. }; }
        seen[id] = true;
        if id == 0 {
            let token, status = msgpack::next(reader);
            if status != msgpack::Error.None { return codec(status); }
            match token { Str _ => {}, _ => { return Status { error: Error.Type, .. }; } }
            let format = msgpack::text(token);
            if format != FORMAT { return Status { error: Error.Format, .. }; }
        } else if id < 4 {
            let value, status = number(reader);
            if status.error != Error.None { return status; }
            if id == 1 && value != 1 { return Status { error: Error.Version, .. }; }
            if id == 2 {
                if value > MAX_TASKS { return Status { error: Error.TaskLimit, .. }; }
                plan.count = value;
            }
            if id == 3 {
                if value < 1 || value > MAX_TASKS { return Status { error: Error.Parallelism, .. }; }
                plan.concurrency = value;
            }
        } else {
            let token, status = msgpack::next(reader);
            if status != msgpack::Error.None { return codec(status); }
            match token { Array _ => {}, _ => { return Status { error: Error.Type, .. }; } }
            let count = msgpack::count(token);
            if count > MAX_EDGES { return Status { error: Error.EdgeLimit, .. }; }
            for edge in count {
                let pair, pair_error = msgpack::next(reader);
                if pair_error != msgpack::Error.None { return codec(pair_error); }
                match pair { Array a => { if a.count != 2 { return Status { error: Error.Type, .. }; } }, _ => { return Status { error: Error.Type, .. }; } }
                let before, before_error = number(reader); if before_error.error != Error.None { return before_error; }
                let after, after_error = number(reader); if after_error.error != Error.None { return after_error; }
                plan.edges.push(task::Edge { before, after });
            }
        }
    }
    for present in seen { if !present { return Status { error: Error.Missing, .. }; } }
    return Status { .. };
}
// Transactional decoding: rejected input never exposes a partial plan.
fn decode(wire: const u8[:]) -> Plan, Status {
    var reader = msgpack::Reader { .. }; var plan = Plan { .. };
    let initialized = msgpack::init(reader, wire, budgets());
    if initialized != msgpack::Error.None { return Plan { .. }, codec(initialized); }
    let parsed = body(reader, plan);
    if parsed.error != Error.None { return Plan { .. }, parsed; }
    let finished = msgpack::finish(reader);
    if finished != msgpack::Error.None { return Plan { .. }, codec(finished); }
    return copy(plan), Status { .. };
}
fn start(scheduler: task::Scheduler&, wire: const u8[:]) -> Status {
    let plan, status = decode(wire);
    if status.error != Error.None { return status; }
    var limits = task::Limits { tasks: MAX_TASKS, edges: MAX_EDGES };
    let graph = task::start(scheduler, plan.count, plan.edges, plan.concurrency, limits);
    if graph.kind != task::ErrorKind.None { return Status { error: Error.Graph, graph: graph, .. }; }
    return Status { .. };
}
fn encode(plan: const Plan&) -> u8[], Status {
    if plan.count < 0 || plan.count > MAX_TASKS { return [], Status { error: Error.TaskLimit, .. }; }
    if plan.concurrency < 1 || plan.concurrency > MAX_TASKS { return [], Status { error: Error.Parallelism, .. }; }
    if plan.edges.len > MAX_EDGES { return [], Status { error: Error.EdgeLimit, .. }; }
    for edge in plan.edges {
        if edge.before < 0 || edge.after < 0 { return [], Status { error: Error.Type, .. }; }
    }
    var writer = msgpack::Writer { .. };
    var error = msgpack::init(writer, budgets());
    if error != msgpack::Error.None { return [], codec(error); }
    error = msgpack::map(writer, 5); if error != msgpack::Error.None { return [], codec(error); }
    for name, i in ["format", "version", "count", "concurrency", "edges"] {
        error = msgpack::str(writer, name); if error != msgpack::Error.None { return [], codec(error); }
        if i == 0 { error = msgpack::str(writer, FORMAT); }
        else if i == 1 { error = msgpack::int(writer, 1); }
        else if i == 2 { error = msgpack::int(writer, plan.count); }
        else if i == 3 { error = msgpack::int(writer, plan.concurrency); }
        else {
            error = msgpack::array(writer, plan.edges.len); if error != msgpack::Error.None { return [], codec(error); }
            for edge in plan.edges {
                error = msgpack::array(writer, 2); if error != msgpack::Error.None { return [], codec(error); }
                error = msgpack::int(writer, edge.before); if error != msgpack::Error.None { return [], codec(error); }
                error = msgpack::int(writer, edge.after); if error != msgpack::Error.None { return [], codec(error); }
            }
        }
        if error != msgpack::Error.None { return [], codec(error); }
    }
    error = msgpack::finish(writer); if error != msgpack::Error.None { return [], codec(error); }
    var out: u8[>..] = []; out.append(msgpack::output(writer));
    return copy(out), Status { .. };
}
