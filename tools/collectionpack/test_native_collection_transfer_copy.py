"""Verified file-copy journal, process crashes and ownership on private NTFS data."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import time
import unittest
import zipfile

from pack_collection import temporary_work_directory, process_working_directory


BINARY = Path(os.environ['HL_TRANSFER_COPY']) if os.environ.get('HL_TRANSFER_COPY') else None
SQLITE = Path(os.environ['HL_TRANSFER_SQLITE']) if os.environ.get('HL_TRANSFER_SQLITE') else None
STAGE = Path(os.environ['HL_TRANSFER_STAGE']) if os.environ.get('HL_TRANSFER_STAGE') else None


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


@unittest.skipUnless(os.name == 'nt' and BINARY and BINARY.is_file() and SQLITE and SQLITE.is_file() and STAGE,
                     'requires native copier, SQLite and owned stage')
class TransferCopyTests(unittest.TestCase):
    attempts = crashes = 0

    def setUp(self):
        self.owned = temporary_work_directory(STAGE, 'HomeLibRu-native-')
        self.root = Path(self.owned.__enter__())
        self.binary = self.root / 'CollectionTransferCopyTest.exe'
        shutil.copy2(BINARY, self.binary)
        shutil.copy2(SQLITE, self.root / 'sqlite3.dll')
        for name in ('uselocaldata', 'uselocaltemp'):
            (self.root / name).touch()
        (self.root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
        for name in ('source', 'output', 'work', 'cases'):
            (self.root / name).mkdir()
        self.source = self.root / 'source/same.zip'
        with zipfile.ZipFile(self.source, 'w', zipfile.ZIP_STORED) as archive:
            archive.writestr('101.fb2', b'<FictionBook><body>' + bytes(range(256)) * 8192 + b'</body></FictionBook>')
        self.before = sha(self.source)
        self.config = self.case('normal')

    def tearDown(self):
        root = self.root
        for path in root.rglob('*'):
            if path.is_file() and not path.is_symlink():
                path.chmod(stat.S_IREAD | stat.S_IWRITE)
        self.owned.__exit__(None, None, None)
        self.assertFalse(root.exists(), 'owned copy runtime remained')

    def case(self, name):
        case = self.root / 'cases' / name
        case.mkdir(exist_ok=False)
        return dict(source=str(self.source), destination=str(self.root / 'output' / name / 'same.zip'),
                    root=str(self.root / 'output'), work=str(self.root / 'work'), attempt=str(case / 'attempt.json'),
                    request=str(case / 'request.json'), result=str(case / 'result.json'))

    def command(self, config):
        Path(config['request']).write_text(json.dumps(config), encoding='utf-8')
        Path(config['result']).unlink(missing_ok=True)
        type(self).attempts += 1
        return [str(self.binary), config['request'], config['result']]

    def run_case(self, config=None, expected=0):
        config = self.config if config is None else config
        result = subprocess.run(self.command(config), cwd=self.root, capture_output=True, timeout=45,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ, 'TEMP': str(self.root), 'TMP': str(self.root)})
        evidence = dict(test=self.id(), expected=expected, returncode=result.returncode,
                        request=dict(config), output=(result.stdout + result.stderr).decode('utf-8', errors='replace'))
        if Path(config['attempt']).exists():
            attempt = self.attempt(config)
            evidence['attempt'] = attempt
            directory = Path(attempt['directory']).resolve()
            self.assertTrue(directory.is_relative_to(self.root.resolve()))
            evidence['states'] = [json.loads(p.read_text(encoding='utf-8')) for p in sorted(directory.glob('state-*.json'))]
        with (STAGE / 'invocations.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(evidence, ensure_ascii=False) + '\n')
        if expected == 'fail':
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(Path(config['result']).exists())
        else:
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        if result.returncode == 97:
            type(self).crashes += 1
        if expected == 0:
            data = json.loads(Path(config['result']).read_text(encoding='utf-8-sig'))
            self.assertEqual(data['status'], 'PASS')
            self.assertEqual(data['sha256'], sha(config['source']))
            self.assertEqual(sha(config['destination']), data['sha256'])
            self.assertEqual(sha(self.source), self.before)
            return data
        return result

    def resume(self, config=None, **extra):
        config = self.config if config is None else config
        values = dict(resume=True, crash='', cancel_copy=False, occupy_destination=False, occupy_temporary=False)
        values.update(extra)
        config.update(values)
        return config

    def attempt(self, config=None):
        return json.loads(Path((config or self.config)['attempt']).read_text(encoding='utf-8-sig'))

    def state(self, config=None):
        directory = Path(self.attempt(config)['directory'])
        record = sorted(directory.glob('state-*.json'))[-1]
        return json.loads(json.loads(record.read_text(encoding='utf-8'))['payload'])

    def temporary(self, config=None):
        config = config or self.config
        return Path(config['destination']).parent / self.state(config)['temporary']

    def test_normal_copy_preserves_named_streams_and_file_time(self):
        streams = {':Zone.Identifier': b'[ZoneTransfer]\r\nZoneId=3\r\n', ':HomeLibreNote': 'личные данные'.encode()}
        for name, body in streams.items():
            Path(str(self.source) + name).write_bytes(body)
        before = self.source.stat()
        data = self.run_case()
        target = Path(self.config['destination'])
        self.assertEqual(target.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(len(json.loads(data['streams'])), 3)
        for name, body in streams.items():
            self.assertEqual(Path(str(target) + name).read_bytes(), body)
            self.assertEqual(Path(str(self.source) + name).read_bytes(), body)
        self.assertFalse(list(target.parent.glob('.homelib-transfer-*.tmp')))

    def test_ready_resume_does_not_copy_or_rewrite_payload(self):
        self.run_case()
        target = Path(self.config['destination'])
        before = (target.stat().st_ino, target.stat().st_mtime_ns, sha(target))
        data = self.run_case(self.resume())
        self.assertEqual(data['copy_streams'], 0)
        self.assertEqual((target.stat().st_ino, target.stat().st_mtime_ns, sha(target)), before)

    def test_keep_in_place_reads_without_copying(self):
        self.config.update(root=str(self.source.parent), destination=str(self.source))
        before = self.source.stat()
        data = self.run_case()
        self.assertEqual(data['copy_streams'], 0)
        self.assertEqual(self.source.stat().st_ino, before.st_ino)
        self.assertEqual(self.source.stat().st_mtime_ns, before.st_mtime_ns)

    def test_empty_file(self):
        self.source.write_bytes(b'')
        self.before = sha(self.source)
        self.run_case()

    def test_read_only_flag_is_preserved(self):
        self.source.chmod(stat.S_IREAD)
        self.run_case()
        self.assertTrue(Path(self.config['destination']).stat().st_file_attributes & stat.FILE_ATTRIBUTE_READONLY)
        self.assertTrue(self.source.stat().st_file_attributes & stat.FILE_ATTRIBUTE_READONLY)

    def test_two_same_names_keep_both_payloads(self):
        first = self.run_case()
        other = self.root / 'source/other/same.zip'
        other.parent.mkdir()
        other.write_bytes(b'another archive payload')
        config = self.case('other')
        config['source'] = str(other)
        second = self.run_case(config)
        self.assertNotEqual(first['destination'], second['destination'])
        self.assertNotEqual(first['sha256'], second['sha256'])

    def test_real_cross_volume_copy_preserves_named_streams(self):
        configured = os.environ.get('HL_TRANSFER_SOURCE_VOLUME')
        if not configured:
            self.skipTest('set HL_TRANSFER_SOURCE_VOLUME to a dedicated second NTFS drive root')
        volume = Path(configured)
        self.assertTrue(volume.is_absolute() and len(volume.drive) == 2 and volume == Path(volume.anchor),
                        'HL_TRANSFER_SOURCE_VOLUME must be a drive root')
        self.assertNotIn(volume.drive.upper(), {'C:', self.root.drive.upper()},
                         'use a separate test volume for the source')
        self.assertGreater(shutil.disk_usage(volume).free, 512 * 1024**2)
        with temporary_work_directory(volume, 'HomeLibRu-native-source-') as value:
            external = Path(value)
            (external / 'transfer-source.marker').write_bytes(
                ('HomeLibre isolated transfer source v1' + os.linesep + str(self.root)).encode('utf-8'))
            source = external / 'same.zip'
            shutil.copy2(self.source, source)
            Path(str(source) + ':HomeLibreNote').write_bytes(b'cross-volume note')
            self.config.update(source=str(source), external_source_root=str(external))
            data = self.run_case()
            self.assertNotEqual(self.attempt()['identity'].split(':')[0], data['identity'].split(':')[0])
            self.assertEqual(Path(self.config['destination'] + ':HomeLibreNote').read_bytes(), b'cross-volume note')
            self.assertEqual(sha(source), self.before)
            self.run_case(self.resume())
        self.assertFalse(external.exists(), 'private cross-volume source remained')

    def test_all_copy_crash_boundaries_resume(self):
        for point in ('after-attempt-intent', 'after-temp-created', 'after-temp-identity',
                      'copy-stream-start', 'copy-chunk', 'after-copy', 'after-verified', 'after-publish', 'after-ready'):
            with self.subTest(point=point):
                config = self.case(point)
                config['crash'] = point
                self.run_case(config, 97)
                self.assertEqual(sha(self.source), self.before)
                data = self.run_case(self.resume(config))
                if point in ('after-verified', 'after-publish', 'after-ready'):
                    self.assertEqual(data['copy_streams'], 0)
                leftovers = list(Path(config['destination']).parent.glob('.homelib-transfer-*.tmp'))
                if point == 'after-temp-created':
                    self.assertEqual(len(leftovers), 1)
                    self.assertEqual(leftovers[0].stat().st_size, 0)  # No recorded ID: preserve, never adopt.
                else:
                    self.assertFalse(leftovers)

    def test_second_crash_during_recovery_preserves_publication(self):
        self.config['crash'] = 'after-publish'
        self.run_case(expected=97)
        target = Path(self.config['destination'])
        identity = target.stat().st_ino
        config = self.resume(crash='after-resume-verified')
        self.run_case(config, 97)
        data = self.run_case(self.resume())
        self.assertEqual(data['copy_streams'], 0)
        self.assertEqual(target.stat().st_ino, identity)

    def test_resume_when_verified_temporary_is_missing(self):
        self.config['crash'] = 'after-verified'
        self.run_case(expected=97)
        self.assertEqual(self.state()['phase'], 'verified')
        temporary = self.temporary()
        self.assertEqual(sha(temporary), self.before)
        self.assertFalse(Path(self.config['destination']).exists())
        temporary.unlink()
        resumed = self.run_case(self.resume())
        self.assertGreater(resumed['copy_streams'], 0)
        self.assertEqual(self.state()['phase'], 'ready')

    def test_missing_published_copy_is_reported(self):
        self.run_case()
        self.assertEqual(self.state()['phase'], 'ready')
        target = Path(self.config['destination'])
        target.unlink()
        self.run_case(self.resume(), 'fail')
        self.assertFalse(target.exists())
        self.assertEqual(sha(self.source), self.before)

    def test_read_only_flag_recovers_after_publication_crash(self):
        self.source.chmod(stat.S_IREAD)
        self.config['crash'] = 'after-publish'
        self.run_case(expected=97)
        self.run_case(self.resume())
        self.assertTrue(Path(self.config['destination']).stat().st_file_attributes & stat.FILE_ATTRIBUTE_READONLY)

    def test_cancelled_copy_retains_source_and_can_resume(self):
        self.config['cancel_copy'] = True
        self.run_case(expected='fail')
        self.assertEqual(sha(self.source), self.before)
        self.assertFalse(Path(self.config['destination']).exists())
        self.run_case(self.resume())

    def test_source_byte_change_with_same_size_date_and_id_is_detected(self):
        self.config['crash'] = 'copy-stream-start'
        self.run_case(expected=97)
        stamp = self.source.stat()
        body = bytearray(self.source.read_bytes())
        body[-1] ^= 1
        self.source.write_bytes(body)
        os.utime(self.source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        modified = sha(self.source)
        self.assertNotEqual(modified, self.before)
        self.run_case(self.resume(), 'fail')
        self.assertEqual(sha(self.source), modified)
        self.assertFalse(Path(self.config['destination']).exists())

    def test_foreign_replacement_of_partial_is_preserved(self):
        self.config['crash'] = 'after-temp-identity'
        self.run_case(expected=97)
        temporary = self.temporary()
        temporary.unlink()
        temporary.write_bytes(b'foreign file, different ID')
        self.run_case(self.resume(), 'fail')
        self.assertEqual(temporary.read_bytes(), b'foreign file, different ID')
        self.assertEqual(sha(self.source), self.before)

    def test_racing_foreign_destination_is_not_overwritten(self):
        self.config['occupy_destination'] = True
        self.run_case(expected='fail')
        target = Path(self.config['destination'])
        self.assertEqual(target.read_text(encoding='utf-8-sig'), 'foreign fixture result')
        self.run_case(self.resume(), 'fail')
        self.assertEqual(target.read_text(encoding='utf-8-sig'), 'foreign fixture result')
        self.assertEqual(sha(self.source), self.before)

    def test_existing_foreign_destination_is_preserved(self):
        target = Path(self.config['destination'])
        target.parent.mkdir()
        target.write_bytes(b'keep existing')
        self.run_case(expected='fail')
        self.assertEqual(target.read_bytes(), b'keep existing')
        self.assertEqual(sha(self.source), self.before)

    def test_unknown_temporary_is_retained_and_fresh_attempt_succeeds(self):
        self.config['occupy_temporary'] = True
        self.run_case(expected='fail')
        foreign = self.temporary()
        self.assertEqual(foreign.read_text(encoding='utf-8-sig'), 'foreign fixture temporary')
        self.run_case(self.resume())
        self.assertEqual(foreign.read_text(encoding='utf-8-sig'), 'foreign fixture temporary')

    def test_modified_ready_payload_is_never_replaced(self):
        self.run_case()
        target = Path(self.config['destination'])
        stamp = target.stat()
        body = bytearray(target.read_bytes())
        body[-1] ^= 1
        target.write_bytes(body)
        os.utime(target, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        modified = sha(target)
        self.run_case(self.resume(), 'fail')
        self.assertEqual(sha(target), modified)
        self.assertEqual(sha(self.source), self.before)

    def test_modified_named_stream_is_detected(self):
        Path(str(self.source) + ':HomeLibreNote').write_bytes(b'original note')
        self.run_case()
        target = Path(self.config['destination'])
        stream = Path(str(target) + ':HomeLibreNote')
        stream.write_bytes(b'changed note')
        self.run_case(self.resume(), 'fail')
        self.assertEqual(stream.read_bytes(), b'changed note')
        self.assertEqual(sha(target), self.before)

    def test_corrupt_completed_state_is_rejected_without_falling_back(self):
        self.run_case()
        records = sorted(Path(self.attempt()['directory']).glob('state-*.json'))
        record = json.loads(records[-1].read_text(encoding='utf-8'))
        record['sha256'] = '0' * 64
        records[-1].write_text(json.dumps(record), encoding='utf-8')
        self.run_case(self.resume(), 'fail')
        self.assertEqual(sha(self.source), self.before)
        self.assertEqual(sha(self.config['destination']), self.before)

    def test_different_destination_binding_is_rejected(self):
        self.config['crash'] = 'after-temp-identity'
        self.run_case(expected=97)
        attempt = self.attempt()
        other = self.root / 'output/another.zip'
        attempt['destination'] = str(other)
        Path(self.config['attempt']).write_text(json.dumps(attempt), encoding='utf-8')
        self.run_case(self.resume(), 'fail')
        self.assertFalse(other.exists())
        self.assertEqual(sha(self.source), self.before)

    def test_source_open_for_write_prevents_copying(self):
        with self.source.open('r+b'):
            self.run_case(expected='fail')
        self.assertFalse(Path(self.config['destination']).exists())
        self.assertEqual(sha(self.source), self.before)

    def test_long_unicode_source_and_destination(self):
        directory = self.root.joinpath('source', *(['длинная папка с книгами'] * 10))
        directory.mkdir(parents=True)
        source = directory / 'same.zip'
        shutil.copy2(self.source, source)
        self.config['source'] = str(source)
        target = self.root.joinpath('output', *(['другая длинная папка'] * 12), 'same.zip')
        self.config['destination'] = str(target)
        self.assertGreater(len(str(source)), 300)
        self.assertGreater(len(str(target)), 300)
        self.run_case()

    def test_destination_directory_junction_is_rejected(self):
        directory = self.root.joinpath('output', *(['long folder for an alias'] * 10))
        directory.mkdir(parents=True)
        with process_working_directory(directory) as alias:
            self.config['destination'] = str(Path(alias) / 'same.zip')
            self.run_case(expected='fail')
            self.assertFalse((directory / 'same.zip').exists())
        self.assertFalse(Path(alias).exists())
        self.assertEqual(sha(self.source), self.before)

    def test_foreign_uncommitted_record_is_retained(self):
        self.config['crash'] = 'after-verified'
        self.run_case(expected=97)
        foreign = Path(self.attempt()['directory']) / '.state-foreign.tmp'
        foreign.write_bytes(b'foreign metadata')
        self.run_case(self.resume())
        self.assertEqual(foreign.read_bytes(), b'foreign metadata')

    def test_journal_has_one_writer(self):
        self.config['crash'] = 'after-attempt-intent'
        self.run_case(expected=97)
        release = self.root / 'release.txt'
        first_config = self.resume(wait_for_release=str(release))
        process = subprocess.Popen(self.command(first_config), cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ, 'TEMP': str(self.root), 'TMP': str(self.root)})
        try:
            deadline = time.monotonic() + 15
            while not Path(str(release) + '.waiting').exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertTrue(Path(str(release) + '.waiting').exists())
            second = dict(first_config, wait_for_release='')
            second['request'] = str(self.root / 'second-request.json')
            second['result'] = str(self.root / 'second-result.json')
            self.run_case(second, 'fail')
            release.touch()
            output = process.communicate(timeout=45)[0]
            self.assertEqual(process.returncode, 0, output)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
        self.assertEqual(sha(self.config['destination']), self.before)
        self.assertEqual(sha(self.source), self.before)


if __name__ == '__main__':
    unittest.main()
