# SPDX-License-Identifier: Apache-2.0
"""Provenance regressions without compiler invocations or timing runs."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import measure
import provenance


class BinaryProvenance(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        (self.root/'GOOSE_REVISION').write_text('a'*40)
        (self.root/'msgpack.goose').write_text('working library')
        self.frozen=self.root/'frozen/msgpack.goose';self.frozen.parent.mkdir();self.frozen.write_text('frozen library')
        self.harness=self.root/'bench/bench.goose';self.harness.parent.mkdir();self.harness.write_text('harness')
        self.binary=self.root/'baseline';self.binary.write_bytes(b'baseline executable fixture')
        self.competitor=self.root/'competitor';self.competitor.write_bytes(b'competitor executable fixture')
        for binary in (self.binary,self.competitor):
            record={'schema':1,'binary_sha256':provenance.sha256_file(binary),
                    'compiler':{'path':'/recorded/gcc','version':'recorded GCC','sha256':'b'*64},
                    'sources':[{'path':str(p),'sha256':provenance.sha256_file(p)} for p in (self.frozen,self.harness)],
                    'flags':['-O2'],'goose':None,'goose_sha256':None}
            provenance.write(binary,record)
        self.patch=patch.multiple(measure,ROOT=self.root,COMPETITOR=self.competitor)
        self.patch.start();self.addCleanup(self.patch.stop)

    def test_selected_binary_record_overrides_environment_guesses(self):
        with patch.dict('os.environ',{'CC':'clang','BENCH_BINARY':'/wrong/binary'}):
            result=measure.provenance(self.binary)
        self.assertEqual(result['cc'],'/recorded/gcc')
        self.assertEqual(result['cc_version'],'recorded GCC')
        self.assertEqual(result['library_sha256'],provenance.sha256_file(self.frozen))
        self.assertNotEqual(result['library_sha256'],provenance.sha256_file(self.root/'msgpack.goose'))
        self.assertEqual(result['bench_binary_sha256'],provenance.sha256_file(self.binary))

    def test_missing_sidecar_is_rejected(self):
        provenance.sidecar(self.binary).unlink()
        with self.assertRaisesRegex(SystemExit,'build record'):measure.provenance(self.binary)

    def test_replaced_binary_is_rejected(self):
        self.binary.write_bytes(b'different executable')
        with self.assertRaisesRegex(SystemExit,'build record'):measure.provenance(self.binary)

    def test_changed_recorded_source_is_rejected(self):
        self.frozen.write_text('changed after build')
        with self.assertRaisesRegex(SystemExit,'source'):measure.provenance(self.binary)

    def test_competitor_record_is_checked_too(self):
        self.competitor.write_bytes(b'different competitor')
        with self.assertRaisesRegex(SystemExit,'build record'):measure.provenance(self.binary)

    def test_legacy_reports_without_build_records_are_rejected(self):
        report=self.root/'old-report.json';report.write_text(json.dumps({'samples':20,'rows':[]}))
        with self.assertRaisesRegex(SystemExit,'provenance'):measure.compare([report,report])


if __name__=='__main__':unittest.main()
