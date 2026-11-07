// SPDX-License-Identifier: Apache-2.0
import std;
namespace task;
const MAX_TASKS = 65536;
const MAX_EDGES = 1048576;
struct Limits { tasks: i64 = MAX_TASKS, edges: i64 = MAX_EDGES }
struct Edge { before: i64, after: i64 }
enum ErrorKind { None, InvalidLimits, TaskLimit, EdgeLimit, InvalidTask, Cycle, InvalidState, InvalidParallelism }
struct Error { kind: ErrorKind = ErrorKind.None, edge: i64 = -1, task: i64 = -1 }
enum State { Unknown, Pending, Ready, Running, Succeeded, Failed, Skipped }
enum DispatchKind { Ready, Waiting, Done, InvalidState }
struct Dispatch { kind: DispatchKind, task: i64 = -1 }
struct Summary { tasks: i64 = 0, running: i64 = 0, succeeded: i64 = 0, failed: i64 = 0, skipped: i64 = 0 }
// Implementation representation, not a supported input type.
struct Graph { offsets: i64[], targets: i64[], degrees: i64[], order: i64[] }
fn detail_compile(count: i64, edges: const Edge[:], limits: Limits&) -> Graph, Error {
    if limits.tasks < 0 || limits.tasks > MAX_TASKS || limits.edges < 0 || limits.edges > MAX_EDGES {
        return Graph { .. }, Error { kind: ErrorKind.InvalidLimits, .. };
    }
    if count < 0 || count > limits.tasks { return Graph { .. }, Error { kind: ErrorKind.TaskLimit, .. }; }
    if edges.len > limits.edges { return Graph { .. }, Error { kind: ErrorKind.EdgeLimit, .. }; }
    for edge, i in edges {
        if edge.before < 0 || edge.before >= count { return Graph { .. }, Error { kind: ErrorKind.InvalidTask, edge: i, task: edge.before }; }
        if edge.after < 0 || edge.after >= count { return Graph { .. }, Error { kind: ErrorKind.InvalidTask, edge: i, task: edge.after }; }
    }
    var offsets: i64[>..] = []; var targets: i64[>..] = [];
    var degrees: i64[>..] = []; var order: i64[>..] = [];
    for i in count + 1 { offsets.push(0); }
    for i in count { degrees.push(0); }
    for edge in edges { offsets[edge.before + 1]++; degrees[edge.after]++; }
    for i in count { offsets[i + 1] += offsets[i]; }
    var positions = copy(offsets);
    for i in edges.len { targets.push(0); }
    for edge in edges { targets[positions[edge.before]] = edge.after; positions[edge.before]++; }
    var remaining = copy(degrees);
    for i in count { if remaining[i] == 0 { order.push(i); } }
    var head = 0;
    while head < order.len {
        let id = order[head]; head++;
        for at in offsets[id]..offsets[id + 1] {
            let next = targets[at]; remaining[next]--;
            if remaining[next] == 0 { order.push(next); }
        }
    }
    if order.len != count {
        for i in count { if remaining[i] > 0 { return Graph { .. }, Error { kind: ErrorKind.Cycle, task: i, .. }; } }
    }
    return Graph { copy(offsets), copy(targets), copy(degrees), copy(order) }, Error { .. };
}
fn plan(count: i64, edges: const Edge[:], limits: Limits&) -> i64[], Error {
    let graph, error = detail_compile(count, edges, limits);
    if error.kind != ErrorKind.None { return [], error; }
    return copy(graph.order), error;
}
// Noncopyable owner. Fields and detail_* helpers are private API; never mutate.
root struct Scheduler {
    _initialized: bool       = false,
    _offsets:     i64[>..]   = [], _targets: i64[>..] = [], _remaining: i64[>..] = [],
    _states:      State[>..] = [], _ready: i64[>..] = [], _head: i64 = 0,
    _scratch:     i64[>..]   = [], _parallelism: i64 = 0, _summary: Summary = Summary { .. },
}
fn start(s: Scheduler&, count: i64, edges: const Edge[:], parallelism: i64, limits: Limits&) -> Error {
    if s._initialized { return Error { kind: ErrorKind.InvalidState, .. }; }
    if parallelism < 1 || parallelism > MAX_TASKS { return Error { kind: ErrorKind.InvalidParallelism, .. }; }
    let graph, error = detail_compile(count, edges, limits);
    if error.kind != ErrorKind.None { return error; }
    s._offsets.append(graph.offsets); s._targets.append(graph.targets); s._remaining.append(graph.degrees);
    for i in count {
        let ready = graph.degrees[i] == 0;
        s._states.push(if ready { State.Ready } else { State.Pending });
        if ready { s._ready.push(i); }
    }
    s._parallelism = parallelism; s._summary.tasks = count; s._initialized = true;
    return Error { .. };
}
fn summary(s: Scheduler&) -> Summary { s._summary }
fn state(s: Scheduler&, id: i64) -> State {
    if !s._initialized || id < 0 || id >= s._states.len { return State.Unknown; }
    s._states[id]
}
fn take(s: Scheduler&) -> Dispatch {
    if !s._initialized { return Dispatch { kind: DispatchKind.InvalidState, .. }; }
    if s._summary.succeeded + s._summary.failed + s._summary.skipped == s._summary.tasks {
        return Dispatch { kind: DispatchKind.Done, .. };
    }
    if s._summary.running >= s._parallelism { return Dispatch { kind: DispatchKind.Waiting, .. }; }
    while s._head < s._ready.len {
        let id = s._ready[s._head]; s._head++;
        if s._states[id] != State.Ready { continue; }
        s._states[id] = State.Running; s._summary.running++;
        return Dispatch { kind: DispatchKind.Ready, task: id };
    }
    return Dispatch { kind: DispatchKind.Waiting, .. };
}
fn finish(s: Scheduler&, id: i64, success: bool) -> Error {
    if !s._initialized { return Error { kind: ErrorKind.InvalidState, .. }; }
    if id < 0 || id >= s._states.len { return Error { kind: ErrorKind.InvalidTask, task: id, .. }; }
    if s._states[id] != State.Running { return Error { kind: ErrorKind.InvalidState, task: id, .. }; }
    s._summary.running--;
    s._states[id] = if success { State.Succeeded } else { State.Failed };
    if success {
        s._summary.succeeded++;
        for at in s._offsets[id]..s._offsets[id + 1] {
            let next = s._targets[at];
            if s._states[next] != State.Pending { continue; }
            s._remaining[next]--;
            if s._remaining[next] == 0 { s._states[next] = State.Ready; s._ready.push(next); }
        }
    } else {
        s._summary.failed++;
        s._scratch.clear(); s._scratch.push(id);
        var head = 0;
        while head < s._scratch.len {
            let current = s._scratch[head]; head++;
            for at in s._offsets[current]..s._offsets[current + 1] {
                let next = s._targets[at];
                // A descendant cannot run until this prerequisite succeeds.
                if s._states[next] == State.Skipped { continue; }
                s._states[next] = State.Skipped; s._summary.skipped++; s._scratch.push(next);
            }
        }
    }
    return Error { .. };
}
