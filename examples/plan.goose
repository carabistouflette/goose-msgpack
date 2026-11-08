// SPDX-License-Identifier: Apache-2.0
// A bounded wire-plan handoff into the pinned goose-task scheduler.
import msgpack from "..";
import task from "../vendor/goose-task";
import .plan_manifest;
import std;
fn main() {
    var plan = plan_manifest::Plan { count: 4, concurrency: 2, edges: [task::Edge { 0, 2 }, task::Edge { 1, 2 }, task::Edge { 2, 3 }] };
    let wire, encoded = plan_manifest::encode(plan); assert(encoded.error == plan_manifest::Error.None);
    var scheduler = task::Scheduler { .. };
    assert(plan_manifest::start(scheduler, wire).error == plan_manifest::Error.None);
    print("manifest: ", wire.len, " bytes");
    // The caller owns work and completion order. No workers are spawned here.
    let first = task::take(scheduler); let second = task::take(scheduler);
    assert(first.task == 0 && second.task == 1);
    assert(task::take(scheduler).kind == task::DispatchKind.Waiting);
    assert(task::finish(scheduler, second.task, true).kind == task::ErrorKind.None);
    assert(task::finish(scheduler, first.task, true).kind == task::ErrorKind.None);
    for expected in [2, 3] {
        let next = task::take(scheduler); assert(next.kind == task::DispatchKind.Ready && next.task == expected);
        assert(task::finish(scheduler, next.task, true).kind == task::ErrorKind.None);
    }
    assert(task::take(scheduler).kind == task::DispatchKind.Done);
    let summary = task::summary(scheduler);
    assert(summary.succeeded == 4 && summary.failed == 0 && summary.skipped == 0);
    print("decoded plan completed: 4 succeeded");
}
