#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent wire producer and semantic scheduling model; fixed generated input."""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import tempfile
from plan_process import run

ROOT=Path(__file__).resolve().parents[1]


def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pack(value):
    if isinstance(value,str):
        b=value.encode();return (bytes([0xa0+len(b)]) if len(b)<32 else b'\xd9'+bytes([len(b)]))+b
    if isinstance(value,int):
        if 0<=value<128:return bytes([value])
        if value<0:return b'\xd1'+struct.pack('>h',value)
        return b'\xcd'+struct.pack('>H',value)
    if isinstance(value,list):return (bytes([0x90+len(value)]) if len(value)<16 else b'\xdc'+struct.pack('>H',len(value)))+b''.join(map(pack,value))
    raise TypeError(value)


def manifest(n,edges,cap,rng):
    fields=[('format','goose-task-plan'),('version',1),('count',n),('concurrency',cap),('edges',[list(e) for e in edges])]
    if rng.randrange(2):fields.append(('extension',[['future',1],[]]))
    rng.shuffle(fields)
    return bytes([0x80+len(fields)])+b''.join(pack(k)+pack(v) for k,v in fields)


def model(n,edges,cap,fail,cancel,reverse):
    if n>64:return 'E Error.TaskLimit Error.None ErrorKind.None'
    if not 1<=cap<=64:return 'E Error.Parallelism Error.None ErrorKind.None'
    if any(x<0 for edge in edges for x in edge):return 'E Error.Type Error.None ErrorKind.None'
    if any(x>=n for edge in edges for x in edge):return 'E Error.Graph Error.None ErrorKind.InvalidTask'
    adjacency={i:set() for i in range(n)}
    for a,b in edges:adjacency[a].add(b)
    colors=[0]*n
    def visit(i):
        if colors[i]==1:return True
        if colors[i]==2:return False
        colors[i]=1
        if any(visit(j) for j in adjacency[i]):return True
        colors[i]=2;return False
    if any(visit(i) for i in range(n)):return 'E Error.Graph Error.None ErrorKind.Cycle'
    prerequisites={i:{a for a,b in edges if b==i} for i in range(n)}
    states=['P' if prerequisites[i] else 'R' for i in range(n)]
    ready=collections.deque(i for i in range(n) if states[i]=='R')
    active=[];admitted=[];completed=[];cancelled=False
    while True:
        if cancel>=0 and len(admitted)>=cancel:cancelled=True
        if not cancelled:
            if all(s in 'SFK' for s in states):break
            if ready and len(active)<cap:
                i=ready.popleft();assert states[i]=='R';states[i]='A';active.append(i);admitted.append(i);continue
            assert active
        elif not active:break
        i=active.pop(-1 if reverse else 0);states[i]='F' if i==fail else 'S';completed.append(i)
        if i==fail:
            descendants=set();todo=list(adjacency[i])
            while todo:
                j=todo.pop()
                if j in descendants:continue
                descendants.add(j);todo.extend(adjacency[j])
            for j in descendants:
                assert states[j]!='A'
                states[j]='K'
            ready=collections.deque(j for j in ready if states[j]=='R')
        else:
            # Re-evaluate the raw prerequisite relation, not degree counters/CSR.
            # Duplicate occurrences retain order: a target is released at the
            # last occurrence owned by this finishing prerequisite, not first.
            last={b:at for at,(a,b) in enumerate(edges) if a==i}
            for b in sorted(last,key=last.get):
                if states[b]=='P' and all(states[p]=='S' for p in prerequisites[b]):
                    states[b]='R';ready.append(b)
    return ('C ' if cancelled else 'D ')+''.join(f'{i},' for i in admitted)+'|'+''.join(f'{i},' for i in completed)+'|'+''.join(states)+f'|{states.count("A")}:{states.count("S")}:{states.count("F")}:{states.count("K")}'


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--goose',required=True,type=Path);p.add_argument('--cc',default='gcc');p.add_argument('--cases',type=int,default=512);p.add_argument('--debug',action='store_true');p.add_argument('--output',type=Path);args=p.parse_args()
    if not 1<=args.cases<=4096:p.error('cases must be1..4096')
    goose=args.goose.resolve(strict=True);cc=Path(shutil.which(args.cc)).resolve(strict=True)
    if args.output is not None and (args.output.exists() or args.output.is_symlink()):p.error('preserve old evidence; choose a new output path')
    (ROOT/'.build').mkdir(exist_ok=True)
    folder=Path(tempfile.mkdtemp(prefix='plan-model-',dir=ROOT/'.build'))
    if args.output is None:args.output=folder/'report.json'
    suffix='debug' if args.debug else 'release';source=folder/(suffix+'.goose');binary=folder/suffix
    rng=random.Random(20261107);fixtures=[]
    special=[(0,[],64),(2,[(0,1),(0,1)],1),(4,[(0,3),(0,2)],2),(3,[(0,1),(1,2),(2,0)],2),(1,[(0,1)],1),(65,[],1),(1,[],0),(1,[],65)]
    for i in range(args.cases):
        if i<len(special):n,edges,cap=special[i]
        else:
            n=rng.randrange(13);cap=rng.randrange(1,17);edges=[]
            for _ in range(rng.randrange(28)):
                if n:edges.append((rng.randrange(n),rng.randrange(n)))
            if i%3==0:edges=[(a,b) for a,b in edges if a<b]
        fail=rng.randrange(-1,max(1,n));cancel=-1 if i%3 else rng.randrange(n+1);reverse=bool(i%2)
        wire=manifest(n,edges,cap,rng)
        fixtures.append(dict(wire=wire.hex(),fail=fail,cancel=cancel,reverse=reverse,expected=model(n,edges,cap,fail,cancel,reverse)))
    text='\n'.join(f'import {name} from {json.dumps(str(path))};' for name,path in [('msgpack',ROOT),('task',ROOT/'vendor/goose-task'),('plan_manifest',ROOT/'examples'),('plan_model',ROOT/'tests')])+'\nimport std;\nfn main() {\n'
    for name,typ,values in [('wires','const u8[:]',[json.dumps(f['wire']) for f in fixtures]),('failed','i64',[str(f['fail']) for f in fixtures]),('cancelled','i64',[str(f['cancel']) for f in fixtures]),('reverse','bool',[str(f['reverse']).lower() for f in fixtures])]:text+=f'let {name}: ({typ})[{len(fixtures)}] = ['+','.join(values)+'];\n'
    text+='for i in wires.len { print(plan_model::trace(wires[i],failed[i],cancelled[i],reverse[i])); }\n}\n';source.write_text(text)
    inputs=[ROOT/'msgpack.goose',ROOT/'examples/plan_manifest.goose',ROOT/'tests/plan_model.goose',ROOT/'tests/plan_process.py',Path(__file__),ROOT/'vendor/goose-task/task.goose',ROOT/'GOOSE_REVISION']
    frozen={str(x.relative_to(ROOT)):digest(x) for x in inputs}
    report=dict(complete=False,cases=len(fixtures),seed=20261107,inputs=frozen,goose_sha256=digest(goose),cc_sha256=digest(cc),generated_sha256=digest(source),fixtures=fixtures,commands=[])
    def save():args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
    save()
    try:
        for argv in ([str(goose),'build',str(source),'--standalone',*(['--debug'] if args.debug else []),'--cc',str(cc),'-o',str(binary)],[str(binary)]):
            child=run(argv,ROOT)
            report['commands'].append(child);save()
            if not child['complete'] or child['code']!=0:raise RuntimeError('model command failed')
        lines=report['commands'][-1]['stdout'].splitlines();expected=[f['expected'] for f in fixtures]
        if lines!=expected:
            report['first_mismatch']=next((i for i,(a,b) in enumerate(zip(lines,expected)) if a!=b),min(len(lines),len(expected)))
            raise RuntimeError('wire scheduling model mismatch')
        if {str(x.relative_to(ROOT)):digest(x) for x in inputs}!=frozen or digest(source)!=report['generated_sha256'] or digest(goose)!=report['goose_sha256'] or digest(cc)!=report['cc_sha256']:raise RuntimeError('inputs changed')
        report['binary_sha256']=digest(binary);report['complete']=True
    except BaseException as error:report['error']=repr(error);raise
    finally:save()
    print('wire scheduling model passed:',len(fixtures),'cases')


if __name__=='__main__':main()
