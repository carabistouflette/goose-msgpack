// SPDX-License-Identifier: Apache-2.0
import msgpack from "..";
import task from "../vendor/goose-task";
import plan_manifest from "../examples";
import std;
fn good(plan: const plan_manifest::Plan&) -> u8[] {
    let wire, error = plan_manifest::encode(plan); assert(error.error == plan_manifest::Error.None); return wire;
}
fn reject(wire: const u8[:], expected: plan_manifest::Error) {
    let plan, status = plan_manifest::decode(wire);
    assert(status.error == expected && plan.count == 0 && plan.concurrency == 1 && plan.edges.len == 0);
    var scheduler = task::Scheduler { .. };
    assert(plan_manifest::start(scheduler, wire).error == expected);
    assert(task::take(scheduler).kind == task::DispatchKind.InvalidState);
    assert(task::summary(scheduler).tasks == 0);
}
fn reject_codec(wire: const u8[:], expected: msgpack::Error) {
    let ignored, status = plan_manifest::decode(wire);
    assert(status.error == plan_manifest::Error.Codec && status.codec == expected);
    reject(wire, plan_manifest::Error.Codec);
}
// Test-only MessagePack producer intentionally permits invalid schema shapes.
fn message(kind: i64, field: i64 = -1) -> u8[] {
    var w = msgpack::Writer { .. }; assert(msgpack::init(w) == msgpack::Error.None);
    let members = if kind == 1 { 4 } else if kind == 2 || kind == 9 || kind == 10 || kind == 11 { 6 } else if kind == 12 { 17 } else { 5 };
    assert(msgpack::map(w, members) == msgpack::Error.None);
    for at in 5 {
        let i = if kind == 3 { 4 - at } else { at };
        if kind == 1 && i == field { continue; }
        let name = ["format", "version", "count", "concurrency", "edges"][i];
        if kind == 4 && i == field { assert(msgpack::bin(w, name) == msgpack::Error.None); }
        else { assert(msgpack::str(w, name) == msgpack::Error.None); }
        if kind == 5 && i == field { assert(msgpack::boolean(w, false) == msgpack::Error.None); }
        else if i == 0 && kind == 19 { assert(msgpack::bin(w, plan_manifest::FORMAT) == msgpack::Error.None); }
        else if i == 0 { assert(msgpack::str(w, if kind == 17 { "other" } else { plan_manifest::FORMAT }) == msgpack::Error.None); }
        else if i == 1 { assert(msgpack::int(w, if kind == 16 { 2 } else { 1 }) == msgpack::Error.None); }
        else if i == 2 && kind == 20 { assert(msgpack::float64(w, 2.0) == msgpack::Error.None); }
        else if i == 2 && kind == 21 { assert(msgpack::uint(w, 0xffffffffffffffff) == msgpack::Error.None); }
        else if i == 2 { assert(msgpack::int(w, if kind == 6 { 65 } else if kind == 15 { -1 } else { 2 }) == msgpack::Error.None); }
        else if i == 3 { assert(msgpack::int(w, if kind == 7 { 0 } else { 1 }) == msgpack::Error.None); }
        else if kind == 8 {
            assert(msgpack::map(w, 0) == msgpack::Error.None);
        } else if kind == 13 {
            assert(msgpack::array(w, 1) == msgpack::Error.None);
            assert(msgpack::map(w, 2) == msgpack::Error.None);
            for j in 4 { assert(msgpack::int(w, 0) == msgpack::Error.None); }
        } else if kind == 14 {
            assert(msgpack::array(w, 257) == msgpack::Error.None);
            for j in 257 { assert(msgpack::array(w, 2) == msgpack::Error.None); for k in 2 { assert(msgpack::int(w, 0) == msgpack::Error.None); } }
        } else { assert(msgpack::array(w, 0) == msgpack::Error.None); }
    }
    if kind == 2 {
        assert(msgpack::str(w, ["format", "version", "count", "concurrency", "edges"][field]) == msgpack::Error.None);
        assert(msgpack::nil(w) == msgpack::Error.None);
    }
    if kind == 9 || kind == 10 || kind == 11 || kind == 12 {
        for i in members - 5 {
            assert(msgpack::str(w, "extension") == msgpack::Error.None);
            if kind == 10 { for j in 9 { assert(msgpack::array(w, 1) == msgpack::Error.None); } assert(msgpack::nil(w) == msgpack::Error.None); }
            else if kind == 11 {
                assert(msgpack::array(w, 17) == msgpack::Error.None);
                for j in 17 { assert(msgpack::array(w, 256) == msgpack::Error.None); for k in 256 { assert(msgpack::nil(w) == msgpack::Error.None); } }
            } else { assert(msgpack::map(w, 1) == msgpack::Error.None); assert(msgpack::str(w, "child") == msgpack::Error.None); assert(msgpack::array(w, 1) == msgpack::Error.None); assert(msgpack::nil(w) == msgpack::Error.None); }
        }
    }
    assert(msgpack::finish(w) == msgpack::Error.None); var out: u8[>..] = []; out.append(msgpack::output(w)); return copy(out);
}
fn graph_cases() {
    for side in 2 {
        var negative = plan_manifest::Plan { count: 2, edges: [task::Edge { if side == 0 { -1 } else { 0 }, if side == 1 { -1 } else { 0 } }] };
        let wire, error = plan_manifest::encode(negative); assert(error.error == plan_manifest::Error.Type && wire.len == 0);
    }

    for cycle in [false, true] {
        var p = plan_manifest::Plan { count: 3, concurrency: 2, edges: [task::Edge { 0, 1 }, task::Edge { 1, 2 }, task::Edge { 2, if cycle { 0 } else { 2 } }] };
        var s = task::Scheduler { .. }; let status = plan_manifest::start(s, good(p));
        assert(status.error == plan_manifest::Error.Graph && status.graph.kind == task::ErrorKind.Cycle);
        assert(task::take(s).kind == task::DispatchKind.InvalidState);
        p.edges.clear(); assert(plan_manifest::start(s, good(p)).error == plan_manifest::Error.None);
    }
    var invalid = plan_manifest::Plan { count: 2, edges: [task::Edge { 0, 2 }] };
    var rejected = task::Scheduler { .. }; let error = plan_manifest::start(rejected, good(invalid));
    assert(error.error == plan_manifest::Error.Graph && error.graph.kind == task::ErrorKind.InvalidTask && error.graph.task == 2);
    var empty = plan_manifest::Plan { count: 0, concurrency: 64, .. }; var zero = task::Scheduler { .. };
    assert(plan_manifest::start(zero, good(empty)).error == plan_manifest::Error.None);
    assert(task::take(zero).kind == task::DispatchKind.Done);
    var singleton = plan_manifest::Plan { count: 1, .. }; var initialized = task::Scheduler { .. };
    let singleton_wire = good(singleton); assert(plan_manifest::start(initialized, singleton_wire).error == plan_manifest::Error.None);
    let restarted = plan_manifest::start(initialized, singleton_wire);
    assert(restarted.error == plan_manifest::Error.Graph && restarted.graph.kind == task::ErrorKind.InvalidState);
    assert(plan_manifest::start(initialized, [0x90 as u8]).error == plan_manifest::Error.Type);
    assert(task::summary(initialized).tasks == 1 && task::summary(initialized).running == 0 && task::state(initialized, 0) == task::State.Ready);

    var boundary = plan_manifest::Plan { count: 64, concurrency: 64, .. };
    for i in 63 { boundary.edges.push(task::Edge { i, i + 1 }); }
    while boundary.edges.len < 256 { boundary.edges.push(task::Edge { 0, 1 }); }
    var s = task::Scheduler { .. }; var wire: u8[>..] = []; wire.append(good(boundary));
    assert(plan_manifest::start(s, wire).error == plan_manifest::Error.None);
    for i in wire.len { wire[i] = 0; } // Scheduler owns its decoded graph snapshot.
    for i in 64 { let next = task::take(s); assert(next.kind == task::DispatchKind.Ready && next.task == i); assert(task::finish(s, i, true).kind == task::ErrorKind.None); }
    assert(task::take(s).kind == task::DispatchKind.Done);
    boundary.edges.push(task::Edge { 0, 1 }); let ignored, too_many = plan_manifest::encode(boundary); assert(too_many.error == plan_manifest::Error.EdgeLimit);
}
fn execution_cases() {
    var p = plan_manifest::Plan { count: 4, concurrency: 2, edges: [task::Edge { 0, 2 }, task::Edge { 0, 3 }, task::Edge { 0, 2 }] };
    var s = task::Scheduler { .. }; assert(plan_manifest::start(s, good(p)).error == plan_manifest::Error.None);
    assert(task::take(s).task == 0 && task::take(s).task == 1 && task::take(s).kind == task::DispatchKind.Waiting);
    assert(task::finish(s, 0, true).kind == task::ErrorKind.None);
    assert(task::take(s).task == 3 && task::take(s).kind == task::DispatchKind.Waiting);
    assert(task::finish(s, 3, true).kind == task::ErrorKind.None); assert(task::take(s).task == 2);
    assert(task::finish(s, 2, true).kind == task::ErrorKind.None); assert(task::finish(s, 1, true).kind == task::ErrorKind.None);
    assert(task::take(s).kind == task::DispatchKind.Done);
    var failed = plan_manifest::Plan { count: 6, concurrency: 2, edges: [task::Edge { 0, 2 }, task::Edge { 1, 2 }, task::Edge { 2, 3 }, task::Edge { 4, 5 }] };
    var f = task::Scheduler { .. }; assert(plan_manifest::start(f, good(failed)).error == plan_manifest::Error.None);
    assert(task::take(f).task == 0 && task::take(f).task == 1);
    assert(task::finish(f, 0, false).kind == task::ErrorKind.None); assert(task::take(f).task == 4);
    assert(task::finish(f, 1, false).kind == task::ErrorKind.None); assert(task::finish(f, 4, true).kind == task::ErrorKind.None);
    assert(task::take(f).task == 5); assert(task::finish(f, 5, true).kind == task::ErrorKind.None);
    assert(task::take(f).kind == task::DispatchKind.Done); let done = task::summary(f);
    assert(done.succeeded == 2 && done.failed == 2 && done.skipped == 2 && done.running == 0);
    // Caller cancellation: stop admissions and finish only already-admitted work.
    var cancelled = plan_manifest::Plan { count: 5, concurrency: 2, edges: [task::Edge { 0, 2 }, task::Edge { 1, 3 }] };
    var c = task::Scheduler { .. }; assert(plan_manifest::start(c, good(cancelled)).error == plan_manifest::Error.None);
    assert(task::take(c).task == 0 && task::take(c).task == 1);
    let caller_cancelled = true;
    assert(task::finish(c, 0, true).kind == task::ErrorKind.None); assert(task::finish(c, 1, false).kind == task::ErrorKind.None);
    assert(caller_cancelled && task::state(c, 2) == task::State.Ready && task::state(c, 4) == task::State.Ready);
    let stopped = task::summary(c); assert(stopped.running == 0 && stopped.succeeded == 1 && stopped.failed == 1 && stopped.skipped == 1);
    assert(stopped.succeeded + stopped.failed + stopped.skipped < stopped.tasks); // Not scheduler Done.
}
fn main() {
    for field in 5 { reject(message(1, field), plan_manifest::Error.Missing); reject(message(2, field), plan_manifest::Error.Duplicate); reject(message(4, field), plan_manifest::Error.Type); reject(message(5, field), plan_manifest::Error.Type); }
    for kind in [0, 3, 9] { let p, status = plan_manifest::decode(message(kind)); assert(status.error == plan_manifest::Error.None && p.count == 2); }
    reject(message(6), plan_manifest::Error.TaskLimit); reject(message(7), plan_manifest::Error.Parallelism);
    reject(message(8), plan_manifest::Error.Type); reject(message(13), plan_manifest::Error.Type);
    reject(message(12), plan_manifest::Error.Members);
    reject_codec(message(10), msgpack::Error.DepthLimit); reject_codec(message(11), msgpack::Error.NodeLimit); reject_codec(message(14), msgpack::Error.ContainerLimit);
    reject(message(15), plan_manifest::Error.Type); reject(message(16), plan_manifest::Error.Version);
    reject(message(17), plan_manifest::Error.Format); reject(message(19), plan_manifest::Error.Type);
    reject(message(20), plan_manifest::Error.Type); reject(message(21), plan_manifest::Error.Type);
    var valid = message(0); var trailing: u8[>..] = []; trailing.append(valid); trailing.push(0);
    reject_codec(trailing, msgpack::Error.TrailingBytes);
    for length in valid.len { reject(valid[..length], plan_manifest::Error.Codec); }
    var huge: u8[>..] = []; for i in 65537 { huge.push(0); } reject_codec(huge, msgpack::Error.InputLimit);
    graph_cases(); execution_cases(); print("wire-plan consumer contracts passed");
}
