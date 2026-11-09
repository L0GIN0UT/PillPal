"""Incremental reading of a large JSON document: memory is bounded by one record."""

from __future__ import annotations

import json
import tracemalloc
from pathlib import Path
from typing import Any

import pytest

from catalog.importers.base import ImporterDataError
from catalog.importers.jsonstream import read_json_member, stream_json_array

BOUNDED_PEAK_BYTES = 6 * 1024 * 1024


def _write(tmp_path: Path, content: str) -> Path:
    path = tmp_path / "doc.json"
    path.write_text(content, encoding="utf-8")
    return path


def test_items_of_the_named_array_are_yielded_in_order(tmp_path: Path) -> None:
    path = _write(tmp_path, '{"meta": {"a": 1}, "results": [{"n": 1}, {"n": "2"}, [3], null]}')

    assert list(stream_json_array(path, "results")) == [{"n": 1}, {"n": "2"}, [3], None]


def test_other_members_and_an_empty_array_are_fine(tmp_path: Path) -> None:
    path = _write(tmp_path, '{"results": [], "x": "y", "meta": {"results": {"skip": 0}}}')

    assert list(stream_json_array(path, "results")) == []


def test_a_nested_key_with_the_same_name_is_not_the_array(tmp_path: Path) -> None:
    path = _write(tmp_path, '{"meta": {"results": [1, 2]}, "results": [9]}')

    assert list(stream_json_array(path, "results")) == [9]


def test_reads_a_small_member_before_the_array(tmp_path: Path) -> None:
    path = _write(tmp_path, '{"meta": {"last_updated": "2026-01-02"}, "results": [{"n": 1}]}')

    assert read_json_member(path, "meta") == {"last_updated": "2026-01-02"}
    assert read_json_member(path, "missing") is None


def test_unicode_and_escapes_survive_chunk_boundaries(tmp_path: Path) -> None:
    items = [{"name": "Тестамол é \U0001f48a " * 40, "i": i} for i in range(3000)]
    path = _write(tmp_path, json.dumps({"results": items}))

    assert list(stream_json_array(path, "results")) == items


def test_a_number_cut_by_a_chunk_boundary_is_read_whole(tmp_path: Path) -> None:
    numbers = list(range(10**9, 10**9 + 120_000))
    path = _write(tmp_path, json.dumps({"results": numbers}))

    assert list(stream_json_array(path, "results")) == numbers


@pytest.mark.parametrize(
    "content",
    [
        "",
        "[1, 2]",
        '{"results": [1, 2',
        '{"results": [1,]}',
        '{"results": [1 2]}',
        '{"results": [1],}',
        '{"results" [1]}',
        '{"results": [NaN]}',
        '{"results": [tru]}',
        "{" + '"results": [' * 3,
        '{"results": ' + "[" * 100_000 + "]" * 100_000 + "}",
    ],
)
def test_malformed_documents_raise_a_data_error(tmp_path: Path, content: str) -> None:
    path = _write(tmp_path, content)

    with pytest.raises(ImporterDataError) as caught:
        list(stream_json_array(path, "results"))
    assert caught.value.code == "invalid_snapshot"


def test_invalid_utf8_raises_a_data_error(tmp_path: Path) -> None:
    path = tmp_path / "doc.json"
    path.write_bytes(b'{"results": ["\xff"]}')

    with pytest.raises(ImporterDataError):
        list(stream_json_array(path, "results"))


def test_a_record_over_the_cap_is_refused(tmp_path: Path) -> None:
    path = _write(tmp_path, json.dumps({"results": ["x" * 5000]}))

    with pytest.raises(ImporterDataError) as caught:
        list(stream_json_array(path, "results", max_value_chars=1000))
    assert caught.value.code == "record_too_large"


def test_memory_stays_bounded_on_a_file_far_larger_than_the_peak(tmp_path: Path) -> None:
    path = tmp_path / "big.json"
    record: dict[str, Any] = {"name": "x" * 900, "list": list(range(20))}
    with path.open("w", encoding="utf-8") as out:
        out.write('{"meta": {}, "results": [')
        for i in range(30_000):
            out.write(("," if i else "") + json.dumps(record))
        out.write("]}")
    assert path.stat().st_size > 25 * 1024 * 1024

    tracemalloc.start()
    seen = sum(1 for _ in stream_json_array(path, "results"))
    _, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()

    assert seen == 30_000
    assert peak < BOUNDED_PEAK_BYTES
