import json
import importlib.util
import ctypes
import os
from pathlib import Path
import time
import unittest

spec = importlib.util.spec_from_file_location('js_runtime', Path(__file__).resolve().parents[1] / 'js_runtime.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
JavaScriptError, JavaScriptRuntime = module.JavaScriptError, module.JavaScriptRuntime


@unittest.skipUnless(os.name == 'nt', 'Windows JSRT')
class JavaScriptHostTests(unittest.TestCase):
    def test_temporary_output_is_released_under_a_small_runtime_memory_budget(self):
        # Leave room for the x64 engine's own heap and a transient join array;
        # retained copies of all 64 results would still exceed this budget.
        with JavaScriptRuntime(memory_limit=16 * 1024 * 1024) as runtime:
            for index in range(64):
                value = runtime.run('new Array(200001).join("x")+' + str(index))
                self.assertEqual(value, 'x' * 200000 + str(index))
            self.assertEqual(runtime.run('6*7'), '42')

    def test_context_and_temporary_results_survive_forced_native_gc(self):
        first, second = JavaScriptRuntime(), JavaScriptRuntime()
        try:
            collect = first.dll.JsCollectGarbage
            collect.argtypes, collect.restype = [ctypes.c_void_p], ctypes.c_uint
            # Both contexts are inactive and stored only in Python objects.
            first._check(collect(first.runtime)); second._check(collect(second.runtime))
            convert = first.dll.JsConvertValueToString
            pointer = first.dll.JsStringToPointer
            calls = []
            def collecting_convert(*args):
                first._check(collect(first.runtime)); calls.append('convert')
                return convert(*args)
            def collecting_pointer(*args):
                first._check(collect(first.runtime)); calls.append('pointer')
                return pointer(*args)
            first.dll.JsConvertValueToString = collecting_convert
            first.dll.JsStringToPointer = collecting_pointer
            for index in range(24):
                expected = 'Книга ё 😀 ' + str(index) + 'x' * 12000
                # A returned object and its freshly allocated toString result
                # have no JS global reference. The host must root both.
                script = '({toString:function(){return ' + json.dumps(expected) + ';}})'
                self.assertEqual(first.run(script), expected)
                self.assertEqual(second.run('6*7'), '42')
            self.assertEqual(calls, ['convert', 'pointer'] * 24)
            first.dll.JsConvertValueToString = convert
            first.dll.JsStringToPointer = pointer
            # Also restore an independently active context after a nested run.
            first._check(first.dll.JsSetCurrentContext(second.context))
            try:
                self.assertEqual(first.run('"first"'), 'first')
                current = ctypes.c_void_p()
                first._check(first.dll.JsGetCurrentContext(ctypes.byref(current)))
                self.assertEqual(current.value, second.context.value)
            finally:
                first._check(first.dll.JsSetCurrentContext(None))
        finally:
            first.close(); second.close()

    def test_language_state_unicode_and_absent_host_bridges(self):
        with JavaScriptRuntime() as runtime:
            runtime.run('var история = {книги:[1,2,3]}; история.книги.splice(1,1);')
            value = runtime.run('JSON.stringify([история.книги, "Книга ё 😀", '
                                'typeof ActiveXObject, typeof WScript, typeof require, '
                                'typeof process, typeof fetch, typeof XMLHttpRequest])')
            self.assertEqual(json.loads(value), [[1, 3], 'Книга ё 😀'] + ['undefined'] * 6)
            for expression in ['eval("1+1")', '(new Function("return 1"))()',
                               '({}).constructor.constructor("return 1")()']:
                with self.assertRaises(JavaScriptError):
                    runtime.run(expression)
            self.assertEqual(runtime.run('1+2'), '3')

    def test_parse_does_not_execute_and_rejects_invalid_source(self):
        with JavaScriptRuntime() as runtime:
            runtime.run('var changed = false;')
            runtime.parse('changed = true; while (true) {}')
            self.assertEqual(runtime.run('changed'), 'false')
            for source in ['function {', '1\0+2', 'x' * (runtime.MAX_SOURCE + 1)]:
                with self.assertRaises(JavaScriptError):
                    runtime.parse(source)
            self.assertEqual(runtime.run('changed'), 'false')

    def test_infinite_script_is_interrupted_and_runtime_recovers(self):
        with JavaScriptRuntime(timeout=0.1) as runtime:
            started = time.monotonic()
            with self.assertRaisesRegex(JavaScriptError, 'время'):
                runtime.run('while (true) {}')
            self.assertLess(time.monotonic() - started, 5)
            self.assertEqual(runtime.run('6*7'), '42')

    def test_runtime_memory_limit_and_independent_sessions(self):
        with JavaScriptRuntime(memory_limit=8 * 1024 * 1024) as runtime:
            with self.assertRaises(JavaScriptError):
                runtime.run('var store=[]; for(var i=0;i<100000;i++) '
                            'store.push(new Array(1024).join("0123456789"));')
        with JavaScriptRuntime() as runtime:
            self.assertEqual(runtime.run('typeof store'), 'undefined')

    def test_interleaved_contexts_and_early_close_are_independent(self):
        first, second = JavaScriptRuntime(), JavaScriptRuntime()
        try:
            first.run('var value = "first";')
            second.run('var value = "second";')
            self.assertEqual(first.run('value'), 'first')
            self.assertEqual(second.run('value'), 'second')
            first.close()
            self.assertEqual(second.run('value'), 'second')
        finally:
            first.close()
            second.close()


if __name__ == '__main__':
    unittest.main()
