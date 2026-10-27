"""AXMA JS source parsing and contained interactive sessions (MIT).

The SM reader worker uses this module to keep passage code executable only
inside js_runtime's bounded, host-free JSRT. The
public syntax and APIs are described at https://axmajs.ru/ru/manual/ . No AXMA
player implementation is copied, downloaded for execution, or embedded here.
"""
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import time

from js_runtime import JavaScriptRuntime, JavaScriptError


class StoryError(ValueError):
    pass


@dataclass(frozen=True)
class Story:
    passages: dict
    sha256: str
    version: int

    MAX_SOURCE = 8 * 1024 * 1024
    MAX_PASSAGES = 4096
    MAX_NAME = 512

    @classmethod
    def parse(cls, data):
        if not isinstance(data, bytes) or len(data) > cls.MAX_SOURCE:
            raise StoryError('Исходник интерактивной книги превышает допустимый размер.')
        try:
            text = data.decode('utf-8-sig')
        except UnicodeError as error:
            raise StoryError('Повреждена кодировка интерактивной книги.') from error
        if '\0' in text or '__mhlSm' in text:
            raise StoryError('В исходнике книги есть недопустимое служебное имя или символ.')
        # Keep every original body. Metadata passages are plain text, not JS.
        lines = text.replace('\r\n', '\n').replace('\r', '\n').splitlines(keepends=True)
        if not lines or not re.fullmatch(r'ASMJS\[::\](\d+)(?:\[::\][^\n]*)*\n?', lines[0]):
            raise StoryError('Это не исходник AXMA Story Maker JS.')
        version = int(lines[0].split('[::]')[1])
        if version != 64:
            raise StoryError('Эта версия исходника AXMA JS пока не поддерживается.')
        passages, name, body = {}, None, []
        for line in lines[1:]:
            match = re.fullmatch(r':: (.*?)\[::\][^\n]*\n?', line)
            if match:
                if name is not None:
                    passages[name] = ''.join(body)
                name, body = match[1], []
                if (not name or len(name) > cls.MAX_NAME or name.strip() != name or
                        name in passages or len(passages) >= cls.MAX_PASSAGES):
                    raise StoryError('Повторное или повреждённое имя параграфа AXMA JS.')
            elif name is not None:
                body.append(line)
            elif line.strip():
                raise StoryError('Лишние данные перед первым параграфом AXMA JS.')
        if name is not None:
            passages[name] = ''.join(body)
        if 'Start' not in passages:
            raise StoryError('В интерактивной книге отсутствует начальный параграф Start.')
        return cls(passages, hashlib.sha256(data).hexdigest(), version)

    @property
    def title(self):
        return self.passages.get('StoryTitle', '').strip()

    @property
    def author(self):
        return self.passages.get('StoryAuthor', '').strip()


class _LexicalState:
    """Track whether the next line belongs to JS or a multi-line literal/comment.

    This is only a prose-line boundary scanner, never a JS syntax validator.
    Chakra subsequently parses every complete function before the story runs.
    """
    def __init__(self):
        self.mode = 'code'
        self.regexp_allowed = True
        self.curly_depth = 0

    def consume(self, line):
        at, escaped, char_class = 0, False, False
        while at < len(line):
            char, following = line[at], line[at:at + 2]
            if self.mode == 'block':
                if following == '*/':
                    self.mode, at = 'code', at + 2
                else:
                    at += 1
                continue
            if self.mode in ("'", '"', '`', 'regexp'):
                if escaped:
                    escaped = False
                elif char == '\\':
                    escaped = True
                elif self.mode == 'regexp':
                    if char == '[':
                        char_class = True
                    elif char == ']':
                        char_class = False
                    elif char == '/' and not char_class:
                        self.mode, self.regexp_allowed = 'code', False
                elif char == self.mode:
                    self.mode, self.regexp_allowed = 'code', False
                at += 1
                continue
            if following == '//':
                return
            if following == '/*':
                self.mode, at = 'block', at + 2
            elif char in "'\"`":
                self.mode, at = char, at + 1
            elif char == '/' and self.regexp_allowed:
                self.mode, at, char_class = 'regexp', at + 1, False
            elif char.isalpha() or char in '_$':
                end = at + 1
                while end < len(line) and (line[end].isalnum() or line[end] in '_$'):
                    end += 1
                self.regexp_allowed = line[at:end] in {
                    'return', 'throw', 'case', 'delete', 'void', 'typeof', 'in',
                    'instanceof', 'new', 'yield', 'else', 'do'}
                at = end
            elif not char.isspace():
                if char == '{':
                    self.curly_depth += 1
                elif char == '}':
                    self.curly_depth -= 1
                    if self.curly_depth < 0:
                        raise StoryError('Код выходит за границы параграфа или действия ссылки.')
                self.regexp_allowed = char not in ')]}' and not char.isdigit()
                at += 1
            else:
                at += 1


def _json(value):
    # ASCII escapes also protect U+2028/U+2029 and embedded quote/backslash.
    return json.dumps(value, ensure_ascii=True, separators=(',', ':'))


def _compile_budget(deadline):
    if deadline is not None and time.monotonic() >= deadline:
        raise StoryError('Подготовка интерактивной книги превысила время выполнения.')


def _line_parts(text, story, runtime, deadline):
    """Compile inline actions in AXMA's global scope, separately from passages.

    A possible ]] inside a callback string/regexp is not an outer link boundary:
    only a candidate with a fully parsed callback is accepted. No callback runs
    while parsing. The original AXMA editor was independently checked: inline
    action blocks do not capture passage locals. Explicit link(..., function)
    callbacks still have ordinary JavaScript lexical closures.
    """
    parts, start, attempts = [], 0, 0
    while True:
        opening = text.find('[[', start)
        if opening < 0:
            parts.append(_json(text[start:]))
            break
        parts.append(_json(text[start:opening]))
        closing, expression = opening, None
        while True:
            _compile_budget(deadline)
            closing = text.find(']]', closing + 2)
            attempts += 1
            if closing < 0 or attempts > 8192:
                raise StoryError('Оборвана или слишком сложна ссылка интерактивной книги.')
            inner = text[opening + 2:closing]
            kind = inner[:1] if inner[:1] in ('+', '*') else ''
            if kind:
                inner = inner[1:]
            label, separator, target = inner.partition('|')
            if not separator:
                target = label
            target, callback = target.strip(), None
            if target not in story.passages and '{' in target:
                target_name, _, action = target.partition('{')
                if not action.rstrip().endswith('}'):
                    continue
                callback = 'function(){\n' + action.rstrip()[:-1] + '\n}'
                try:
                    action_state = _LexicalState()
                    for line in action.rstrip()[:-1].splitlines():
                        action_state.consume(line + '\n')
                    runtime.parse('(' + callback + ')')
                except (JavaScriptError, StoryError):
                    continue
                callback_id = runtime.run('__mhlSm.defineInline(' + callback + ')')
                if not re.fullmatch(r'[1-9][0-9]*', callback_id):
                    raise StoryError('Не удалось подготовить действие ссылки.')
                callback = '__mhlSm.inline(' + callback_id + ')'
                target = target_name.strip()
            if not target and callback is None:
                raise StoryError('В ссылке интерактивной книги не указан параграф.')
            # Unknown target names are reported on selection, as in the author
            # tool. Merely containing a broken, unvisited link is not data loss.
            expression = '__mhlSm.link(' + ','.join((
                _json(label), _json(target), _json(kind), callback or 'null')) + ')'
            break
        parts.append(expression)
        start = closing + 2
    return '[' + ','.join(parts) + ']'


def compile_passage(body, story, runtime, deadline=None):
    state, lines = _LexicalState(), []
    for line in body.splitlines():
        _compile_budget(deadline)
        stripped = line.lstrip()
        if state.mode == 'code' and stripped.startswith('\\'):
            lines.append('__mhlSm.line(' + _line_parts(stripped[1:], story, runtime, deadline) + ');')
        else:
            lines.append(line)
            state.consume(line + '\n')
    function = 'function(){\n' + '\n'.join(lines) + '\n}'
    _compile_budget(deadline)
    runtime.parse('(' + function + ')')
    return function


class StorySession:
    """Low-level session; no filesystem/network book APIs exposed.

    Frames contain text and opaque action IDs, not executable HTML handlers.
    Media lookup, verified progress replay and explicit route export belong to
    sm_reader. Testing this engine alone never proves complete AXMA support.
    """
    METADATA = frozenset(('StoryTitle', 'StoryAuthor', 'StorySubtitle'))
    COMPILE_SECONDS = 30.0

    def __init__(self, story, timeout=2.0, seed=None, clock=None):
        self.story = story
        self.runtime = JavaScriptRuntime(timeout=timeout)
        self.failed = False
        try:
            deadline = time.monotonic() + self.COMPILE_SECONDS
            bootstrap = Path(__file__).with_name('sm_runtime.js').read_text('utf-8-sig')
            self.runtime.run(bootstrap)
            if seed is not None:
                if (type(seed) is not int or not 0 <= seed <= 0xffffffff or
                        type(clock) is not int or not 0 <= clock <= 8640000000000000):
                    raise StoryError('Неверные параметры сохранённой истории.')
                self.runtime.run('__mhlSm.configure(' + _json(seed) + ',' + _json(clock) + ');')
            for name, body in story.passages.items():
                if name in self.METADATA:
                    continue
                function = compile_passage(body, story, self.runtime, deadline)
                self.runtime.run('__mhlSm.define(' + _json(name) + ',' + function + ');')
                _compile_budget(deadline)
        except BaseException:
            self.runtime.close()
            raise

    def _request(self, method, *arguments):
        if self.failed:
            raise StoryError('После ошибки сценария нужно заново открыть интерактивную книгу.')
        try:
            call = '__mhlSm.' + method + '(' + ','.join(_json(v) for v in arguments) + ')'
            # Error conversion stays inside the same timed/memory-bounded run:
            # even a custom Error.toString cannot hang the Python host.
            data = self.runtime.run('(function(){try{return ' + call +
                                    ';}catch(e){return JSON.stringify({error:String(e)});}})()')
            result = json.loads(data)
            if isinstance(result, dict) and isinstance(result.get('error'), str):
                raise StoryError(result['error'][:2048])
            if not isinstance(result, dict) or not isinstance(result.get('parts'), list):
                raise StoryError('Повреждён результат сценария интерактивной книги.')
            return result
        except (JavaScriptError, ValueError, TypeError, RecursionError) as error:
            # Script state may already be partly modified. Never continue from
            # it or acknowledge partially produced text as a successful passage.
            self.failed = True
            raise StoryError('Не удалось выполнить параграф интерактивной книги: ' + str(error)) from error

    def start(self):
        return self._request('start')

    def choose(self, action_id, text=None):
        if not isinstance(action_id, int) or isinstance(action_id, bool) or action_id < 1:
            raise StoryError('Неверная ссылка интерактивной книги.')
        if text is not None and (not isinstance(text, str) or len(text) > 65536):
            raise StoryError('Слишком длинное значение для интерактивной книги.')
        return self._request('choose', action_id, text)

    def set_clock(self, clock):
        if type(clock) is not int or not 0 <= clock <= 8640000000000000:
            raise StoryError('Неверное время сохранённой истории.')
        self.runtime.run('__mhlSm.setClock(' + _json(clock) + ');')

    def close(self):
        self.runtime.close()

    def __enter__(self):
        return self

    def __exit__(self, *error):
        self.close()
