# Example-only dependency

`goose-task/` contains the exact Apache-2.0 `task.goose` and LICENSE from public
alpha.1, commit `166b684ca96403fea94072cc8e0c630321fb832d`.
`pins.json` retains immutable source hashes; `scripts/check-task-vendor.py`
verifies them without network access. Only the plan example and its consumer
tests import this dependency. `msgpack.goose` still imports only Goose's standard
modules, and the codec API/source remain unchanged.
