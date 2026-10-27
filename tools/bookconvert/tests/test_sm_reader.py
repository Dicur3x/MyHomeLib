import copy
import base64
import ctypes
from ctypes import wintypes
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET
import zipfile
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import convert_book
from sm_input import Story, StoryError
from sm_reader import ReaderSession, NOTICE, atomic_json, plain_label, validate_frame, write_document
from sm_resources import StoryResources, MissingStoryImage
from test_sm_input import source
from test_conversion import PNG, png_chunk


@contextmanager
def deny_delete(path):
    """Reproduce a native Windows reader which does not share file deletion."""
    api = ctypes.WinDLL('kernel32.dll', use_last_error=True, winmode=0x800)
    api.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                               wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    api.CreateFileW.restype = wintypes.HANDLE
    api.CloseHandle.argtypes = [wintypes.HANDLE]
    api.CloseHandle.restype = wintypes.BOOL
    handle = api.CreateFileW(str(path), 0x80000000, 3, None, 3, 0x80, None)
    if handle == ctypes.c_void_p(-1).value: raise ctypes.WinError(ctypes.get_last_error())
    try: yield
    finally: api.CloseHandle(handle)


def book_text(path):
    with zipfile.ZipFile(path) as archive:
        root = ET.fromstring(archive.read('OEBPS/book.xhtml'))
    return ''.join(root.itertext()), root


@unittest.skipUnless(os.name == 'nt', 'Windows JSRT')
class ReaderSessionTests(unittest.TestCase):
    def test_story_menu_picture_and_callback_survive_replay_and_both_route_exports(self):
        raw = source(('StoryMenu', '''$items=0;
var step=7;
print('<b>Общее меню</b> '+link('<img src="files/menu.png" alt="Рюкзак"/>','Bag','',function(){$items+=step;}));'''),
                     ('Start', '\\ НАЧАЛО [[Далее|Next]]'),
                     ('Next', '\\ ПРОДОЛЖЕНИЕ'), ('Bag', 'print("ПРЕДМЕТОВ: "+$items);'))
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-initial-menu-') as directory:
            root = Path(directory); original = root / 'story.sm'
            original.write_bytes(raw); (root / 'files').mkdir()
            (root / 'files/menu.png').write_bytes(PNG)
            story = Story.parse(raw)
            with ReaderSession(story, now=1, seed=1) as reader:
                self.assertEqual([v['label'] for v in reader.choices()], ['Далее', 'Рюкзак'])
                menu_id = reader.choices()[1]['id']
                reader.choose(reader.choices()[0]['id'], now=2)
                reader.choose(menu_id, now=3)
                progress = reader.progress()
            with ReaderSession(story, progress=progress) as resumed:
                self.assertEqual(resumed.progress(), progress)
                self.assertEqual([v['label'] for v in resumed.choices()], ['Рюкзак'])
                resumed.choose(menu_id, now=4)
                scene = root / 'scene.epub'
                self.assertEqual(write_document(resumed, original, scene), [])
                value, _ = book_text(scene)
                self.assertIn('ПРЕДМЕТОВ: 14', value)
                self.assertIn('Общее меню', value)
                route = root / 'route.epub'
                self.assertEqual(write_document(resumed, original, route, True), [])
                fb2 = root / 'route.fb2'; convert_book.convert_book(route, fb2)
                for target in (route, fb2):
                    if target == route:
                        value, _ = book_text(target)
                        with zipfile.ZipFile(target) as archive:
                            images = {archive.read(n) for n in archive.namelist() if '/images/' in n}
                    else:
                        tree = ET.parse(target).getroot(); value = ''.join(tree.itertext())
                        images = {base64.b64decode(n.text) for n in tree if n.tag.endswith('}binary')}
                    self.assertIn(NOTICE, value)
                    self.assertIn('ПРЕДМЕТОВ: 14', value)
                    self.assertEqual(images, {PNG})
            self.assertEqual(original.read_bytes(), raw)

    def test_graphical_menu_is_a_separate_block_after_unwrapped_body_text(self):
        raw = source(('Start', '''title("СТАТУС");
print("ОСНОВНОЙ ТЕКСТ");
menu(link('<img src="menu.png" alt="Рюкзак"/>','Bag'));'''),
                     ('Bag', 'print("РЮКЗАК ОТКРЫТ");'))
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-menu-block-') as directory:
            root = Path(directory); original = root / 'story.sm'
            original.write_bytes(raw); (root / 'menu.png').write_bytes(PNG)
            with ReaderSession(Story.parse(raw), now=1, seed=1) as reader:
                for transcript in (False, True):
                    target = root / ('route.epub' if transcript else 'scene.epub')
                    self.assertEqual(write_document(reader, original, target, transcript), [])
                    value, tree = book_text(target)
                    body = next(n for n in tree if n.tag.endswith('}body'))
                    status, prose, menu = list(body)[-3:]
                    self.assertTrue(status.tag.endswith('}div'))
                    self.assertTrue(prose.tag.endswith('}p'))
                    self.assertTrue(menu.tag.endswith('}div'))
                    self.assertEqual(''.join(status.itertext()), 'СТАТУС')
                    self.assertEqual(''.join(prose.itertext()), 'ОСНОВНОЙ ТЕКСТ')
                    self.assertIn('[Рюкзак]', ''.join(menu.itertext()))
                    self.assertFalse(any(n.tag.endswith('}img') for n in prose.iter()))
                    self.assertEqual(len([n for n in menu.iter() if n.tag.endswith('}img')]), 1)
                action = reader.choices()[0]['id']
                reader.choose(action, now=2)
                resumed = root / 'resumed.epub'
                self.assertEqual(write_document(reader, original, resumed), [])
                value, tree = book_text(resumed)
                self.assertIn('РЮКЗАК ОТКРЫТ', value)
                self.assertEqual(reader.choices()[0]['id'], action)

    def test_unused_regions_keep_the_legacy_frame_and_journal_identity(self):
        raw = source(('Start', '\\ Начало'))
        # Independent pre-region protocol shape, including the source newline.
        legacy = {'parts': [{'kind': 'text', 'text': ' Начало'}, {'kind': 'newline'}],
                  'passage': 'Start', 'from': '', 'picture': '', 'title': '', 'menu': '',
                  'mode': '', 'generation': 1}
        digest = hashlib.sha256(json.dumps(legacy, ensure_ascii=False, separators=(',', ':')).encode('utf-8')).hexdigest()
        progress = {'version': 1, 'source': hashlib.sha256(raw).hexdigest(), 'seed': 1,
                    'started': 1, 'initial': digest, 'events': []}
        with ReaderSession(Story.parse(raw), progress) as reader:
            self.assertEqual(reader.frames[0][0], legacy)
            self.assertEqual(reader.progress(), progress)

    def test_graphical_status_and_menu_survive_transition_replay_and_both_exports(self):
        raw = source(('Start', '''$items=0;
title('<h2>Статус героя</h2><img src="files/status.png" alt="Герой"/>');
menu(link('<img src="files/menu.png" alt="Рюкзак"/>','Bag','',function(){$items++;}));
\\ НАЧАЛО [[Далее|Next]]'''), ('Next', '''title("<h2>Новый статус героя</h2>");
\\ ПРОДОЛЖЕНИЕ [[Убрать меню|Clear]]'''), ('Bag', '''print("ПРЕДМЕТОВ: "+$items);
\\ [[Убрать меню|Clear]]'''), ('Clear', '''menu("");title("");
\\ МЕНЮ УБРАНО'''))
        second_png = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
                      + png_chunk(b'IDAT', zlib.compress(b'\0\xff\x45\x12\xff')) + png_chunk(b'IEND', b''))
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-regions-') as directory:
            root = Path(directory); original = root / 'book.zip'; cached = root / 'cached.sm'
            cached.write_bytes(raw)
            with zipfile.ZipFile(original, 'w') as archive:
                archive.writestr('story.sm', raw)
                archive.writestr('files/status.png', PNG)
                archive.writestr('files/menu.png', second_png)
            before = hashlib.sha256(original.read_bytes()).hexdigest()
            story = Story.parse(raw)
            with StoryResources(cached, story.sha256, container=original, member='story.sm') as assets:
                with ReaderSession(story, now=1, seed=1) as reader:
                    self.assertEqual([v['label'] for v in reader.choices()], ['Далее', 'Рюкзак'])
                    menu_id = reader.choices()[1]['id']
                    scene = root / 'scene.epub'
                    self.assertEqual(write_document(reader, cached, scene, resources=assets), [])
                    value, tree = book_text(scene)
                    self.assertLess(value.index('Статус героя'), value.index('НАЧАЛО'))
                    self.assertLess(value.index('НАЧАЛО'), value.index('[Рюкзак]'))
                    with zipfile.ZipFile(scene) as archive:
                        self.assertEqual(set(archive.read(n) for n in archive.namelist() if '/images/' in n), {PNG, second_png})
                    reader.choose(reader.choices()[0]['id'], now=2)
                    self.assertEqual(write_document(reader, cached, scene, resources=assets), [])
                    value, _ = book_text(scene)
                    self.assertIn('Новый статус героя', value); self.assertNotIn('НАЧАЛО', value)
                    self.assertIn('Рюкзак', value)
                    reader.choose(menu_id, now=3); reader.choose(menu_id, now=4)
                    self.assertIn('ПРЕДМЕТОВ: 2', ''.join(v.get('text', '') for v in reader.frames[-1][0]['parts']))
                    progress = reader.progress()
                    route = root / 'route.epub'
                    self.assertEqual(write_document(reader, cached, route, True, assets), [])
                    fb2 = root / 'route.fb2'; convert_book.convert_book(route, fb2)
                    for target in (route, fb2):
                        if target == route:
                            route_text, _ = book_text(target)
                            with zipfile.ZipFile(target) as archive:
                                images = {archive.read(n) for n in archive.namelist() if '/images/' in n}
                        else:
                            tree = ET.parse(target).getroot(); route_text = ''.join(tree.itertext())
                            images = {base64.b64decode(''.join(n.itertext())) for n in tree if n.tag.endswith('}binary')}
                        for expected in ('Статус героя', 'Новый статус героя', 'Рюкзак', 'ПРЕДМЕТОВ: 2'):
                            self.assertIn(expected, route_text)
                        self.assertEqual(images, {PNG, second_png})
                    reader.choose(next(v['id'] for v in reader.choices() if v['label'] == 'Убрать меню'), now=5)
                    self.assertEqual(reader.choices(), [])
                    with self.assertRaises(StoryError): reader.choose(menu_id, now=6)
                    self.assertEqual(write_document(reader, cached, scene, resources=assets), [])
                    value, _ = book_text(scene)
                    self.assertIn('МЕНЮ УБРАНО', value); self.assertNotIn('Рюкзак', value)
                with ReaderSession(story, progress) as resumed:
                    self.assertEqual(resumed.progress(), progress)
                    self.assertIn(menu_id, [v['id'] for v in resumed.choices()])
                    resumed.choose(menu_id, now=5)
                    self.assertIn('ПРЕДМЕТОВ: 3', ''.join(v.get('text', '') for v in resumed.frames[-1][0]['parts']))
            self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), before)
            self.assertEqual(cached.read_bytes(), raw)

    def test_append_updates_regions_without_repeating_old_status_or_choices(self):
        raw = source(('Start', '''title("СТАРЫЙ СТАТУС");
menu(link("СТАРОЕ МЕНЮ","Clear"));
\\ НАЧАЛО [[+Добавить|Next]]'''), ('Next', '''title("НОВЫЙ СТАТУС");
menu(link("НОВОЕ МЕНЮ","Clear"));
\\ ПРОДОЛЖЕНИЕ'''), ('Clear', '''title("");menu("");
\\ ГОТОВО'''))
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-region-append-') as directory:
            root = Path(directory); original = root / 'story.sm'; original.write_bytes(raw)
            with ReaderSession(Story.parse(raw), now=1, seed=1) as reader:
                old_menu = next(v['id'] for v in reader.choices() if v['label'] == 'СТАРОЕ МЕНЮ')
                reader.choose(next(v['id'] for v in reader.choices() if v['label'] == 'Добавить'), now=2)
                target = root / 'scene.epub'; write_document(reader, original, target)
                value, _ = book_text(target)
                for expected in ('НАЧАЛО', 'ПРОДОЛЖЕНИЕ', 'НОВЫЙ СТАТУС', 'НОВОЕ МЕНЮ'): self.assertIn(expected, value)
                for absent in ('СТАРЫЙ СТАТУС', 'СТАРОЕ МЕНЮ'): self.assertNotIn(absent, value)
                self.assertEqual([v['label'] for v in reader.choices()], ['НОВОЕ МЕНЮ'])
                with self.assertRaises(StoryError): reader.choose(old_menu, now=3)

    def test_graphical_answers_keep_original_images_labels_route_and_source(self):
        other_png = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
                     + png_chunk(b'IDAT', zlib.compress(b'\0\xff\x45\x12\xff')) + png_chunk(b'IEND', b''))
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-graphical-answers-') as directory:
            root = Path(directory); original = root / 'story.zip'; cached = root / 'cached.sm'
            raw = source(('Start', '''\\ Перед выбором <p>[[<img src="files/left.png" alt="Левая дверь" onerror="bad()"/>|Left]]
\\ [[<img src="files/right.png"/>|Right]] [[<img src="files/right.png"/>|Left]]</p> После выбора'''),
                         ('Left', '\\ Невыбранная левая ветка'), ('Right', '\\ Выбрана правая дверь'))
            cached.write_bytes(raw)
            with zipfile.ZipFile(original, 'w') as archive:
                archive.writestr('book/story.sm', raw)
                archive.writestr('book/files/left.png', PNG)
                archive.writestr('book/files/right.png', other_png)
            before = hashlib.sha256(original.read_bytes()).hexdigest()
            story = Story.parse(raw)
            with StoryResources(cached, story.sha256, container=original, member='book/story.sm') as assets:
                with ReaderSession(story, now=1, seed=1) as reader:
                    options = reader.choices()
                    captions = ['Левая дверь', 'Вариант ' + str(options[1]['id']), 'Вариант ' + str(options[2]['id'])]
                    self.assertEqual([v['label'] for v in options], captions)
                    self.assertTrue(all(not v['input'] for v in options))
                    scene = root / 'scene.epub'
                    self.assertEqual(write_document(reader, cached, scene, resources=assets), [])
                    value, tree = book_text(scene)
                    for caption in captions: self.assertIn('[' + caption + ']', value)
                    self.assertIn('Перед выбором', value); self.assertIn('После выбора', value)
                    self.assertEqual(len([n for n in tree.iter() if n.tag.endswith('}img')]), 3)
                    with zipfile.ZipFile(scene) as archive:
                        self.assertEqual(set(archive.read(n) for n in archive.namelist() if '/images/' in n), {PNG, other_png})
                    reader.choose(options[1]['id'], now=2)
                    progress = reader.progress()
                    route = root / 'route.epub'
                    self.assertEqual(write_document(reader, cached, route, True, assets), [])
                    route_text, tree = book_text(route)
                    self.assertIn('Выбран ответ: ' + captions[1], route_text)
                    self.assertIn('Выбрана правая дверь', route_text)
                    self.assertNotIn('Невыбранная левая ветка', route_text)
                    self.assertFalse(any('onerror' in n.attrib or (n.tag.endswith('}a') and n.get('href'))
                                         for n in tree.iter()))
                    with zipfile.ZipFile(route) as archive:
                        self.assertEqual(set(archive.read(n) for n in archive.namelist() if '/images/' in n), {PNG, other_png})
                    fb2 = root / 'route.fb2'; convert_book.convert_book(route, fb2)
                    converted = ET.parse(fb2).getroot()
                    self.assertIn('Выбран ответ: ' + captions[1], ''.join(converted.itertext()))
                    self.assertEqual({base64.b64decode(''.join(n.itertext())) for n in converted
                                      if n.tag.endswith('}binary')}, {PNG, other_png})
                with ReaderSession(story, progress) as reopened:
                    self.assertEqual(reopened.frames[-1][1]['label'], captions[1])
                    self.assertEqual(reopened.choices(), [])
            self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), before)
            self.assertEqual(cached.read_bytes(), raw)

    def test_malformed_answer_markup_cannot_hide_following_prose_or_run_a_handler(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-answer-markup-') as directory:
            root = Path(directory); original = root / 'story.sm'
            original.write_bytes(source(('Start', '''\\ До [[<script>bad()|End]] ПОСЛЕ <b>Сохранено</b>
\\ [[<b>Выбрать|End]] ЗАВЕРШЕНИЕ'''), ('End', '\\ Конец')))
            with ReaderSession(Story.parse(original.read_bytes())) as reader:
                output = root / 'scene.epub'; write_document(reader, original, output)
                value, tree = book_text(output)
                for expected in ('До', 'ПОСЛЕ', 'Сохранено', 'Выбрать', 'ЗАВЕРШЕНИЕ'):
                    self.assertIn(expected, value)
                self.assertNotIn('bad()', value)
                self.assertFalse(any(n.tag.endswith('}script') or any(k.startswith('on') for k in n.attrib)
                                     for n in tree.iter()))

    def test_original_archive_companions_survive_cached_source_and_both_exports(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-media-') as directory:
            root = Path(directory); cache = root / 'cache'; cache.mkdir()
            raw = source(('Start', '''picture("files/background.png");
\\ <p>Текст с картинками</p><img src="files/inline.png"/> [[Дальше|End]]'''), ('End', '\\ Конец'))
            cached = cache / 'renamed.sm'; cached.write_bytes(raw)
            original = root / 'library.zip'
            with zipfile.ZipFile(original, 'w') as archive:
                archive.writestr('novel/book.sm', raw)
                archive.writestr('novel/files/background.png', PNG)
                archive.writestr('novel/files/inline.png', PNG)
            digest = hashlib.sha256(original.read_bytes()).hexdigest()
            story = Story.parse(raw)
            with StoryResources(cached, story.sha256, container=original, member='novel/book.sm') as assets:
                self.assertEqual(assets.image('files/BACKGROUND.png'), PNG)
                with ReaderSession(story) as reader:
                    epub = root / 'route.epub'
                    self.assertEqual(write_document(reader, cached, epub, True, assets), [])
                    with zipfile.ZipFile(epub) as archive:
                        images = [archive.read(v) for v in archive.namelist() if '/images/' in v]
                        self.assertEqual(images, [PNG])
                        markup = ET.fromstring(archive.read('OEBPS/book.xhtml'))
                        self.assertEqual(len([n for n in markup.iter() if n.tag.endswith('}img')]), 2)
                    fb2 = root / 'route.fb2'; convert_book.convert_book(epub, fb2)
                    binaries = [base64.b64decode(''.join(n.itertext())) for n in ET.parse(fb2).getroot()
                                if n.tag.endswith('}binary')]
                    self.assertEqual(binaries, [PNG])
            self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), digest)
            with self.assertRaisesRegex(StoryError, 'не совпадает'):
                StoryResources(cached, '0' * 64, container=original, member='novel/book.sm')

    def test_local_images_and_embedded_data_preserve_bytes_without_network_or_traversal(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-local-media-') as directory:
            root = Path(directory); (root / 'files').mkdir(); (root / 'files/image.png').write_bytes(PNG)
            assets = StoryResources(root / 'book.sm', '0' * 64)
            self.assertEqual(assets.image('files/image.png'), PNG)
            self.assertEqual(assets.image('data:image/png;base64,' + base64.b64encode(PNG).decode()), PNG)
            for value in ('../private.png', '%2e%2e/private.png', '/private.png', 'C:/private.png', 'files\\x.png'):
                with self.subTest(value=value), self.assertRaises(StoryError): assets.image(value)
            for value in ('https://example.com/image.png', 'files/missing.png'):
                with self.subTest(value=value), self.assertRaises(MissingStoryImage): assets.image(value)
            with self.assertRaises(StoryError): assets.image('data:image/png;base64,not-base64')

    def test_ambiguous_archive_images_fail_instead_of_selecting_a_different_picture(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-ambiguous-media-') as directory:
            root = Path(directory); raw = source(('Start', '\\ Text')); path = root / 'book.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('book.sm', raw); archive.writestr('files/X.png', PNG); archive.writestr('files/x.png', PNG)
            with StoryResources(root / 'cached.sm', hashlib.sha256(raw).hexdigest(), container=path, member='book.sm') as assets:
                with self.assertRaisesRegex(StoryError, 'несколько файлов'): assets.image('files/x.png')

    def story(self):
        return Story.parse(source(('StoryTitle', 'Ветви'), ('StoryAuthor', 'Автор'),
            ('Start', '$number=random(1,100000);\n\\ Начало [[Взять|Next {$book=1;}]] [[Мимо|Next {$book=0;}]]'),
            ('Next', 'print($number+"@"+Date.now());\nif($book){\n\\ Только выбранная ветка\n}\n\\ [[Ответить|Ask]]'),
            ('Ask', 'input("Result");'), ('Result', 'print("Ответ: "+$$input+"@"+Date.now());')))

    def test_progress_replays_exact_choices_random_clock_and_input(self):
        story = self.story()
        with ReaderSession(story, now=1000, seed=43) as reader:
            reader.choose(reader.choices()[0]['id'], now=2000)
            reader.choose(reader.choices()[0]['id'], now=3000)
            reader.choose(reader.choices()[0]['id'], 'Привет ё 😀', now=4000)
            frames, progress = copy.deepcopy(reader.frames), reader.progress()
        with ReaderSession(story, progress) as reopened:
            self.assertEqual(reopened.frames, frames)
            self.assertEqual(reopened.progress(), progress)
            self.assertEqual(reopened.choices(), [])

    def test_wrong_source_damaged_frame_and_state_do_not_continue(self):
        with ReaderSession(self.story(), now=1, seed=2) as reader:
            reader.choose(reader.choices()[0]['id'], now=2)
            saved = reader.progress()
        mutations = [('source', '0' * 64), ('initial', '0' * 64), ('seed', -1),
                     ('events', [{'id': True, 'clock': 2, 'frame': '0' * 64}])]
        for key, value in mutations:
            damaged = copy.deepcopy(saved); damaged[key] = value
            before = copy.deepcopy(damaged)
            with self.subTest(key=key), self.assertRaises(StoryError):
                ReaderSession(self.story(), damaged)
            self.assertEqual(damaged, before)
        damaged = copy.deepcopy(saved); damaged['events'][0]['frame'] = '0' * 64
        with self.assertRaisesRegex(StoryError, 'точно восстановить'):
            ReaderSession(self.story(), damaged)

    def test_only_displayed_live_actions_accept_input_and_ids(self):
        with ReaderSession(self.story()) as reader:
            first = reader.choices()[0]['id']
            for identity, value in ((False, None), (999999, None), (first, 'unexpected')):
                with self.assertRaises(StoryError): reader.choose(identity, value)
            reader.choose(first)
            with self.assertRaises(StoryError): reader.choose(first)
            reader.choose(reader.choices()[0]['id'])
            with self.assertRaises(StoryError): reader.choose(reader.choices()[0]['id'])
            reader.choose(reader.choices()[0]['id'], 'input')

    def test_append_actions_keep_unconsumed_options_and_normal_transition_clears(self):
        story = Story.parse(source(('Start', '\\ [[+Ещё|Extra]] [[Финиш|End]]'),
                                  ('Extra', '\\ Добавление [[Новый|End]]'), ('End', '\\ Конец')))
        with ReaderSession(story) as reader:
            original = reader.choices()
            reader.choose(original[0]['id'])
            self.assertEqual(len(reader.display), 2)
            self.assertEqual([v['label'] for v in reader.choices()], ['Финиш', 'Новый'])
            reader.choose(original[1]['id'])
            self.assertEqual(len(reader.display), 1)
            self.assertEqual(reader.choices(), [])

    def test_export_is_explicit_route_with_only_true_conditional_text_and_full_prose(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-export-') as directory:
            root = Path(directory); original = root / 'wrong.pdf'
            original.write_bytes(source(('StoryTitle', 'История'),
                ('Start', '\\ Начало [[Выбрать|End {$chosen=1}]] [[Не брать|End {$chosen=0}]]'),
                ('End', 'if($chosen){\n\\ <b>Выбрано</b> — точный текст 😀\n} else {\n\\ Невыбранный текст\n}')))
            digest = hashlib.sha256(original.read_bytes()).hexdigest()
            self.assertEqual(convert_book.detect_input(original), '.sm')
            original.write_bytes(b'\xef\xbb\xbf' + original.read_bytes())
            self.assertEqual(convert_book.detect_input(original), '.sm')
            digest = hashlib.sha256(original.read_bytes()).hexdigest()
            with ReaderSession(Story.parse(original.read_bytes()), now=1, seed=1) as reader:
                reader.choose(reader.choices()[0]['id'], now=2)
                epub = root / 'route.epub'; self.assertEqual(write_document(reader, original, epub, True), [])
                text, tree = book_text(epub)
                for value in (NOTICE, 'Начало', 'Выбран ответ: Выбрать', 'Выбрано', 'точный текст 😀'):
                    self.assertIn(value, text)
                self.assertNotIn('Невыбранный текст', text)
                self.assertFalse(any(n.tag.rsplit('}', 1)[-1] == 'script' for n in tree.iter()))
                fb2 = root / 'route.fb2'
                convert_book.convert_book(epub, fb2)
                converted = ''.join(ET.parse(fb2).getroot().itertext())
                for value in (NOTICE, 'Начало', 'Выбран ответ: Выбрать', 'Выбрано', 'точный текст 😀'):
                    self.assertIn(value, converted)
                self.assertNotIn('Невыбранный текст', converted)
                scene = root / 'scene.epub'; write_document(reader, original, scene)
                scene_text, _ = book_text(scene)
                self.assertNotIn('Начало', scene_text)
                self.assertNotIn(NOTICE, scene_text)
                self.assertNotIn('Start', scene_text)
                self.assertIn('Выбрано', scene_text)
            self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), digest)

    def test_markup_resources_stay_local_missing_images_are_visible_and_scripts_removed(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-markup-') as directory:
            root = Path(directory); original = root / 'story.sm'
            original.write_bytes(source(('Start', '''picture("missing.jpg");
\\ <script>alert('bad')</script><b>Safe</b><img src="https://example.com/private.png" onerror="bad()"/>
\\ <a href="file:///C:/secret">Label</a> [[<b>Go</b>|End]]'''), ('End', '\\ End')))
            with ReaderSession(Story.parse(original.read_bytes())) as reader:
                path = root / 'scene.epub'; warnings = write_document(reader, original, path)
                value, tree = book_text(path)
                self.assertIn('Safe', value); self.assertIn('Label', value)
                self.assertIn('[Иллюстрация отсутствует в исходных файлах]', value)
                self.assertNotIn("alert('bad')", value)
                self.assertEqual(reader.choices()[0]['label'], 'Go')
                self.assertTrue(any('иллюстрации' in v for v in warnings))
                for node in tree.iter():
                    self.assertNotIn('onerror', node.attrib)
                    self.assertFalse(node.get('href', '').startswith('file:'))
                with zipfile.ZipFile(path) as archive:
                    self.assertFalse(any(v.endswith('.js') for v in archive.namelist()))

    def test_native_protocol_start_choose_snapshot_resume_and_close(self):
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-sm-protocol-') as directory:
            root = Path(directory); original = root / 'source.sm'; work = root / 'work'; work.mkdir()
            original.write_bytes(self.story_source())
            before = original.read_bytes()
            def start():
                return subprocess.Popen([sys.executable, '-I', '-B', '-X', 'utf8',
                    str(Path(__file__).resolve().parents[1] / 'sm_reader.py'), '--source', str(original),
                    '--workspace', str(work)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            def response(process, identity):
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    try:
                        value = json.loads((work / ('reply-' + str(identity) + '.json')).read_text('utf-8'))
                        if value['id'] == identity: return value
                    except (FileNotFoundError, PermissionError): pass
                    if process.poll() is not None: self.fail(process.communicate()[1].decode())
                    time.sleep(.02)
                self.fail('Native protocol response timed out')
            process = start()
            try:
                first = response(process, 0); self.assertNotIn('error', first)
                # Holding the previous reply used to make os.replace fail with
                # WinError5. The next sequence must finish while this lock lives.
                old_reply = (work / 'reply-0.json').read_bytes()
                with deny_delete(work / 'reply-0.json'):
                    atomic_json(work / 'request-1.json', {'id': 1, 'command': 'choose', 'action': first['choices'][0]['id']})
                    second = response(process, 1); self.assertNotIn('error', second)
                    self.assertEqual((work / 'reply-0.json').read_bytes(), old_reply)
                self.assertEqual(second['visited'], 2)
                atomic_json(work / 'request-2.json', {'id': 2, 'command': 'snapshot'})
                saved = response(process, 2); self.assertEqual(saved['snapshot'], 'history.epub')
                self.assertIn(NOTICE, book_text(work / saved['snapshot'])[0])
                saved_scene = book_text(work / saved['scene'])[0]
                state = (work / 'state.json').read_bytes()
                atomic_json(work / 'request-3.json', {'id': 3, 'command': 'close'})
                self.assertEqual(process.wait(5), 0)
                process.communicate()
                for path in work.glob('request-*.json'): path.unlink()
                for path in work.glob('reply-*.json'): path.unlink()
                process = start()
                reopened = response(process, 0); self.assertEqual(reopened['visited'], 2)
                self.assertEqual((work / 'state.json').read_bytes(), state)
                self.assertEqual(book_text(work / reopened['scene'])[0], saved_scene)
                atomic_json(work / 'request-1.json', {'id': 1, 'command': 'close'})
                self.assertEqual(process.wait(5), 0); process.communicate()
            finally:
                if process.poll() is None: process.kill(); process.communicate()
            self.assertEqual(original.read_bytes(), before)

    @staticmethod
    def story_source():
        return source(('StoryTitle', 'Книга'), ('Start', '\\ Begin [[Next|End {$x=1}]]'),
                      ('End', 'print("Final="+$x);'))


class FrameValidationTests(unittest.TestCase):
    def test_label_markup_is_text_and_unknown_frame_fields_cannot_be_actions(self):
        self.assertEqual(plain_label('<script>bad</script><b>Название &amp; ё</b>'), 'Название & ё')
        self.assertEqual(plain_label('<img alt="Дверь &amp; окно" src="local.png"/>'), 'Дверь & окно')
        self.assertEqual(plain_label('<img title="Вход" src="local.png"/>'), 'Вход')
        self.assertEqual(plain_label('<style><img alt="Скрыто"/></style>Показано'), 'Показано')
        basic = {'generation': 1, 'mode': '', 'parts': [], 'passage': 'Start', 'from': '',
                 'picture': '', 'title': '', 'menu': ''}
        self.assertEqual(validate_frame(basic), basic)
        for regions in (None, [], {'other': []}, {'title': {}}, {'menu': [{'kind': 'eval'}]},
                        {'title': [{'kind': 'text', 'text': 3}]},
                        {'menu': [{'kind': 'link', 'id': True, 'label': 'Bad', 'target': 'Next', 'mode': ''}]}):
            with self.subTest(regions=regions), self.assertRaises(StoryError):
                validate_frame(dict(basic, regions=regions))
        for extra in ({'kind': 'eval', 'text': 'run()'}, {'kind': 'link', 'id': True, 'label': 'Bad',
                      'target': 'Next', 'mode': ''}, {'kind': 'external', 'target': 'file:///C:/secret'}):
            with self.subTest(extra=extra), self.assertRaises(StoryError):
                validate_frame(dict(basic, parts=[extra]))


if __name__ == '__main__': unittest.main()
