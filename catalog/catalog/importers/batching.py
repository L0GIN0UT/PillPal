"""Groups a lazy record stream into batches of one level (substance, composition or product), so
the loader holds one batch in memory instead of the whole snapshot."""

from __future__ import annotations

from collections.abc import Iterator

from catalog.importers.base import RECORD_LEVELS, ImporterDataError, Record


def _level(record: Record) -> int:
    return RECORD_LEVELS.index(type(record))


class RecordBatcher:
    """``next_batch`` returns up to ``size`` consecutive records of one level; empty at the end.

    Levels must not go back (a substance after a product): the loader has already written the
    earlier level and later levels only refer backwards, so a snapshot out of order is refused.
    """

    def __init__(self, records: Iterator[Record], size: int) -> None:
        self._records = records
        self._size = size
        self._pending: Record | None = None
        self._level = 0

    def _take(self) -> Record | None:
        if self._pending is not None:
            record, self._pending = self._pending, None
            return record
        return next(self._records, None)

    def next_batch(self) -> list[Record]:
        first = self._take()
        if first is None:
            return []
        level = _level(first)
        if level < self._level:
            raise ImporterDataError("records_out_of_order")
        self._level = level
        batch = [first]
        while len(batch) < self._size:
            record = self._take()
            if record is None:
                break
            if _level(record) != level:
                self._pending = record
                break
            batch.append(record)
        return batch
