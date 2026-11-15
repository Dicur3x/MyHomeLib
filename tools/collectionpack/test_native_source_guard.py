"""Refuse an unexpected archive before approving a real-catalogue copy trial."""
import json
import os
from pathlib import Path
import unittest

from supervised_test_process import run_owned
import test_native_compression_operation as operations


@unittest.skipUnless(os.name == 'nt' and operations.OPERATOR and operations.OPERATOR.is_file()
                     and operations.RUNTIME, 'Built native operation and isolated runtime required')
class AllowedSourceGuardTests(unittest.TestCase):
    def setUp(self):
        self.op = operations.NativeCompressionOperationTests()
        self.op.setUp()
        self.addCleanup(self.op.tearDown)
        self.op.config.update(operation_mode='review-apply', allowed_source=str(self.op.fixture.source))

    def test_expected_source_is_checked_before_approval(self):
        result = self.op.run_operation()
        self.assertTrue(result['allowed_source_verified'], result)
        self.op.assert_applied(result)

    def test_unexpected_source_stops_without_source_or_store_writes(self):
        self.op.config['allowed_source'] = str(self.op.root/'not-the-selected-source.zip')
        self.op.request.write_text(json.dumps(self.op.config), encoding='utf-8')
        process = run_owned([str(operations.OPERATOR), str(self.op.request), str(self.op.result)],
            capture_output=True, encoding='utf-8', errors='strict', timeout=45)
        self.assertEqual(process.returncode, 1, process.stdout+process.stderr)
        self.assertIn('Refusing write outside the allowed test source.', process.stdout)
        self.op.unchanged()
        self.assertFalse(list(Path(self.op.config['work_root']).glob('prepare-*')))
