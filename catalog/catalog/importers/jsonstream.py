"""Incremental reader of a large JSON document (openFDA bulk files are hundreds of megabytes).

The standard library parses a document only as a whole. This reader walks the top-level object
and decodes one member, or one item of one chosen array, at a time from a bounded text buffer,
so memory is bounded by the largest single record, not by the file. A snapshot is untrusted:
one record larger than ``max_value_chars`` is refused, deep nesting and invalid UTF-8 become a
data error, and no error message carries file content.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path
from typing import Any, TextIO

from catalog.importers.base import ImporterDataError

CHUNK_CHARS = 256 * 1024
DEFAULT_MAX_VALUE_CHARS = 8 * 1024 * 1024
_WHITESPACE = " \t\n\r"


def _reject_constant(name: str) -> Any:
    raise ValueError(name)  # NaN and Infinity are not JSON


_DECODER = json.JSONDecoder(parse_constant=_reject_constant)


def _invalid() -> ImporterDataError:
    return ImporterDataError("invalid_snapshot")


class _Reader:
    def __init__(self, handle: TextIO, max_value_chars: int) -> None:
        self._handle = handle
        self._max = max_value_chars
        self.buf = ""
        self.pos = 0
        self._eof = False

    def _fill(self) -> bool:
        if self._eof:
            return False
        chunk = self._handle.read(CHUNK_CHARS)
        if not chunk:
            self._eof = True
            return False
        self.buf = self.buf[self.pos :] + chunk
        self.pos = 0
        return True

    def peek(self) -> str | None:
        """Next non-whitespace character without consuming it; ``None`` at the end."""
        while True:
            while self.pos < len(self.buf) and self.buf[self.pos] in _WHITESPACE:
                self.pos += 1
            if self.pos < len(self.buf):
                return self.buf[self.pos]
            if not self._fill():
                return None

    def expect(self, char: str) -> None:
        if self.peek() != char:
            raise _invalid()
        self.pos += 1

    def decode(self) -> Any:
        """Decode the value at the cursor, reading more input while it is incomplete."""
        if self.peek() is None:
            raise _invalid()
        while True:
            try:
                value, end = _DECODER.raw_decode(self.buf, self.pos)
            except RecursionError:
                raise _invalid() from None
            except ValueError:
                value, end = None, -1
            # A value that ends at the buffer end may be a cut number: read on to be sure.
            if end != -1 and (end < len(self.buf) or self._eof):
                return self._take(value, end)
            if len(self.buf) - self.pos > self._max:
                raise ImporterDataError("record_too_large")
            if not self._fill():
                if end == -1:
                    raise _invalid()
                return self._take(value, end)

    def _take(self, value: Any, end: int) -> Any:
        if end - self.pos > self._max:
            raise ImporterDataError("record_too_large")
        self.pos = end
        return value


def _items(reader: _Reader) -> Iterator[Any]:
    reader.expect("[")
    if reader.peek() == "]":
        reader.pos += 1
        return
    while True:
        yield reader.decode()
        char = reader.peek()
        if char == "]":
            reader.pos += 1
            return
        reader.expect(",")
        if reader.peek() == "]":
            raise _invalid()  # a trailing comma


def _members(reader: _Reader, stream_key: str | None) -> Iterator[tuple[str, bool, Any]]:
    """Top-level members as ``(key, is_item, value)``; items of ``stream_key`` one by one."""
    reader.expect("{")
    if reader.peek() == "}":
        return
    while True:
        key = reader.decode()
        if not isinstance(key, str):
            raise _invalid()
        reader.expect(":")
        if key == stream_key and reader.peek() == "[":
            for item in _items(reader):
                yield key, True, item
        else:
            yield key, False, reader.decode()
        if reader.peek() == "}":
            return
        reader.expect(",")
        if reader.peek() == "}":
            raise _invalid()  # a trailing comma


def _open(path: Path) -> TextIO:
    return path.open("r", encoding="utf-8")


def stream_json_array(
    path: Path, key: str, *, max_value_chars: int = DEFAULT_MAX_VALUE_CHARS
) -> Iterator[Any]:
    """Items of the top-level array ``key``, one at a time; other members are dropped."""
    try:
        with _open(path) as handle:
            reader = _Reader(handle, max_value_chars)
            for _, is_item, value in _members(reader, key):
                if is_item:
                    yield value
    except UnicodeDecodeError:
        raise _invalid() from None


def read_json_member(
    path: Path, key: str, *, max_value_chars: int = DEFAULT_MAX_VALUE_CHARS
) -> Any | None:
    """The top-level member ``key`` (a small value such as ``meta``), or ``None`` if absent."""
    try:
        with _open(path) as handle:
            for name, _, value in _members(_Reader(handle, max_value_chars), None):
                if name == key:
                    return value
    except UnicodeDecodeError:
        raise _invalid() from None
    return None
