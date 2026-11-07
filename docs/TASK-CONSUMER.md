# MessagePack → goose-task example consumer

`examples/plan.goose` is a second example consumer of goose-task after Honk.
It is a wire-plan handoff workflow, not a production build runner. Neither
`msgpack.goose` nor goose-task's supported API changes. The example/test-only
source pin is `166b684ca96403fea94072cc8e0c630321fb832d` (alpha.1), verified by
`scripts/check-task-vendor.py`; license and immutable file hashes are retained.

## Wire contract and application policy

A single MessagePack map requires five unique string-named fields:

| Field | Value |
| --- | --- |
| format | Exact string `goose-task-plan` |
| version | Nonnegative integer 1 |
| count | Nonnegative integer, 0–64 |
| concurrency | Integer, 1–64; may exceed count, including an empty plan |
| edges | Array of at most 256 two-element arrays of nonnegative integer IDs |

Both signed and unsigned integer marker families are accepted for nonnegative
values that fit i64; booleans/floats are not integers here. `edges` and pairs
must be arrays, never maps with coincidentally equal counts. Endpoints and
cycles are validated by goose-task, not a duplicate graph implementation.
Duplicate edges retain their multiplicity and wire order.

The example policy permits at most 16 map members, 64 KiB input/output, 4,096
codec nodes, depth 8 and 256 elements per container. These limits are deliberately
smaller than the libraries' hard maxima and can represent the stated 64/256
graph envelope. Declared lengths are checked before growing edge storage.
Unknown string-named fields are skipped as entire budgeted values for forward
compatibility. Unknown names may repeat; recognized names may not. Missing,
wrong-type, duplicate-known-field, trailing, truncated and over-budget inputs
are rejected. Map order is not significant.

`encode` enforces schema sizes and nonnegative IDs, but does not validate graph
topology; a successful encoding is not proof that a plan is runnable.
`decode` owns a fresh temporary plan and returns an empty default on failure;
it validates the schema and full-input consumption, not graph topology.
`start` first decodes and calls `finish(reader)`, then invokes
`task::start(scheduler, count, edges, concurrency, limits)`. The scheduler takes
its own graph snapshot. No work is admitted before complete wire validation;
invalid endpoints/cycles leave a fresh scheduler uninitialized. Rejected restarts
leave an existing scheduler's counters and states unchanged. Callers should
construct a fresh scheduler for each accepted manifest.

## Completion, ordering and cancellation

Determinism requires a fixed graph and completion sequence; real workers may
finish in different orders. Initial ready IDs enter FIFO in ascending order. Later releases follow the final
incoming occurrence's input-edge order; this can differ from smallest-ID order.
For `0→2, 0→3, 0→2`, completing 0 releases 3 before 2. The model initially assumed
first occurrence; the retained counterexample motivated an explicit regression
and a specification-correct independent oracle. The library behavior was correct.

A task failure transitively skips dependents, including overlapping descendant
sets only once, while independent work can continue. `Done` means terminal, not all succeeded;
callers must inspect failed/skipped counters. The single owner reports
actual completion outcomes serially. The consumer does not kill processes,
implement retries, or create OS workers.

Cancellation belongs to that owner: stop admissions, complete only already
admitted work, and report cancellation separately. Ready/Pending tasks stay
undispatched; they are not falsely marked finished or given a new cancellation
state. The scheduler may remain nonterminal. The qualification simulates that
caller policy; it does not qualify signal delivery or external worker cleanup.

## Maintained qualification

`tests/plan_consumer.goose` exercises public schema/task interfaces, transactional
rejection, every recognized field, exact container types, unknown/reordered
fields, byte/node/depth/container limits, empty/full envelopes, invalid indices,
self/long cycles, duplicated edges, snapshot ownership, Waiting/Done, FIFO
release, overlapping failure and caller cancellation.

`tests/plan_model.py` independently encodes randomized manifests with shuffled
fields and bounded extensions. A DFS/set-prerequisite model computes expected
traces, states and counters under fixed completion/failure/cancellation policies.
It does not use the library's CSR/degree-counter algorithm. A generated fixed
Goose program feeds those wire bytes through the real decoder and scheduler.
The model uses last-occurrence ordering for duplicate releases. Default 512
cases use seed 20261107; inputs, generated program, tool hashes, stdout and
mismatch/failure data are retained in a new `.build/plan-model-*` directory.
Existing explicit output paths are never overwritten.

The Linux test harness uses pidfds, private process groups, finite deadlines,
bounded output and cleanup before reaping; timeout output is retained. This is
test tooling, not a platform dependency of the pure codec/task modules. It
controls its private group, not arbitrary descendants that escape that group.

```sh
make format check test test-debug GOOSE=/path/to/pinned/goose
make sanitize GOOSE=/path/to/pinned/goose SANITIZER_CC=gcc OUTPUT=.build/task-gcc.json
make sanitize GOOSE=/path/to/pinned/goose SANITIZER_CC=clang OUTPUT=.build/task-clang.json
```

No throughput comparison or performance guarantee follows from this correctness
qualification. The original codec benchmarks and validation remain source-qualified.
