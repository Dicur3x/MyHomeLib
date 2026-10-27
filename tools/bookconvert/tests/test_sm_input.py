import hashlib
import os
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sm_input import Story, StoryError, StorySession
from js_runtime import JavaScriptError


def source(*passages):
    return ('ASMJS[::]64[::]0[::]0[::]1[::]mw[::]html\n' + ''.join(
        ':: ' + name + '[::]0[::]0\n' + body + '\n' for name, body in passages)).encode('utf-8')


def text(frame):
    return ''.join(part.get('text', '') for part in frame['parts'])


def links(frame):
    return [part for part in frame['parts'] if part['kind'] == 'link']


class StoryParserTests(unittest.TestCase):
    def test_complete_original_passage_bodies_metadata_and_identity(self):
        data = source(('StoryTitle', 'Книга ё 😀'), ('StoryAuthor', 'Автор'),
                      ('Start', '\\ Первая строка\n\\ Вторая строка'))
        story = Story.parse(data)
        self.assertEqual(story.title, 'Книга ё 😀')
        self.assertEqual(story.author, 'Автор')
        self.assertEqual(story.passages['Start'], '\\ Первая строка\n\\ Вторая строка\n')
        self.assertEqual(story.sha256, hashlib.sha256(data).hexdigest())
        self.assertEqual(Story.parse(b'\xef\xbb\xbf' + data.replace(b'\n', b'\r\n')).passages,
                         story.passages)

    def test_rejects_truncation_duplicates_missing_start_and_limits(self):
        for data in (b'ASMJS', source(('Else', '\\ No start')),
                     source(('Start', '\\ One'), ('Start', '\\ Two')),
                     source((' Start', '\\ Bad name')),
                     source(('Start', '\\ \0')),
                     source(('Start', '__mhlSm.choose(1)')),
                     source(('X' * 513, ''), ('Start', '')),
                     b'ASMJS[::]63\n:: Start[::]\n',
                     b'ASMJS[::]64\nnot a passage\n:: Start[::]\n',
                     b'ASMJS[::]64\n:: Start[::]\n\xff',
                     b'x' * (Story.MAX_SOURCE + 1)):
            with self.subTest(prefix=data[:60]), self.assertRaises(StoryError):
                Story.parse(data)


@unittest.skipUnless(os.name == 'nt', 'Windows JSRT')
class StorySessionTests(unittest.TestCase):
    def test_story_menu_initializes_before_start_and_keeps_its_graphical_actions(self):
        story = Story.parse(source(('StoryMenu', '''$menuInitializations=typeof $menuInitializations==="undefined"?1:$menuInitializations+1;
$items=0;
var step=7;
print("<b>Общее меню</b>");
print(link('<img src="bag.png" alt="Рюкзак"/>',"Bag","",function(){$items+=step;}));'''),
                                   ('Start', '''print("INIT="+$menuInitializations);
\\ [[В путь|Next]]'''), ('Next', '\\ Следующий параграф'),
                                   ('Bag', 'print("В рюкзаке: "+$items);')))
        with StorySession(story) as session:
            self.assertEqual(session.runtime.run('typeof $menuInitializations'), 'undefined')
            first = session.start()
            self.assertEqual((first['passage'], first['from']), ('Start', ''))
            self.assertEqual(text(first), 'INIT=1 ')
            menu = first['regions']['menu']
            self.assertEqual(menu[0], {'kind': 'text', 'text': '<b>Общее меню</b>'})
            menu_id = next(v['id'] for v in menu if v['kind'] == 'link')
            self.assertIn('<img src="bag.png"', next(v['label'] for v in menu if v['kind'] == 'link'))
            self.assertEqual(session.runtime.run('visited("Start")+"|"+visited("StoryMenu")'), '1|0')
            second = session.choose(links(first)[0]['id'])
            self.assertEqual(second['regions']['menu'], menu)
            self.assertIn('В рюкзаке: 7', text(session.choose(menu_id)))
            self.assertIn('В рюкзаке: 14', text(session.choose(menu_id)))
            self.assertEqual(session.runtime.run('$menuInitializations'), '1')

    def test_empty_story_menu_preserves_frames_and_failed_menu_does_not_start(self):
        basic = (('Start', '\\ Начало'),)
        with StorySession(Story.parse(source(*basic))) as plain:
            expected = plain.start()
        with StorySession(Story.parse(source(('StoryMenu', '// Необязательное меню\n'), *basic))) as empty:
            self.assertEqual(empty.start(), expected)
        with StorySession(Story.parse(source(('StoryMenu', 'throw new Error("Menu failed");'),
                                            ('Start', '$didStart=true;')))) as failed:
            with self.assertRaisesRegex(StoryError, 'Menu failed'):
                failed.start()
            self.assertEqual(failed.runtime.run('typeof $didStart'), 'undefined')

    def test_story_menu_input_remains_available_and_its_output_is_bounded(self):
        story = Story.parse(source(('StoryMenu', 'print("Имя: ");input("Name");'),
                                   ('Start', '\\ Начало'), ('Name', 'print($$input);')))
        with StorySession(story) as session:
            first = session.start()
            action = next(v for v in first['regions']['menu'] if v['kind'] == 'input')
            self.assertIn('Аня', text(session.choose(action['id'], 'Аня')))
            self.assertIn('Борис', text(session.choose(action['id'], 'Борис')))
        oversized = Story.parse(source(('StoryMenu', 'print(new Array(65538).join("x"));'),
                                       ('Start', '$didStart=true;')))
        with StorySession(oversized) as session:
            with self.assertRaisesRegex(StoryError, 'Слишком большой'):
                session.start()
            self.assertEqual(session.runtime.run('typeof $didStart'), 'undefined')

    def test_menu_and_title_keep_links_and_closures_between_normal_passages(self):
        story = Story.parse(source(('Start', '''$visits=0;
var amount=11;
title("<b>Жизни: 3</b>");
menu(link("Рюкзак","Bag","",function(){$visits+=amount;}));
\\ [[В путь|Next]]'''), ('Next', '''title("<b>Жизни: 2</b>");
\\ Следующий параграф'''), ('Bag', 'print("В рюкзаке: "+$visits);')))
        with StorySession(story) as session:
            first = session.start()
            menu_id = first['regions']['menu'][0]['id']
            body_id = links(first)[0]['id']
            self.assertEqual(first['regions']['title'], [{'kind': 'text', 'text': '<b>Жизни: 3</b>'}])
            second = session.choose(body_id)
            self.assertEqual(second['regions']['menu'][0]['id'], menu_id)
            self.assertEqual(second['regions']['title'][0]['text'], '<b>Жизни: 2</b>')
            self.assertIn('В рюкзаке: 11', text(session.choose(menu_id)))
            self.assertIn('В рюкзаке: 22', text(session.choose(menu_id)))
            with self.assertRaises(StoryError): session.choose(body_id)

    def test_initialization_does_not_run_story_or_untaken_actions(self):
        story = Story.parse(source(('Start', '$key=0;\n\\ [[Take|Door {$key=1}]]'),
                                   ('Door', 'if ($key === 1) {\n\\ Open\n} else {\n\\ Closed\n}')))
        with StorySession(story) as session:
            self.assertEqual(session.runtime.run('typeof $key'), 'undefined')
            first = session.start()
            self.assertEqual(session.runtime.run('$key'), '0')
            second = session.choose(links(first)[0]['id'])
            self.assertEqual(second['passage'], 'Door')
            self.assertEqual(second['from'], 'Start')
            self.assertIn('Open', text(second))
            self.assertNotIn('Closed', text(second))
            self.assertEqual(session.runtime.run('$key'), '1')

    def test_choices_keep_lexical_closures_and_javascript_state(self):
        story = Story.parse(source(('Start', '''$items = [];
[11,22].forEach(function (n) {
print(link("Choose","Next","",function(){$items.push(n);}));
});'''), ('Next', '''print($items.join(","));
\\ [[Again|Next {$items.push(33)}]]''')))
        with StorySession(story) as session:
            first = session.start()
            next_frame = session.choose(links(first)[1]['id'])
            self.assertIn('22', text(next_frame))
            self.assertEqual(session.runtime.run('JSON.stringify($items)'), '[22]')
            third = session.choose(links(next_frame)[0]['id'])
            self.assertIn('22,33', text(third))

    def test_inline_actions_have_global_scope_as_in_the_original_axma_editor(self):
        # Independent original-editor oracle: Start declares a local variable,
        # inline action assigns the same name, Next prints SCOPE=number, not
        # undefined. See pre534-sm-inline-action-oracle.png and its UI record.
        story = Story.parse(source(('Start', '''var localChoice;
\\ [[Check scope|Next {localChoice=22;}]]'''),
                                   ('Next', 'print("SCOPE="+typeof localChoice+"|"+localChoice);')))
        with StorySession(story) as session:
            first = session.start()
            self.assertEqual(session.runtime.run('typeof localChoice'), 'undefined')
            result = session.choose(links(first)[0]['id'])
            self.assertEqual(text(result), 'SCOPE=number|22')

    def test_source_cannot_break_out_of_a_function_during_preparation(self):
        for body in ('});$eager=1;(function(){',
                     '\\ [[Go|Next {});$eager=1;(function(){}]]'):
            with self.subTest(body=body), self.assertRaises((StoryError, JavaScriptError)):
                StorySession(Story.parse(source(('Start', body), ('Next', '\\ Done'))))

    def test_link_brackets_in_strings_regex_and_nested_callback_blocks(self):
        story = Story.parse(source(('Start', '''$value = "";
\\ [[Next|Next {if (true) {$value = "a ]] } b"; var r = /[}\\]]/;}}]]'''),
                                   ('Next', 'print($value);')))
        with StorySession(story) as session:
            frame = session.start()
            self.assertEqual(len(links(frame)), 1)
            next_frame = session.choose(links(frame)[0]['id'])
            self.assertEqual(text(next_frame), 'a ]] } b')

    def test_multiline_comments_templates_regex_and_literal_text_are_distinct(self):
        story = Story.parse(source(('Start', '''/*
\\ [[Broken|Nowhere {this is not JS}]]
*/
var template = `first
\\ not prose or a link [[x]]
last`;
var regexp = /[/*]/;
\\ Видимый текст — \"кавычки\" 😀
print(template);''')))
        with StorySession(story) as session:
            frame = session.start()
            self.assertFalse(links(frame))
            self.assertNotIn('Broken', text(frame))
            self.assertIn('Видимый текст — "кавычки" 😀', text(frame))
            self.assertIn('not prose or a link [[x]]', text(frame))

    def test_print_link_concatenation_input_and_system_values(self):
        story = Story.parse(source(('Start', '''print("before "+link("Input","Ask")+" after");'''),
                                   ('Ask', 'input("Result");'),
                                   ('Result', 'print($$input+"|"+$$title+"|"+$$from);')))
        with StorySession(story) as session:
            first = session.start()
            self.assertEqual(text(first), 'before  after')
            second = session.choose(links(first)[0]['id'])
            input_id = next(part['id'] for part in second['parts'] if part['kind'] == 'input')
            final = session.choose(input_id, 'Unicode ё 😀 " \\')
            self.assertEqual(text(final), 'Unicode ё 😀 " \\|Result|Ask')

    def test_append_actions_and_external_urls_never_run_host_requests(self):
        story = Story.parse(source(('Start', '''\\ [[+More|Extra]] [[Site|https://example.com/]]'''),
                                   ('Extra', '\\ Extra [[Later|Last]]'),
                                   ('Last', '\\ Last')))
        with StorySession(story) as session:
            first = session.start()
            more = session.choose(links(first)[0]['id'])
            self.assertEqual(more['mode'], '+')
            self.assertIn('Extra', text(more))
            external = session.choose(links(first)[1]['id'])
            self.assertEqual(external['parts'], [{'kind': 'external', 'target': 'https://example.com/'}])
            self.assertEqual(session.runtime.run('typeof fetch+","+typeof ActiveXObject'), 'undefined,undefined')

    def test_stale_actions_and_failed_passages_never_publish_partial_success(self):
        story = Story.parse(source(('Start', '\\ [[Next|Next]]'),
                                   ('Next', '\\ Partial\nthrow new Error("failed");')))
        with StorySession(story) as session:
            first = session.start()
            with self.assertRaisesRegex(StoryError, 'failed'):
                session.choose(links(first)[0]['id'])
            with self.assertRaisesRegex(StoryError, 'заново'):
                session.choose(links(first)[0]['id'])
        story = Story.parse(source(('Start', '\\ [[Next|Next]]'), ('Next', '\\ Good')))
        with StorySession(story) as session:
            first = session.start()
            session.choose(links(first)[0]['id'])
            with self.assertRaises(StoryError):
                session.choose(links(first)[0]['id'])

    def test_infinite_loop_is_bounded_and_cannot_resume_modified_story(self):
        story = Story.parse(source(('Start', 'while (true) {}')))
        with StorySession(story, timeout=0.1) as session:
            begin = time.monotonic()
            with self.assertRaisesRegex(StoryError, 'время'):
                session.start()
            self.assertLess(time.monotonic() - begin, 5)
            with self.assertRaisesRegex(StoryError, 'заново'):
                session.start()

    def test_error_string_conversion_is_inside_the_execution_deadline(self):
        story = Story.parse(source(('Start',
            'throw {toString:function(){while(true){}}};')))
        with StorySession(story, timeout=0.1) as session:
            begin = time.monotonic()
            with self.assertRaisesRegex(StoryError, 'время'):
                session.start()
            self.assertLess(time.monotonic() - begin, 5)
            self.assertTrue(session.failed)

    def test_window_alias_cannot_supply_host_bridges_or_dynamic_code(self):
        story = Story.parse(source(('Start', '\\ Text')))
        with StorySession(story) as session:
            self.assertEqual(session.runtime.run(
                '[typeof window.fetch,typeof window.ActiveXObject,typeof window.WScript,'
                'typeof window.require,typeof window.process,typeof window.XMLHttpRequest].join()'),
                ','.join(['undefined'] * 6))
            for expression in ('eval("1+1")',
                               'window.constructor.constructor("return this")()'):
                with self.assertRaises(JavaScriptError):
                    session.runtime.run(expression)
            self.assertEqual(text(session.start()).strip(), 'Text')

    def test_malformed_link_or_code_never_creates_a_partly_valid_session(self):
        for body in ('\\ [[Missing end', '\\ [[Empty|]]',
                     '\\ [[Action|Next {this is not JavaScript}]]', 'function {'):
            with self.subTest(body=body), self.assertRaises((StoryError, JavaScriptError)):
                StorySession(Story.parse(source(('Start', body))))

    def test_preparation_has_an_overall_budget_not_only_per_script_deadlines(self):
        story = Story.parse(source(('Start', '\\ [[Next|Next {$x=1}]]'),
                                   ('Next', '\\ Text')))
        with patch.object(StorySession, 'COMPILE_SECONDS', 0):
            with self.assertRaisesRegex(StoryError, 'Подготовка.*время'):
                StorySession(story)

    def test_random_bounds_are_inclusive_and_independent_sessions(self):
        story = Story.parse(source(('Start', '''$value = random(3,7);
print($value);''')))
        with StorySession(story) as first, StorySession(story) as second:
            first.runtime.run('Math.random=function(){return 0;}')
            second.runtime.run('Math.random=function(){return 0.999999999;}')
            self.assertEqual(text(first.start()), '3')
            self.assertEqual(text(second.start()), '7')


if __name__ == '__main__':
    unittest.main()
