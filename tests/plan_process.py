# SPDX-License-Identifier: Apache-2.0
"""Linux-only test runner: finite capture and owned process-group cleanup."""
import os
import selectors
import signal
import subprocess
import time


def run(argv,cwd,timeout=180,cap=8*1024*1024):
    record=dict(argv=list(map(str,argv)),complete=False,code=None,stdout='',stderr='')
    process=None;pidfd=None;selector=selectors.DefaultSelector();buffers={'stdout':bytearray(),'stderr':bytearray()}
    def kill_group():
        try:os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError:pass
    try:
        process=subprocess.Popen(record['argv'],cwd=cwd,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        pidfd=os.pidfd_open(process.pid);selector.register(pidfd,selectors.EVENT_READ,'exit')
        for name in buffers:
            stream=getattr(process,name);os.set_blocking(stream.fileno(),False);selector.register(stream,selectors.EVENT_READ,name)
        deadline=time.monotonic()+timeout;streams=2;exited=False
        while streams or not exited:
            left=deadline-time.monotonic()
            if left<=0:raise TimeoutError('finite model command deadline exceeded')
            for key,_ in selector.select(left):
                if key.data=='exit':
                    exited=True;selector.unregister(pidfd)
                    # Keep the terminal leader unreaped until group cleanup;
                    # its reserved PID/group cannot be reused for another job.
                    kill_group();continue
                data=os.read(key.fileobj.fileno(),65536)
                if not data:selector.unregister(key.fileobj);streams-=1;continue
                buffer=buffers[key.data];remaining=cap-len(buffer);buffer.extend(data[:remaining])
                if len(data)>remaining:raise RuntimeError('model command output cap exceeded')
        record['complete']=True
    except BaseException as error:record['error']=repr(error)
    finally:
        if process is not None:
            try:kill_group();process.wait(timeout=5)
            except BaseException as error:record['cleanup_error']=repr(error);record['complete']=False
            record['code']=process.returncode
        for name,data in buffers.items():record[name]=data.decode('utf-8',errors='backslashreplace')
        selector.close()
        if pidfd is not None:os.close(pidfd)
        if process is not None:
            process.stdout.close();process.stderr.close()
    return record
