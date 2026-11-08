// SPDX-License-Identifier: Apache-2.0
// Test helper for generated, bounded fixtures; no process I/O or worker execution.
namespace plan_model;
import msgpack from "..";
import task from "../vendor/goose-task";
import plan_manifest from "../examples";
import std;
fn hex(c: u8) -> i64 { if c >= '0' && c <= '9' { return c - '0'; } if c >= 'a' && c <= 'f' { return c - 'a' + 10; } return -1; }
fn trace(encoded: const u8[:], fail: i64, cancel_after: i64, reverse: bool) -> u8[] {
    assert(encoded.len <= 131072 && encoded.len % 2 == 0);
    var wire: u8[>..] = [];
    for i in encoded.len / 2 { let hi = hex(encoded[i * 2]); let lo = hex(encoded[i * 2 + 1]); assert(hi >= 0 && lo >= 0); wire.push((hi * 16 + lo) as u8); }
    var s = task::Scheduler { .. }; let status = plan_manifest::start(s, wire);
    if status.error != plan_manifest::Error.None { return str("E ", status.error, " ", status.codec, " ", status.graph.kind); }
    var active: i64[>..] = []; var admitted: i64[>..] = []; var completed: i64[>..] = [];
    var cancelled = false;
    loop {
        if cancel_after >= 0 && admitted.len >= cancel_after { cancelled = true; }
        if !cancelled {
            let next = task::take(s);
            if next.kind == task::DispatchKind.Done { assert(active.len == 0); break; }
            if next.kind == task::DispatchKind.Ready { active.push(next.task); admitted.push(next.task); continue; }
            assert(next.kind == task::DispatchKind.Waiting && active.len > 0);
        } else if active.len == 0 { break; }
        let selected = if reverse { active.len - 1 } else { 0 };
        let id = active[selected]; var remaining: i64[>..] = [];
        for value, i in active { if i != selected { remaining.push(value); } }
        active = copy(remaining);
        assert(task::finish(s, id, id != fail).kind == task::ErrorKind.None); completed.push(id);
    }
    var out: u8[>..] = []; out.append(if cancelled { "C " } else { "D " });
    for id in admitted { format(out, id, ","); } out.push('|');
    for id in completed { format(out, id, ","); } out.push('|');
    let summary = task::summary(s);
    for id in summary.tasks {
        match task::state(s, id) {
            Ready => { out.push('R'); }, Pending => { out.push('P'); }, Running => { out.push('A'); },
            Succeeded => { out.push('S'); }, Failed => { out.push('F'); }, Skipped => { out.push('K'); },
            _ => { assert(false); },
        }
    }
    format(out, "|", summary.running, ":", summary.succeeded, ":", summary.failed, ":", summary.skipped);
    return copy(out);
}
