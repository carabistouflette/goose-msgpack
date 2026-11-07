# SPDX-License-Identifier: Apache-2.0
"""Recompute correctness evidence; repeated configurations are not unique cases."""
import hashlib
import json
from pathlib import Path
root=Path(__file__).resolve().parent
load=lambda name:json.loads((root/name).read_text())
digest=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
receipt=load('receipt.json')
for name,value in receipt['sha256'].items():assert digest(root/name)==value,name
modes=['release','debug','gcc-sanitize','clang-sanitize'];summary={};fixtures=None
for mode in modes:
 r=load('model-'+mode+'.json');assert r['complete'] and r['cases']==512 and len(r['fixtures'])==512
 assert all(c['complete'] and c['code']==0 for c in r['commands'])
 assert not r['commands'][-1]['stderr']
 assert r['commands'][-1]['stdout'].splitlines()==[f['expected'] for f in r['fixtures']]
 if fixtures is None:fixtures=r['fixtures']
 else:assert r['fixtures']==fixtures
 summary[mode]=dict(cases=512,wire_and_expected_sha256=hashlib.sha256(json.dumps(r['fixtures'],sort_keys=True,separators=(',',':')).encode()).hexdigest(),binary_sha256=r['binary_sha256'])
for cc in ['gcc','clang']:
 s=load(cc+'-sanitize.json');m=load('model-'+cc+'-sanitize.json');target=m['commands'][0]['argv'][-1]
 assert all(c['returncode']==0 for c in s['executions'])
 assert digest(root/(cc+'-compiler-commands.jsonl'))==s['compiler_commands_sha256']
 links=[argv for argv in s['compiler_commands'] if '-o' in argv and argv[argv.index('-o')+1]==target]
 assert links and all('-fsanitize=address,undefined' in argv and '-UNDEBUG' in argv for argv in links)
 assert s['oracle']['cases']==102723 and s['oracle']['stdout_sha256']==s['oracle']['expected_sha256']
for name in ['oracle.json','oracle-native.json','oracle-debug.json']:
 r=load(name);assert r['cases']==102723 and r['stdout_sha256']==r['expected_sha256']
result=dict(source=receipt['source'],codec_unchanged=receipt['codec_unchanged'],task_revision=receipt['task_pin']['revision'],
            configurations=summary,distinct_wire_cases=len({f["wire"] for f in fixtures}),process_selftests=receipt['process_selftests'],
            outcomes={prefix:sum(f['expected'].startswith(prefix) for f in fixtures) for prefix in ['D ','C ','E ']},
            scope='Correctness of an example wire handoff and caller policy; no OS worker, signal cleanup or throughput guarantee.')
(root/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
