"""System-drive and workspace headroom must be checked before creating data."""
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from pack_collection import PackingError, reserve_space, temporary_work_directory


@unittest.skipUnless(os.name == 'nt', 'Windows system drive reserve')
class DiskReserveTests(unittest.TestCase):
    def test_full_system_drive_blocks_a_workspace_on_another_drive(self):
        def usage(path):
            return SimpleNamespace(free=7*1024**3 if str(path).upper().startswith('C:') else 100*1024**3)
        with patch('pack_collection.shutil.disk_usage',side_effect=usage), patch.dict(os.environ,SystemDrive='C:'):
            with self.assertRaisesRegex(PackingError,'системном диске'):
                reserve_space(Path('G:/workspace'),1024)

    def test_workspace_keeps_512_mib_after_the_requested_output(self):
        with patch('pack_collection.shutil.disk_usage',side_effect=[SimpleNamespace(free=20*1024**3),
                SimpleNamespace(free=1024**3+512*1024**2-1)]):
            with self.assertRaisesRegex(PackingError,'выбранной папке'):
                reserve_space(Path('G:/workspace'),1024**3)

    def test_temporary_directory_is_not_created_when_reserve_is_low(self):
        with patch('pack_collection.shutil.disk_usage',return_value=SimpleNamespace(free=0)), \
                patch('pack_collection.tempfile.mkdtemp') as create:
            with self.assertRaises(PackingError):
                with temporary_work_directory(Path(__file__).parent,'HomeLibre-low-space-'):
                    self.fail('Workspace creation must be refused')
            create.assert_not_called()

    def test_requested_space_and_reserves_are_accepted(self):
        with patch('pack_collection.shutil.disk_usage',side_effect=[SimpleNamespace(free=8*1024**3),
                SimpleNamespace(free=1024**3+512*1024**2)]):
            reserve_space(Path('G:/workspace'),1024**3)
