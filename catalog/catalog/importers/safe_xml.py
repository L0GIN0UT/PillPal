"""Guards for XML that comes from a source file (xlsx parts, ESKLP XML).

The standard-library parser is used with two precautions instead of a new dependency. A document
type declaration is refused outright: entities and external subsets are the whole attack surface
(billion laughs, external references), and neither Excel nor an official register export needs
them. And the stream counts the bytes the parser actually receives, so a header that lies about a
part's size does not lift the cap. Only ASCII-compatible encodings are accepted: a UTF-16 document
would hide the markers the scan looks for.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from typing import IO, Literal
from xml.etree import ElementTree as ET

from catalog.importers.base import ImporterDataError

Event = Literal["start", "end"]
_FORBIDDEN = (b"<!DOCTYPE", b"<!ENTITY")
_OVERLAP = max(len(marker) for marker in _FORBIDDEN) - 1
_DECLARATION_BYTES = 200
_ENCODING = re.compile(rb"""^\s*<\?xml[^>]*encoding\s*=\s*["']([A-Za-z0-9._-]+)["']""")
_ALLOWED_ENCODINGS = frozenset({b"utf-8", b"windows-1251", b"cp1251"})
_UNICODE_BOMS = (b"\xff\xfe", b"\xfe\xff", b"\x00<", b"<\x00")
_UTF8_BOM = b"\xef\xbb\xbf"


def iterparse(stream: GuardedStream, events: tuple[Event, ...]) -> Iterator[tuple[str, ET.Element]]:
    """Incremental parse of a guarded stream; the only place the XML parser is called."""
    # S314: the stream refuses DOCTYPE and ENTITY declarations before the parser sees them.
    return ET.iterparse(stream, events=events)  # noqa: S314


def local_name(tag: str) -> str:
    """``{namespace}name`` -> ``name`` (the strict and transitional OOXML namespaces differ)."""
    return tag.rpartition("}")[2]


class GuardedStream:
    """A read-only view of an XML byte stream with a byte cap and the marker scan."""

    def __init__(self, raw: IO[bytes], max_bytes: int, too_large: str, invalid: str) -> None:
        self._raw = raw
        self._max = max_bytes
        self._too_large = too_large
        self._invalid = invalid
        self._count = 0
        self._tail = b""
        self._first = True

    def read(self, size: int = -1) -> bytes:
        chunk = self._raw.read(size)
        self._count += len(chunk)
        if self._count > self._max:
            raise ImporterDataError(self._too_large)
        if self._first and chunk:
            self._first = False
            self._check_declaration(chunk)
        window = self._tail + chunk
        if any(marker in window for marker in _FORBIDDEN):
            raise ImporterDataError(self._invalid)
        self._tail = window[-_OVERLAP:]
        return chunk

    def close(self) -> None:
        self._raw.close()

    def __enter__(self) -> GuardedStream:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def _check_declaration(self, head: bytes) -> None:
        if head.startswith(_UNICODE_BOMS):
            raise ImporterDataError(self._invalid)
        found = _ENCODING.match(head.removeprefix(_UTF8_BOM)[:_DECLARATION_BYTES])
        if found is not None and found.group(1).lower() not in _ALLOWED_ENCODINGS:
            raise ImporterDataError(self._invalid)
