"""Line reader for UMLS/RxNorm Rich Release Format files: ``|``-separated, one record per line,
a trailing ``|`` after the last field. Lines are read with a cap so a hostile file without line
breaks cannot exhaust memory; the files themselves are read incrementally."""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

from catalog.importers.base import ImporterDataError

MAX_LINE_CHARS = 64 * 1024
SEPARATOR = "|"


def iter_rrf(path: Path, min_fields: int) -> Iterator[list[str]]:
    """Fields of every line that has at least ``min_fields`` of them; shorter lines are noise."""
    try:
        with path.open("r", encoding="utf-8", newline="") as handle:
            while line := handle.readline(MAX_LINE_CHARS + 1):
                if len(line) > MAX_LINE_CHARS and not line.endswith("\n"):
                    raise ImporterDataError("invalid_snapshot")
                fields = line.rstrip("\r\n").split(SEPARATOR)
                if len(fields) >= min_fields:
                    yield fields
    except UnicodeDecodeError:
        raise ImporterDataError("invalid_snapshot") from None
