#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify the exact example-only dependency without network or hooks."""
import hashlib
import json
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
pin=json.loads((root/'vendor/pins.json').read_text())
assert re.fullmatch('[0-9a-f]{40}',pin['revision'])
assert set(pin['files'])=={'task.goose','LICENSE'}
for name,expected in pin['files'].items():
    path=root/'vendor/goose-task'/name
    assert path.is_file() and not path.is_symlink()
    assert hashlib.sha256(path.read_bytes()).hexdigest()==expected,(name,'vendored bytes differ from pin')
print('example-only goose-task pin verified:',pin['revision'])
