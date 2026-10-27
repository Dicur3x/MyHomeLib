"""Contained SM reader session, replayable progress and explicit route exports.

Only source bytes enter JSRT; file names, native controls and export publishing
belong to this host. Books never receive a Python/DOM/COM/network callback.
The small file protocol is private to one application-created work directory.
"""
import argparse
import hashlib
from html import escape
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import secrets
import sys
import time
import zipfile

if __name__ == '__main__':
    # -I excludes the script directory. Import only our adjacent installed
    # modules, never the working directory or a source-book search path.
    sys.path.insert(0, str(Path(__file__).resolve().parent))

import convert_book as converter
from sm_input import Story, StoryError, StorySession
from sm_resources import StoryResources, MissingStoryImage
from text_inputs import Book, HTMLInput

NOTICE = ('Это пройденная ветка интерактивной книги. Сохранены показанные '
          'параграфы и выбранные ответы. Другие ветки и выполнение условий '
          'в этой копии отсутствуют; исходная интерактивная книга сохранена.')
MAX_JOURNAL = 4 * 1024 * 1024
MAX_ROUTE_TEXT = 16 * 1024 * 1024
MAX_ACTIONS = 4096


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')


def identity(frame):
    return hashlib.sha256(encoded(frame)).hexdigest()


class _Plain(HTMLParser):
    def __init__(self, image_alt=True):
        super().__init__(convert_charrefs=True)
        self.parts, self.hidden = [], 0
        self.image_alt = image_alt

    def handle_starttag(self, name, attrs):
        if name in {'script', 'style'}: self.hidden += 1
        if self.hidden: return
        if name in {'br', 'p', 'div'}: self.parts.append(' ')
        if name == 'img' and self.image_alt:
            attributes = dict(attrs)
            self.parts.append(' ' + (attributes.get('alt') or attributes.get('title') or '') + ' ')

    def handle_endtag(self, name):
        if name in {'script', 'style'}: self.hidden = max(0, self.hidden - 1)

    def handle_data(self, data):
        if not self.hidden: self.parts.append(data)


def plain_label(value, image_alt=True):
    if not isinstance(value, str) or len(value) > 65536:
        raise StoryError('Слишком длинное название действия интерактивной книги.')
    parser = _Plain(image_alt); parser.feed(value); parser.close()
    return ' '.join(''.join(parser.parts).split())[:2048]


def choice_label(part):
    return plain_label(part['label']) or (
        'Ввести текст' if part['kind'] == 'input' else 'Вариант ' + str(part['id']))


def validate_frame(frame):
    if (not isinstance(frame, dict) or type(frame.get('generation')) is not int or
            frame['generation'] < 1 or frame.get('mode') not in {'', '+', '*'} or
            not isinstance(frame.get('parts'), list) or len(frame['parts']) > 100000):
        raise StoryError('Повреждён результат сценария интерактивной книги.')
    for name in ('passage', 'from', 'picture', 'title', 'menu'):
        if not isinstance(frame.get(name), str) or len(frame[name]) > 65536:
            raise StoryError('Повреждены сведения параграфа интерактивной книги.')
    regions = frame.get('regions', {})
    if (not isinstance(regions, dict) or set(regions) - {'title', 'menu'} or
            any(not isinstance(parts, list) or len(parts) > 100000 for parts in regions.values())):
        raise StoryError('Повреждён заголовок или меню интерактивной книги.')
    ids, characters = set(), 0
    for part in [*frame['parts'], *(part for parts in regions.values() for part in parts)]:
        if not isinstance(part, dict): raise StoryError('Повреждён блок параграфа.')
        kind = part.get('kind')
        if kind == 'text':
            if not isinstance(part.get('text'), str): raise StoryError('Повреждён текст параграфа.')
            characters += len(part['text'])
        elif kind in {'link', 'input'}:
            if (type(part.get('id')) is not int or part['id'] < 1 or
                    not isinstance(part.get('target'), str) or
                    not isinstance(part.get('label'), str) or
                    part.get('mode') not in {'', '+', '*'}):
                raise StoryError('Повреждено действие параграфа.')
            # A printed link marker may occur twice; it is still one action.
            ids.add(part['id']); characters += len(part.get('label', ''))
            plain_label(part.get('label'))
        elif kind == 'external':
            if (not isinstance(part.get('target'), str) or len(part['target']) > 8192 or
                    not part['target'].lower().startswith(('http://', 'https://'))):
                raise StoryError('Повреждён адрес ссылки параграфа.')
        elif kind != 'newline': raise StoryError('Неизвестный блок параграфа.')
    if characters > 4 * 1024 * 1024 or len(ids) > 1000:
        raise StoryError('Слишком большой параграф или список действий интерактивной книги.')
    return frame


class ReaderSession:
    """Keep actual choices; reopen by verified replay, never serialize JS objects.

    The source hash and every resulting frame must agree. A changed source,
    changed engine behavior or a non-replayable author script fails explicitly
    instead of opening the wrong branch. Saved progress stays intact on failure.
    """
    def __init__(self, story, progress=None, now=None, seed=None):
        self.story, self.session = story, None
        self.frames, self.display, self.actions, self.events = [], [], {}, []
        self.body_actions = {}
        self.route_size = 0
        now = int(time.time() * 1000) if now is None else now
        if progress is not None:
            self._validate_progress(progress)
            seed, now = progress['seed'], progress['started']
        seed = secrets.randbits(32) if seed is None else seed
        self.seed, self.started = seed, now
        deadline = time.monotonic() + 30
        try:
            self.session = StorySession(story, seed=seed, clock=now)
            frame = validate_frame(self.session.start())
            self.initial = identity(frame)
            if progress is not None and self.initial != progress['initial']:
                raise StoryError('Начало сохранённой истории изменилось. Можно начать книгу заново.')
            self._accept(frame)
            if progress:
                for event in progress['events']:
                    if time.monotonic() >= deadline:
                        raise StoryError('Восстановление пути превысило 30 секунд. Сохранённый путь не изменён.')
                    result = self.choose(event['id'], event['text'], event['clock'])
                    if identity(result) != event['frame']:
                        raise StoryError('Не удалось точно восстановить сохранённый путь. Можно начать книгу заново.')
        except BaseException:
            self.close(); raise

    def _validate_progress(self, progress):
        if (not isinstance(progress, dict) or progress.get('version') != 1 or
                progress.get('source') != self.story.sha256 or
                type(progress.get('seed')) is not int or not 0 <= progress['seed'] <= 0xffffffff or
                type(progress.get('started')) is not int or not 0 <= progress['started'] <= 8640000000000000 or
                not isinstance(progress.get('initial'), str) or not isinstance(progress.get('events'), list) or
                len(progress['events']) > MAX_ACTIONS or len(encoded(progress)) > MAX_JOURNAL):
            raise StoryError('Сохранённый путь относится к другой книге или повреждён. Исходник и сохранение не изменены.')
        for event in progress['events']:
            if (not isinstance(event, dict) or type(event.get('id')) is not int or event['id'] < 1 or
                    (event.get('text') is not None and (not isinstance(event['text'], str) or len(event['text']) > 65536)) or
                    type(event.get('clock')) is not int or not 0 <= event['clock'] <= 8640000000000000 or
                    not isinstance(event.get('frame'), str) or len(event['frame']) != 64):
                raise StoryError('Повреждено сохранённое действие интерактивной книги.')

    def _accept(self, frame, choice=None):
        size = len(encoded(frame))
        if self.route_size + size > MAX_ROUTE_TEXT:
            raise StoryError('Пройденный путь превышает предел 16 МБ. Сохраните его и начните книгу заново.')
        if not self.display or self.display[-1]['generation'] != frame['generation']:
            self.display, self.body_actions = [], {}
        self.display.append(frame)
        self.frames.append((frame, choice)); self.route_size += size
        for part in frame['parts']:
            if part['kind'] in {'link', 'input'}: self.body_actions[part['id']] = part
        self.actions = dict(self.body_actions)
        # The latest frame replaces these two persistent areas. An earlier
        # menu must not leave invisible choices behind after menu("").
        for parts in frame.get('regions', {}).values():
            for part in parts:
                if part['kind'] in {'link', 'input'}: self.actions[part['id']] = part

    def choose(self, action_id, text=None, now=None):
        if type(action_id) is not int or action_id not in self.actions:
            raise StoryError('Это действие уже выполнено или отсутствует на странице.')
        if len(self.events) >= MAX_ACTIONS:
            raise StoryError('Сохранённый путь достиг предела 4096 действий.')
        part = self.actions[action_id]
        if part['kind'] == 'input':
            if not isinstance(text, str) or len(text) > 65536:
                raise StoryError('Введите текст для выбранного действия.')
        elif text is not None: raise StoryError('Это действие не принимает текст.')
        now = int(time.time() * 1000) if now is None else now
        self.session.set_clock(now)
        frame = validate_frame(self.session.choose(action_id, text))
        event = {'id': action_id, 'text': text, 'clock': now, 'frame': identity(frame)}
        candidate = self.progress(); candidate['events'] = self.events + [event]
        if len(encoded(candidate)) > MAX_JOURNAL:
            raise StoryError('Сохранённый путь превышает предел 4 МБ.')
        self.body_actions.pop(action_id, None)
        self._accept(frame, {'label': choice_label(part), 'text': text})
        self.events.append(event)
        return frame

    def progress(self):
        return {'version': 1, 'source': self.story.sha256, 'seed': self.seed,
                'started': self.started, 'initial': self.initial, 'events': list(self.events)}

    def choices(self):
        return [{'id': v['id'], 'label': choice_label(v),
                 'input': v['kind'] == 'input'} for v in self.actions.values()]

    def close(self):
        if self.session is not None: self.session.close(); self.session = None

    def __enter__(self): return self
    def __exit__(self, *error): self.close()


class _StoryHTML(HTMLInput):
    def handle_starttag(self, name, attrs):
        # No active/source-generated HTML links or duplicate author IDs. Native
        # transitions are separate opaque controls, not executable markup.
        attrs = [(key, value) for key, value in attrs if key not in {'id', 'name', 'href'}]
        super().handle_starttag(name, attrs)


def write_document(reader, source, output, transcript=False, resources=None):
    warnings = set()
    book = Book(converter, Path(source), warnings, title=reader.story.title or Path(source).stem,
                author=reader.story.author, language='ru', reading=True)
    resources = resources or StoryResources(source, reader.story.sha256)
    def image(href):
        try: data = resources.image(href)
        except MissingStoryImage:
            warnings.add('Некоторые иллюстрации отсутствуют в исходных файлах или недоступны; они не скачивались.')
            return book.el('span', '[Иллюстрация отсутствует в исходных файлах]')
        return book.image(data)
    book.local_image = image
    if transcript:
        book.title += ' — пройденная ветка'
        book.body.append(book.el('p', NOTICE))

    def render(parts, region=False):
        parser = _StoryHTML(book)
        if region and parts:
            # AXMA title/menu are separate display areas. Keep a block
            # boundary even when the author's body is bare print() text;
            # otherwise the next menu image joins that text's paragraph.
            block = book.el('div')
            book.body.append(block)
            parser.stack = [('root', block)]
        for part in parts:
            if part['kind'] == 'text': parser.feed(part['text'])
            elif part['kind'] == 'newline': parser.feed('<br/>')
            elif part['kind'] in {'link', 'input'}:
                # An illustration can itself be an answer, not just decoration.
                # Keep its local media and harmless markup through the same
                # parser as prose; never give it a source-controlled href or
                # executable handler. Match its visible caption to the native
                # answer list, including distinct unnamed graphical choices.
                # Isolate fragment parser state: an unclosed tag in a label
                # cannot hide or reformat the following story text.
                if not parser.hidden:
                    label = _StoryHTML(book)
                    label.stack = [('root', parser.stack[-1][1])]
                    label.feed(part['label']); label.close()
                    if not plain_label(part['label'], image_alt=False):
                        parser.feed(escape(' [' + choice_label(part) + ']'))
            elif part['kind'] == 'external':
                parser.feed(escape('Внешняя ссылка: ' + part['target']))
        parser.close()

    rows = reader.frames if transcript else [(frame, None) for frame in reader.display]
    for index, (frame, choice) in enumerate(rows):
        if transcript and choice:
            book.body.append(book.el('p', 'Выбран ответ: ' + choice['label'] +
                                    ((' — ' + choice['text']) if choice['text'] is not None else '')))
        if transcript:
            # Passage keys such as Start/1:1:2 are script identifiers, not
            # headings. Reading keeps the author's own HTML headings/order.
            book.body.append(book.el('h2', 'Эпизод ' + str(index + 1)))
        # A live append keeps prose already shown, but title/menu are the
        # latest state, not a trail of obsolete status panels and choices.
        if transcript or index == 0:
            current = frame if transcript else reader.display[-1]
            render(current.get('regions', {}).get('title', []), region=True)
        if frame['picture']:
            paragraph = book.el('p'); paragraph.append(image(frame['picture'])); book.body.append(paragraph)
        render(frame['parts'])
        if transcript or index == len(rows) - 1:
            render(frame.get('regions', {}).get('menu', []), region=True)
    book.finish(Path(output))
    return sorted(warnings)


def atomic_json(path, value):
    pending = path.with_suffix('.pending')
    pending.write_bytes(encoded(value))
    os.replace(pending, path)


def read_json(path, maximum):
    with path.open('rb') as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum: raise StoryError('Слишком большой файл сохранённого пути или команды.')
    return json.loads(data.decode('utf-8-sig'))


def serve(source, workspace, resource_root=None, container=None, member=None):
    source, workspace = Path(source).resolve(), Path(workspace).resolve(strict=True)
    if not workspace.is_dir(): raise StoryError('Не найдена рабочая папка читалки.')
    with source.open('rb') as stream: story = Story.parse(stream.read(Story.MAX_SOURCE + 1))
    resources = StoryResources(source, story.sha256, resource_root, container, member)
    state = workspace / 'state.json'
    reader, sequence, old_scene = None, 0, None

    def publish(command):
        nonlocal reader, old_scene
        scene = workspace / ('scene-' + str(sequence) + '.epub')
        warnings = write_document(reader, source, scene, resources=resources)
        atomic_json(state, reader.progress())
        response = {'id': sequence, 'scene': scene.name, 'title': plain_label(story.title),
                    'choices': reader.choices(), 'visited': len(reader.frames), 'source': story.sha256,
                    'view': hashlib.sha256(encoded(reader.display)).hexdigest(), 'warnings': warnings}
        if command == 'snapshot':
            warnings = write_document(reader, source, workspace / 'history.epub', True, resources)
            response['warnings'] = sorted(set(response['warnings'] + warnings))
            response['snapshot'] = 'history.epub'
        # Every command/reply has a fresh name. A native poller holding the
        # previous JSON must never make Windows deny atomic replacement.
        atomic_json(workspace / ('reply-' + str(sequence) + '.json'), response)
        if old_scene and old_scene != scene:
            try: old_scene.unlink(missing_ok=True)
            except PermissionError: pass  # Native session cleanup owns any locked retired scene.
        old_scene = scene

    try:
        try:
            progress = read_json(state, MAX_JOURNAL) if state.exists() else None
            reader = ReaderSession(story, progress)
            publish('start')
        except (StoryError, converter.ConversionError, ValueError, OSError) as error:
            if reader: reader.close(); reader = None
            atomic_json(workspace / ('reply-' + str(sequence) + '.json'), {'id': sequence, 'error': str(error)[:2048]})
        while True:
            request = workspace / ('request-' + str(sequence + 1) + '.json')
            try:
                command = read_json(request, 256 * 1024)
            except (FileNotFoundError, PermissionError):
                time.sleep(.05); continue
            if not isinstance(command, dict) or type(command.get('id')) is not int:
                raise StoryError('Повреждена команда интерактивной читалки.')
            if command['id'] != sequence + 1:
                raise StoryError('Нарушен порядок команд интерактивной читалки.')
            sequence += 1
            try: request.unlink()
            except PermissionError: pass
            try:
                operation = command.get('command')
                if operation == 'close': return
                if operation == 'reset':
                    if reader: reader.close()
                    reader = ReaderSession(story)
                elif reader is None:
                    raise StoryError('Нужно нажать «Начать заново». Прежнее сохранение не изменено.')
                elif operation == 'choose': reader.choose(command.get('action'), command.get('text'))
                elif operation != 'snapshot': raise StoryError('Неизвестная команда интерактивной читалки.')
                publish(operation)
            except (StoryError, converter.ConversionError, ValueError, OSError) as error:
                if reader: reader.close(); reader = None
                atomic_json(workspace / ('reply-' + str(sequence) + '.json'), {'id': sequence, 'error': str(error)[:2048]})
    finally:
        if reader: reader.close()
        resources.close()


if __name__ == '__main__':
    arguments = argparse.ArgumentParser()
    arguments.add_argument('--source', required=True)
    arguments.add_argument('--workspace', required=True)
    arguments.add_argument('--resource-root')
    arguments.add_argument('--container')
    arguments.add_argument('--member')
    options = arguments.parse_args()
    try: serve(options.source, options.workspace, options.resource_root, options.container, options.member)
    except (StoryError, converter.ConversionError, ValueError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error))
