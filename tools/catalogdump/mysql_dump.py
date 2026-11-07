"""Read data rows from a MySQL catalogue dump without executing SQL."""
import gzip
from pathlib import Path
import re


MAX_STATEMENT = 16 * 1024 * 1024
IDENTIFIER = rb"`?([a-z_][a-z_0-9]*)`?"
CREATE = re.compile(rb"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?" + IDENTIFIER + rb"\s*\(", re.I)
COLUMN = re.compile(rb"^\s*`([a-z_][a-z_0-9]*)`\s+[a-z]", re.I | re.M)
INSERT = re.compile(rb"INSERT\s+(?:IGNORE\s+)?INTO\s+" + IDENTIFIER +
                    rb"\s*(?:\(([a-z0-9_`,\s]+)\)\s*)?VALUES\s*", re.I)
VALUE = re.compile(rb"\s*('(?:[^'\\]++|\\.|'')*+'|NULL|0x[0-9a-f]+|[+-]?[0-9]+(?:\.[0-9]+)?)\s*([,)])",
                   re.I | re.S)
NAMES = re.compile(rb"^(?:/\*!\d+\s+)?SET\s+NAMES\s+[\x27\x22]?([a-z0-9_]+)", re.I)
ESCAPE = re.compile(rb"\\(.)|''", re.S)
ESCAPES = {ord(key): ord(value) for key, value in (("0", "\0"), ("b", "\b"), ("n", "\n"),
                                                ("r", "\r"), ("t", "\t"), ("Z", "\x1a"))}
ENCODINGS = {b"utf8": "utf-8", b"utf8mb3": "utf-8", b"utf8mb4": "utf-8", b"cp1251": "cp1251"}


class DumpError(ValueError):
    pass


def decode(token, encoding):
    if token.upper() == b"NULL":
        return None
    if token.startswith(b"'"):
        def unescape(match):
            if match[1] is None:
                return b"'"
            escaped = match[1][0]
            return bytes((ESCAPES.get(escaped, escaped),))
        return ESCAPE.sub(unescape, token[1:-1]).decode(encoding)
    return token.decode("ascii")


def value_rows(statement, start, width, indices, encoding):
    while True:
        while statement[start:start + 1].isspace():
            start += 1
        if statement[start:start + 1] != b"(":
            raise DumpError("ожидалась строка данных INSERT")
        start += 1
        tokens = []
        for index in range(width):
            match = VALUE.match(statement, start)
            expected = b")" if index == width - 1 else b","
            if match is None or match[2] != expected:
                raise DumpError("значения INSERT не соответствуют полям таблицы")
            tokens.append(match[1])
            start = match.end()
        yield tuple(decode(tokens[index], encoding) if index is not None else None for index in indices)
        while statement[start:start + 1].isspace():
            start += 1
        separator = statement[start:start + 1]
        if separator == b";" and start + 1 == len(statement):
            return
        if separator != b",":
            raise DumpError("неверный разделитель между строками INSERT")
        start += 1


def read_statement(first, stream):
    parts = [first]
    size = len(first)
    while not parts[-1].rstrip().endswith(b";"):
        part = stream.readline(MAX_STATEMENT - size + 1)
        size += len(part)
        if size > MAX_STATEMENT:
            raise DumpError("слишком длинная команда в SQL-дампе")
        if not part:
            raise DumpError("SQL-дамп оборван посреди команды")
        parts.append(part)
    return b"".join(parts).rstrip()


def selected_columns(columns, required, optional):
    if len(columns) != len(set(columns)):
        raise DumpError("поля таблицы повторяются")
    missing = set(required) - set(columns)
    if missing:
        raise DumpError("нет полей " + ", ".join(sorted(missing)))
    return tuple(columns.index(name) if name in columns else None for name in (*required, *optional))


def read_rows(path, table, required, optional=()):
    """Yield selected lower-case columns in the caller's order."""
    path = Path(path)
    columns, default_indices = (), ()
    encoding = "utf-8"
    opener = gzip.open if path.suffix.lower() == ".gz" else open
    try:
        with opener(path, "rb") as stream:
            while first := stream.readline(MAX_STATEMENT + 1):
                if len(first) > MAX_STATEMENT:
                    raise DumpError("слишком длинная строка в SQL-дампе")
                first = first.removeprefix(b"\xef\xbb\xbf").lstrip()
                if match := NAMES.match(first):
                    encoding = ENCODINGS.get(match[1].lower())
                    if encoding is None:
                        raise DumpError("неподдерживаемая кодировка SQL-дампа")
                elif match := CREATE.match(first):
                    if columns or match[1].decode("ascii").lower() != table:
                        raise DumpError(f"ожидалась только таблица {table}")
                    definition = read_statement(first, stream)
                    columns = tuple(name.decode("ascii").lower() for name in COLUMN.findall(definition[match.end():]))
                    default_indices = selected_columns(columns, required, optional)
                elif first[:6].upper() == b"INSERT":
                    match = INSERT.match(first)
                    if match is None or match[1].decode("ascii").lower() != table or not columns:
                        raise DumpError(f"ожидалась команда INSERT VALUES для таблицы {table}")
                    if match[2] is not None:
                        insert_columns = tuple(part.strip(b" \t\r\n`").decode("ascii").lower()
                                               for part in match[2].split(b","))
                        if set(insert_columns) - set(columns):
                            raise DumpError("INSERT указывает неизвестное поле")
                        indices = selected_columns(insert_columns, required, optional)
                    else:
                        insert_columns, indices = columns, default_indices
                    statement = read_statement(first, stream)
                    yield from value_rows(statement, match.end(), len(insert_columns), indices, encoding)
        if not columns:
            raise DumpError(f"нет описания таблицы {table}")
    except (DumpError, OSError, EOFError, UnicodeError) as error:
        raise DumpError(f"{path.name}: {error}") from error
