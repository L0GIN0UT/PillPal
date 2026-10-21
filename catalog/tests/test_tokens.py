from __future__ import annotations

import hashlib

import pytest

from catalog import tokens
from catalog.config import TokenEntry
from catalog.tokens import match_token


def entry(name: str, secret: str) -> TokenEntry:
    return TokenEntry(name=name, sha256=hashlib.sha256(secret.encode()).hexdigest())


ENTRIES = (entry("ops", "a" * 40), entry("second", "b" * 40), entry("third", "c" * 40))


def test_returns_the_entry_whose_digest_matches() -> None:
    assert match_token("b" * 40, ENTRIES) == ENTRIES[1]


@pytest.mark.parametrize("presented", ["", "x" * 40, "A" * 40, "ö" * 40, ENTRIES[0].sha256])
def test_returns_none_for_anything_else(presented: str) -> None:
    # The digest itself is not the secret: presenting it must not authenticate.
    assert match_token(presented, ENTRIES) is None


def test_no_entries_never_match() -> None:
    assert match_token("a" * 40, ()) is None


def test_compares_against_every_entry_even_after_a_match(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[str, str]] = []
    real = tokens.hmac.compare_digest

    def counting(a: str, b: str) -> bool:
        calls.append((a, b))
        return real(a, b)

    monkeypatch.setattr(tokens.hmac, "compare_digest", counting)
    assert match_token("a" * 40, ENTRIES) == ENTRIES[0]  # the first one matches
    assert len(calls) == len(ENTRIES)
    calls.clear()
    assert match_token("zzz", ENTRIES) is None
    assert len(calls) == len(ENTRIES)
