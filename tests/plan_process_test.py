# SPDX-License-Identifier: Apache-2.0
import sys
import tempfile
import unittest
from plan_process import run


class ProcessTests(unittest.TestCase):
    def test_launch_failure_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            row=run(['/does/not/exist/model-command'],root)
            self.assertFalse(row['complete']);self.assertIn('FileNotFoundError',row['error'])

    def test_timeout_preserves_output(self):
        with tempfile.TemporaryDirectory() as root:
            row=run([sys.executable,'-c','import time;print("before",flush=True);time.sleep(10)'],root,timeout=1)
            self.assertFalse(row['complete']);self.assertIn('deadline',row['error']);self.assertEqual(row['stdout'],'before\n');self.assertIsNotNone(row['code'])

    def test_timeout_stops_owned_child_group(self):
        with tempfile.TemporaryDirectory() as root:
            program='import subprocess,sys,time; p=subprocess.Popen([sys.executable,"-c","import time;time.sleep(10)"]); print(p.pid,flush=True);time.sleep(10)'
            row=run([sys.executable,'-c',program],root,timeout=1)
            self.assertFalse(row['complete']);self.assertIn('deadline',row['error'])
            pid=int(row['stdout'].strip())
            from pathlib import Path
            try:
                text=Path(f'/proc/{pid}/stat').read_text();state=text[text.rfind(')')+2:].split()[0]
                self.assertEqual(state,'Z') # A non-parent cannot reap an orphan.
            except (FileNotFoundError,ProcessLookupError):pass

    def test_output_cap(self):
        with tempfile.TemporaryDirectory() as root:
            row=run([sys.executable,'-c','print("x"*1000)'],root,cap=64)
            self.assertFalse(row['complete']);self.assertIn('output cap',row['error']);self.assertEqual(len(row['stdout']),64)


if __name__=='__main__':unittest.main()
