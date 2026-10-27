"""Small, bounded Windows JSRT host (MIT).

This is a language runtime, without browser, COM, filesystem or network host
objects. Load only the operating system's Chakra.dll. No downloaded runtime,
ActiveX bridge, Python callback or user-provided DLL search path is exposed.
"""
import ctypes
import os
import threading


class JavaScriptError(ValueError):
    pass


class JavaScriptRuntime:
    MAX_SOURCE = 8 * 1024 * 1024
    MAX_RESULT = 8 * 1024 * 1024

    def __init__(self, memory_limit=64 * 1024 * 1024, timeout=2.0):
        if os.name != 'nt':
            raise JavaScriptError('Для интерактивной книги нужен Windows 10 или новее.')
        if not 1024 * 1024 <= memory_limit <= 256 * 1024 * 1024 or not 0.02 <= timeout <= 30:
            raise ValueError('Invalid JavaScript resource budget')
        self.owner = threading.get_ident()
        self.timeout = timeout
        self.runtime = ctypes.c_void_p()
        self.context = ctypes.c_void_p()
        self.context_retained = False
        self.closed = False
        self.sequence = 0
        try:
            # LOAD_LIBRARY_SEARCH_SYSTEM32: a book folder cannot replace it.
            self.dll = ctypes.WinDLL('Chakra.dll', winmode=0x800)
        except OSError as error:
            raise JavaScriptError('Системный движок JavaScript недоступен.') from error
        ptr, size = ctypes.c_void_p, ctypes.c_size_t
        out_ptr = ctypes.POINTER(ptr)
        signatures = {
            'JsCreateRuntime': [ctypes.c_uint, ptr, out_ptr],
            'JsCreateContext': [ptr, out_ptr],
            'JsAddRef': [ptr, ctypes.POINTER(ctypes.c_uint)],
            'JsRelease': [ptr, ctypes.POINTER(ctypes.c_uint)],
            'JsGetCurrentContext': [out_ptr],
            'JsSetCurrentContext': [ptr],
            'JsSetRuntimeMemoryLimit': [ptr, size],
            'JsCollectGarbage': [ptr],
            'JsRunScript': [ctypes.c_wchar_p, size, ctypes.c_wchar_p, out_ptr],
            'JsParseScript': [ctypes.c_wchar_p, size, ctypes.c_wchar_p, out_ptr],
            'JsConvertValueToString': [ptr, out_ptr],
            'JsStringToPointer': [ptr, out_ptr, ctypes.POINTER(size)],
            'JsGetAndClearException': [out_ptr],
            'JsDisableRuntimeExecution': [ptr],
            'JsEnableRuntimeExecution': [ptr],
            'JsDisposeRuntime': [ptr],
        }
        for name, arguments in signatures.items():
            function = getattr(self.dll, name)
            function.argtypes, function.restype = arguments, ctypes.c_uint
        try:
            # Interruptible, interpreter only, no eval/Function constructor.
            # OOM must be a recoverable error, not the engine's fail-fast exit.
            self._check(self.dll.JsCreateRuntime(0x02 | 0x08 | 0x10 | 0x80, None,
                                                ctypes.byref(self.runtime)))
            self._check(self.dll.JsSetRuntimeMemoryLimit(self.runtime, memory_limit))
            self._check(self.dll.JsCreateContext(self.runtime, ctypes.byref(self.context)))
            # ctypes keeps handles on Python's heap, outside Chakra's stack
            # scanner. Contexts also need a root while another one is active.
            self._check(self.dll.JsAddRef(self.context, None))
            self.context_retained = True
        except BaseException:
            self.close()
            raise

    @staticmethod
    def _check(status):
        if status:
            raise JavaScriptError('Ошибка JavaScript: 0x%08X.' % status)

    def _thread(self):
        if threading.get_ident() != self.owner:
            raise JavaScriptError('Сеанс JavaScript принадлежит другому потоку.')
        if self.closed:
            raise JavaScriptError('Сеанс JavaScript уже закрыт.')

    def _execute(self, source, parse_only):
        self._thread()
        if not isinstance(source, str) or '\0' in source or len(source) > self.MAX_SOURCE:
            raise JavaScriptError('Повреждённый или слишком большой сценарий книги.')
        previous = ctypes.c_void_p()
        self._check(self.dll.JsGetCurrentContext(ctypes.byref(previous)))
        if previous.value:
            self._check(self.dll.JsAddRef(previous, None))
        try:
            self._check(self.dll.JsSetCurrentContext(self.context))
            expired = threading.Event()

            def interrupt():
                expired.set()
                self.dll.JsDisableRuntimeExecution(self.runtime)

            timer = threading.Timer(self.timeout, interrupt)
            timer.daemon = True
            timer_started, roots = False, []
            try:
                timer.start()
                timer_started = True
                # Finish idle collection before starting the next command.
                # System Chakra's deferred Array.join strings proved unsafe
                # under allocation pressure between separate ctypes calls.
                # A usage threshold was insufficient. Collect while no new
                # temporary result exists; preserve all live book state and
                # keep the same hard memory limit and execution deadline.
                if not parse_only:
                    self._check(self.dll.JsCollectGarbage(self.runtime))
                self.sequence += 1
                result = ctypes.c_void_p()
                function = self.dll.JsParseScript if parse_only else self.dll.JsRunScript
                self._check(function(source, self.sequence, 'homelib://interactive-book',
                                     ctypes.byref(result)))
                if parse_only:
                    return None
                self._check(self.dll.JsAddRef(result, None)); roots.append(result)
                string, pointer, length = ctypes.c_void_p(), ctypes.c_void_p(), ctypes.c_size_t()
                self._check(self.dll.JsConvertValueToString(result, ctypes.byref(string)))
                self._check(self.dll.JsAddRef(string, None)); roots.append(string)
                self._check(self.dll.JsStringToPointer(string, ctypes.byref(pointer),
                                                      ctypes.byref(length)))
                if length.value > self.MAX_RESULT:
                    raise JavaScriptError('Слишком большой ответ сценария книги.')
                return ctypes.wstring_at(pointer, length.value)
            finally:
                try:
                    timer.cancel()
                    if timer_started:
                        timer.join()
                    self.dll.JsEnableRuntimeExecution(self.runtime)
                    exception = ctypes.c_void_p()
                    self.dll.JsGetAndClearException(ctypes.byref(exception))
                    # Keep the result and converted string rooted until the
                    # native string has been copied into a Python string.
                    for value in reversed(roots):
                        self._check(self.dll.JsRelease(value, None))
                finally:
                    if expired.is_set():
                        raise JavaScriptError('Сценарий книги превысил время выполнения.')
        finally:
            try:
                self.dll.JsSetCurrentContext(previous)
            finally:
                if previous.value:
                    self._check(self.dll.JsRelease(previous, None))

    def run(self, source):
        return self._execute(source, False)

    def parse(self, source):
        self._execute(source, True)

    def close(self):
        if self.closed:
            return
        self._thread()
        if self.runtime:
            self.dll.JsEnableRuntimeExecution(self.runtime)
            if self.context_retained:
                self._check(self.dll.JsRelease(self.context, None))
                self.context_retained = False
            self._check(self.dll.JsDisposeRuntime(self.runtime))
        self.closed = True

    def __enter__(self):
        self._thread()
        return self

    def __exit__(self, *error):
        self.close()
