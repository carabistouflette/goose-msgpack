# Wire-plan consumer qualification

Source `8537bc8` (full identity in receipt.json) integrates the existing example
workflow with exact goose-task alpha.1 `166b684ca96403fea94072cc8e0c630321fb832d`.
The codec bytes match public base `18c968bcf2d938bd3af6e878e5ee607eaac3c875`;
the task source/license match `vendor/pins.json`. Neither library API expands.
This is an example consumer, not a production executor.

Normal/debug contracts, the runnable example and both GCC/Clang ASan+UBSan
consumer configurations pass. The independent wire model replays the same 512
seeded fixtures in release, debug and both sanitizer configurations. These are
512 distinct fixtures, not 2,048 distinct cases. They include successful terminal
runs, caller-stopped admissions and graph/schema rejection. Admission/completion
ID sequences and final task states/summary counters are compared against an
independent DFS/set-prerequisite model. Codec differential validation also retains 102,723
cases per configured execution with matching expected/actual corpus hashes.

The sanitizer records include explicit generated-C compiler/link transcripts;
the generated model binary's link must contain the sanitizer flags, in addition
to the consumer contract binaries. Root helper self-tests cover launch failure,
partial timeout output, bounded capture and private child-group termination.
An orphan zombie is not a live child and cannot be reaped by a non-parent.
The helper cleans its group; it does not prove that a command left no lingering
members before that cleanup or control descendants escaping the group.

`duplicate-order-counterexample.json` retains a development oracle correction:
its first-occurrence assumption was wrong, and the unchanged task library
correctly used final duplicate-occurrence ordering. The final oracle and an
explicit contract regression cover that nuance. It is not a library defect or
a passing-run result. All final model outputs are retained separately.

Raw reports retain exact wire fixtures, fixed caller policies, expected/actual
traces, source/tool/generated-input hashes, commands and failure provenance.
No generated binary, compiler output or toolchain is committed. Linux process
ownership belongs to test tooling; consumer cancellation merely stops admission
and reports already-admitted work. No performance, OS-worker cleanup or leak
freedom claim is made. See [the contract](../TASK-CONSUMER.md).

Recompute:

```sh
python3 summarize.py
```
