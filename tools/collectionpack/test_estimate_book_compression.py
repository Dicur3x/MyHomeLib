"""Read-only image sampling and honest aggregation across physical archives."""
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

from estimate_book_compression import (MeasurementBudget, aggregate_estimates,
    estimate_selected_file)
from pack_collection import Canceled, PackingError
from prepare_book_compression import profile_digest
from test_pack_collection import image_fixture, illustrated_fb2, layered_djvu, sha
import test_prepare_book_compression as fixtures


class CompressionEstimateTests(unittest.TestCase):
    setUp = fixtures.SelectedPreparationTests.setUp
    tearDown = fixtures.SelectedPreparationTests.tearDown
    source_zip = fixtures.SelectedPreparationTests.source_zip
    prepare = fixtures.SelectedPreparationTests.prepare

    def estimate(self, source, members, **options):
        return estimate_selected_file(source, members, self.work, fixtures.SEVEN,
            tools_root=fixtures.TOOLS, **options)

    def test_reversible_counts_payloads_separately_from_archive_bytes_without_repacking(self):
        source = self.source_zip({'one.fb2': b'a'*100000, 'two.pdf': b'b'*50000, 'neighbor': b'keep'})
        original = sha(source)
        with patch('prepare_book_compression.prepare_archive_replacement', side_effect=AssertionError('Do not repack')):
            result = self.estimate(source, {'one.fb2': '.fb2', 'two.pdf': '.pdf'}, profile='original')
        self.assertEqual(result['input_bytes'], 150000)
        self.assertEqual(result['output_bytes'], 150000)
        self.assertEqual(result['archive_bytes'], source.stat().st_size)
        self.assertIsNone(result['archive_output_bytes'])
        self.assertEqual(sha(source), original)
        self.assertEqual(list(self.work.iterdir()), [])

    @unittest.skipUnless(fixtures.TOOLS, 'Actual HomeLibre Images runtime required')
    def test_fb2_and_epub_sample_matches_actual_payload_within_ten_percent(self):
        for extension, body in (('.fb2', illustrated_fb2(image_fixture(True))),
                                ('.epub', fixtures.epub(image_fixture(False)))):
            with self.subTest(extension=extension):
                source = self.source_zip({'one'+extension: body, 'neighbor': b'keep'})
                original = sha(source)
                estimated = self.estimate(source, {'one'+extension: extension}, profile='economy', grayscale=True)
                self.assertEqual(sha(source), original)
                self.assertEqual(list(self.work.iterdir()), [])
                prepared = self.prepare(source, {'one'+extension: extension}, profile='economy', grayscale=True)
                actual = prepared.books[0]['output_bytes']
                predicted = estimated['output_bytes']
                self.assertIsNotNone(predicted)
                self.assertLessEqual(abs(predicted-actual)/actual, .10)
                self.assertLess(predicted, len(body))
                self.assertGreater(estimated['books'][0]['sampled'], 0)
                self.assertLess(estimated['books'][0]['seconds'], 10)
                # Only owned candidates are removed; the estimator left none.
                Path(prepared.candidate).unlink()

    @unittest.skipUnless(fixtures.TOOLS, 'Actual HomeLibre Images runtime required')
    def test_maximum_djvu_keeps_payload_length_but_can_make_archive_smaller(self):
        layered = layered_djvu()
        plain = layered_djvu(mask=False)
        source = self.source_zip({'scan.djv': layered, 'photo.djvu': plain, 'neighbor.txt': b'keep'})
        original = sha(source)
        members = {'scan.djv': '.djv', 'photo.djvu': '.djvu'}
        estimated = self.estimate(source, members, profile='maximum')
        self.assertEqual(estimated['unknown_books'], 0)
        self.assertEqual(estimated['output_bytes'], len(layered) + len(plain))
        self.assertEqual(estimated['archive_bytes'], source.stat().st_size)
        self.assertIsNone(estimated['archive_output_bytes'])
        self.assertTrue(all(row['exact'] for row in estimated['books']))
        self.assertTrue(all('архив' in row['reason'] for row in estimated['books']))
        self.assertEqual([row['djvu_background_pages'] for row in estimated['books']], [1, 0])
        self.assertEqual(list(self.work.iterdir()), [])

        prepared = self.prepare(source, members, profile='maximum')
        self.assertTrue(prepared.books[0]['optimized'])
        self.assertFalse(prepared.books[1]['optimized'])
        self.assertEqual([row['output_bytes'] for row in estimated['books']],
                         [row['output_bytes'] for row in prepared.books])
        self.assertLess(prepared.output_bytes, source.stat().st_size)
        self.assertEqual(sha(source), original)

    @unittest.skipUnless(fixtures.TOOLS, 'Actual HomeLibre Images runtime required')
    def test_actual_format_detection_ignores_wrong_catalogue_extension(self):
        source = self.source_zip({'wrong.fb2': fixtures.epub(image_fixture(False))})
        result = self.estimate(source, {'wrong.fb2': '.fb2'}, profile='economy')
        self.assertEqual(result['unknown_books'], 0)
        self.assertGreater(result['books'][0]['sampled'], 0)

    @unittest.skipUnless(fixtures.TOOLS, 'Actual HomeLibre Images runtime required')
    def test_cached_image_result_is_counted_without_second_lossy_encode(self):
        body = illustrated_fb2(image_fixture(True))
        source = self.source_zip({'one.fb2': body})
        import hashlib
        previous = {'one.fb2': dict(profile_sha256=profile_digest('economy', False),
            output_sha256=hashlib.sha256(body).hexdigest())}
        with patch('estimate_book_compression.measure_book', side_effect=AssertionError('Do not reencode')):
            result = self.estimate(source, {'one.fb2': '.fb2'}, profile='economy', previous=previous)
        self.assertEqual(result['output_bytes'], len(body))
        self.assertTrue(result['books'][0]['exact'])

    @unittest.skipUnless(fixtures.TOOLS, 'Actual HomeLibre Images runtime required')
    def test_expired_image_measurement_is_unknown_not_false_zero_or_cancelled_batch(self):
        source = self.source_zip({'one.fb2': illustrated_fb2(image_fixture(True))})
        original = sha(source)
        with patch('estimate_book_compression.measure_book', side_effect=MeasurementBudget('Limit')):
            result = self.estimate(source, {'one.fb2': '.fb2'}, profile='economy')
        self.assertIsNone(result['output_bytes'])
        self.assertEqual(result['known_output_bytes'], 0)
        self.assertEqual(result['unknown_books'], 1)
        self.assertIn('Limit', result['books'][0]['reason'])
        self.assertEqual(sha(source), original)
        self.assertEqual(list(self.work.iterdir()), [])

    @unittest.skipUnless(fixtures.TOOLS, 'Actual HomeLibre Images runtime required')
    def test_stop_during_sampling_removes_temporary_files_and_preserves_source(self):
        source = self.source_zip({'one.fb2': illustrated_fb2(image_fixture(True))})
        original = sha(source)
        with patch('estimate_book_compression.measure_book', side_effect=Canceled('Stop')):
            with self.assertRaises(Canceled):
                self.estimate(source, {'one.fb2': '.fb2'}, profile='economy')
        self.assertEqual(sha(source), original)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_missing_member_does_not_turn_into_a_different_book(self):
        source = self.source_zip({'neighbor.txt': b'keep'})
        with self.assertRaisesRegex(PackingError, 'точный файл'):
            self.estimate(source, {'missing.fb2': '.fb2'}, profile='original')
        self.assertEqual(list(self.work.iterdir()), [])

    def test_empty_book_is_unknown_instead_of_a_successful_zero_byte_result(self):
        source = self.source_zip({'empty.fb2': b'', 'neighbor': b'keep'})
        result = self.estimate(source, {'empty.fb2': '.fb2'}, profile='original')
        self.assertEqual(result['unknown_books'], 1)
        self.assertIsNone(result['output_bytes'])
        self.assertIn('пуст', result['books'][0]['reason'])

    def test_invalid_time_limits_fail_before_source_processing(self):
        source = self.source_zip({'one.txt': b'keep'})
        for limit in (False, 0, 11, -1, math.nan, math.inf, '10'):
            with self.subTest(limit=limit), self.assertRaises(PackingError):
                self.estimate(source, {'one.txt': '.txt'}, profile='original', book_seconds=limit)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_aggregate_retains_known_subset_and_does_not_sum_unknown_as_zero(self):
        first = dict(source=str(self.root/'first.zip'), size_basis='selected-book-payloads', archive_bytes=50,
            books=[dict(input_bytes=100, output_bytes=70), dict(input_bytes=200, output_bytes=None)])
        second = dict(source=str(self.root/'second.7z'), size_basis='selected-book-payloads', archive_bytes=20,
            books=[dict(input_bytes=80, output_bytes=80)])
        result = aggregate_estimates([first, second])
        self.assertEqual((result['files'],result['books'],result['archive_bytes']), (2,3,70))
        self.assertEqual(result['input_bytes'], 380)
        self.assertEqual(result['known_input_bytes'], 180)
        self.assertEqual(result['known_output_bytes'], 150)
        self.assertIsNone(result['output_bytes'])
        self.assertIsNone(result['archive_output_bytes'])
        with self.assertRaises(PackingError):
            aggregate_estimates([first, first])
        if os.name == 'nt':
            with self.assertRaises(PackingError):
                aggregate_estimates([first, dict(first, source=first['source'].upper())])
        with self.assertRaises(PackingError):
            aggregate_estimates([dict(second, size_basis='physical-archive')])

    def test_cli_publishes_read_only_measurement_then_refuses_report_overwrite(self):
        source = self.source_zip({'one.txt': b'keep'*1000})
        report, request = self.root/'report.json', self.root/'request.json'
        request.write_text(json.dumps(dict(version=1, source=str(source), members={'one.txt':'.txt'},
            workspace=str(self.work), seven_zip=str(fixtures.SEVEN), profile='original', report=str(report))), encoding='utf-8')
        command = [sys.executable, '-B', str(Path(__file__).with_name('estimate_book_compression.py')), '--job', str(request)]
        process = subprocess.run(command, capture_output=True, timeout=20)
        self.assertEqual(process.returncode, 0, process.stdout+process.stderr)
        self.assertEqual(json.loads(report.read_text(encoding='utf-8'))['output_bytes'], 4000)
        report.write_bytes(b'Keep existing report')
        process = subprocess.run(command, capture_output=True, timeout=20)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(report.read_bytes(), b'Keep existing report')
        self.assertEqual(list(self.work.iterdir()), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
