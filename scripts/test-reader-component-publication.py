"""Regression for the permanent component publication contract (no downloads)."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('reader_packages', Path(__file__).with_name('package-reader-components.py'))
packages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packages)


class PublicationContract(unittest.TestCase):
    def test_permanent_destination(self):
        self.assertEqual(packages.publication_tag('optional-alreader-2.5.1009.25'),
                         'optional-alreader-2.5.1009.25')

    def test_application_tag_rejected_before_build_or_output_access(self):
        for component in ('HomeLibReader', 'PDFium', 'BookConverter'):
            for tag in ('2.7.0_pre5.35', '2.7.0_pre5.36', '', '../release'):
                with self.subTest(component=component, tag=tag):
                    with self.assertRaisesRegex(ValueError, 'permanent component release'):
                        packages.package(Path('missing-runtime'), 'Win64', component,
                                         tag, '2.7.0.1103', Path('missing-output'))


if __name__ == '__main__':
    unittest.main()
