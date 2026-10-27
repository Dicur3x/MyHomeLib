import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ibk_input_tested', ROOT / 'ibk_input.py')
ibk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ibk)
c = ibk.crypto()


def word(text):
    raw = text.encode('utf-16-le')
    units = len(raw) // 2
    assert 0 < units < 128
    return bytes([units]) + raw


def node(identity, data=b'', children=()):
    assert identity < 256 and len(data) < 59
    return bytes([len(data), identity]) + data + b''.join(children) + b'\xff'


def block(data):
    return data + c.checksum(data, c.format_data()[1][2])


def plain_container(text, bad_offset=False, protected=False, compressed=None):
    entries = []
    body = bytearray(ibk.MAGIC)

    def add(name, data, logical=None, options=0, descriptor=1):
        offset = len(body)
        stored = block(data)
        body.extend(stored)
        if bad_offset and name == 'Text':
            offset = 2 ** 63
        record = struct.pack('<QIHHHB', len(data) if logical is None else logical, 1, len(name), 0, 0, options)
        record += name.encode('utf-16-le') + bytes([descriptor]) + struct.pack('<QQ', offset, len(stored))
        entries.append(record)

    if protected:
        params = c.format_data()[0]
        info = node(0, children=[node(1, b'\x02'), node(2, b'\x01'), node(3, bytes.fromhex(params['book_profile_uuid_le'])),
                                 node(5, b'\x04\0\0\0\x01\0\x01\0'), node(8, b'\x01')])
        add('Info', info)
    add('Text', text if compressed is None else compressed, logical=len(text), options=128 if protected else 0,
        descriptor=129 if compressed is not None else 1)
    table = b'ICE1' + struct.pack('<IIB', 0, len(entries), 1) + b''.join(entries)
    stored = block(table)
    body.extend(stored)
    body.extend(block(struct.pack('<4sIIQ', b'ICE1', len(stored), 0, 16)))
    return bytes(body)


class IBKTests(unittest.TestCase):
    def test_plain_book_needs_no_original_runtime(self):
        raw = plain_container(word('Привет') + b'\xf0' + word('мир') + b'\0' + word('Вторая строка'))
        with tempfile.TemporaryDirectory(prefix='homelib-ibk-test-') as folder:
            text, metadata = ibk.Container(raw).text_and_metadata(Path(folder))
        self.assertEqual(ibk.paragraphs(text), ['Привет мир', 'Вторая строка'])
        self.assertEqual(metadata, {})

    def test_format_change_does_not_split_a_word(self):
        self.assertEqual(ibk.paragraphs(word('г') + b'\x80' + word('лава')), ['глава'])

    def test_unicode_surrogate_pair_and_blank_paragraph(self):
        self.assertEqual(ibk.paragraphs(word('A🙂Б') + b'\0\0' + word('Конец')), ['A🙂Б', '', 'Конец'])

    def test_unknown_record_is_not_silently_discarded(self):
        with self.assertRaisesRegex(c.IBKError, 'неизвестный элемент'):
            ibk.paragraphs(word('Начало') + b'\xf1' + word('Конец'))

    def test_truncated_word_is_not_returned_as_partial_book(self):
        with self.assertRaisesRegex(c.IBKError, 'Обрезано слово'):
            ibk.paragraphs(b'\x04A\0')

    def test_bad_utf16_is_rejected(self):
        with self.assertRaisesRegex(c.IBKError, 'UTF-16'):
            ibk.paragraphs(b'\x01\x00\xd8')

    def test_control_character_is_rejected(self):
        with self.assertRaisesRegex(c.IBKError, 'управляющие'):
            ibk.paragraphs(word('Текст\x01'))

    def test_bad_text_checksum_is_rejected(self):
        raw = bytearray(plain_container(word('Исходная книга')))
        raw[20] ^= 1
        container = ibk.Container(bytes(raw))
        with tempfile.TemporaryDirectory(prefix='homelib-ibk-test-') as folder:
            with self.assertRaisesRegex(c.IBKError, 'контрольная сумма'):
                container.text_and_metadata(Path(folder))

    def test_directory_range_is_bounded(self):
        with self.assertRaisesRegex(c.IBKError, 'границы'):
            ibk.Container(plain_container(word('Книга'), bad_offset=True))

    def test_compression_limit_and_trailing_data(self):
        import bz2
        stream = bz2.compress(b'A' * 1000)
        with self.assertRaises(c.IBKError):
            ibk.expand(stream, 100)
        with self.assertRaises(c.IBKError):
            ibk.expand(stream + b'extra', 1000)
        self.assertEqual(ibk.expand(stream, 1000), b'A' * 1000)

    def test_duplicate_metadata_and_depth_are_bounded(self):
        with self.assertRaisesRegex(c.IBKError, 'Повторяется'):
            c.record_tree(node(0, children=[node(1), node(1)]))
        raw = node(1)
        for _ in range(18):
            raw = node(0, children=[raw])
        with self.assertRaisesRegex(c.IBKError, 'Слишком сложная'):
            c.record_tree(raw)

    def test_missing_runtime_is_distinct_from_a_bad_book(self):
        raw = plain_container(word('Книга'), protected=True)
        with tempfile.TemporaryDirectory(prefix='homelib-ibk-test-') as folder:
            with self.assertRaises(c.RuntimeRequired):
                ibk.Container(raw).text_and_metadata(Path(folder))

    def test_program_or_personal_key_is_never_executed_or_replaced(self):
        with tempfile.TemporaryDirectory(prefix='homelib-ibk-test-') as folder:
            runtime = Path(folder) / 'ibk'
            runtime.mkdir()
            program = runtime / 'ICEReaderRus.exe'
            program.write_bytes(b'not an executable to run')
            key = runtime / 'Rus.key'
            key.write_bytes(b'personal registration must not be read as a supported package')
            before = (program.read_bytes(), key.read_bytes())
            with self.assertRaises(c.RuntimeRequired):
                c.runtime_profile(Path(folder))
            self.assertEqual(before, (program.read_bytes(), key.read_bytes()))


if __name__ == '__main__':
    unittest.main()
