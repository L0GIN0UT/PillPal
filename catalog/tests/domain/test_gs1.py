"""Properties of the GS1 parser that the vectors cannot express."""

from __future__ import annotations

import dataclasses
from datetime import date

import pytest

from catalog.domain.gs1 import Gs1Result, parse_gs1
from catalog.domain.gtin import Gtin, GtinError

GTIN = "04607012345677"


def test_result_has_no_field_for_lot_or_serial() -> None:
    # Privacy: lot (AI 10) and serial (AI 21) are consumed and discarded (docs/spec/gtin.md 5.3).
    fields = {f.name for f in dataclasses.fields(Gs1Result)}
    assert fields == {"gtin", "expiry", "partial"}


def test_result_is_immutable_and_expiry_is_a_plain_date() -> None:
    result = parse_gs1("01" + GTIN + "17271231")
    assert result.expiry == date(2027, 12, 31)
    assert type(result.expiry) is date
    with pytest.raises(dataclasses.FrozenInstanceError):
        result.partial = True  # type: ignore[misc]


def test_lot_and_serial_do_not_leak_into_the_repr() -> None:
    result = parse_gs1("01" + GTIN + "10SECRETLOT\x1d21SECRETSERIAL\x1d17271231")
    assert "SECRET" not in repr(result)
    assert isinstance(result.gtin, Gtin)


def test_error_carries_a_stable_code_and_never_echoes_input() -> None:
    with pytest.raises(GtinError) as info:
        parse_gs1("PRIVATE-NOT-A-CODE")
    assert info.value.code == "unsupported_format"
    assert "PRIVATE" not in str(info.value)


def test_repr_does_not_contain_the_gtin() -> None:
    result = parse_gs1("01" + GTIN + "17271231")
    assert GTIN not in repr(result)
    assert GTIN[1:] not in repr(result)
