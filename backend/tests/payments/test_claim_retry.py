"""The claim retries once when the conflicting row vanished before it was read (pure: scripted)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from types import SimpleNamespace
from typing import Any

from app.payments.base import VerifiedPurchase
from app.services.purchases import ClaimOutcome, claim_purchase

NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)
PURCHASE = VerifiedPurchase(
    store="app_store",
    product_id="synthetic.remove_ads",
    product_kind="remove_ads",
    original_transaction_id="2000000000001",
    environment="production",
    purchased_at=NOW,
)


class ScriptedSession:
    """Answers the claim's statements in order: the user lock, then insert and owner lookups."""

    def __init__(self, inserts: list[bool], owners: list[uuid.UUID | None]) -> None:
        self._inserts = inserts
        self._owners = owners
        self.added: list[Any] = []
        self.committed = False
        self.rolled_back = False
        self.insert_calls = 0

    async def scalar(self, stmt: Any) -> Any:
        if "FROM users" in str(stmt):
            return SimpleNamespace(pending_deletion=False)
        return self._owners.pop(0)

    async def execute(self, stmt: Any) -> Any:
        self.insert_calls += 1
        won = self._inserts.pop(0)
        return SimpleNamespace(first=lambda: (uuid.uuid4(),) if won else None)

    def add(self, row: Any) -> None:
        self.added.append(row)

    async def commit(self) -> None:
        self.committed = True

    async def rollback(self) -> None:
        self.rolled_back = True


async def test_a_vanished_conflicting_row_is_retried_once() -> None:
    session = ScriptedSession(inserts=[False, True], owners=[None])
    outcome = await claim_purchase(session, uuid.uuid4(), PURCHASE, NOW)  # type: ignore[arg-type]
    assert outcome is ClaimOutcome.CREATED
    assert session.insert_calls == 2
    assert len(session.added) == 2
    assert session.committed


async def test_a_row_that_keeps_vanishing_is_refused_not_retried_forever() -> None:
    session = ScriptedSession(inserts=[False, False], owners=[None, None])
    outcome = await claim_purchase(session, uuid.uuid4(), PURCHASE, NOW)  # type: ignore[arg-type]
    assert outcome is ClaimOutcome.CLAIMED_BY_OTHER
    assert session.insert_calls == 2
    assert session.rolled_back
    assert not session.committed


async def test_an_existing_row_of_another_account_is_not_retried() -> None:
    session = ScriptedSession(inserts=[False], owners=[uuid.uuid4()])
    outcome = await claim_purchase(session, uuid.uuid4(), PURCHASE, NOW)  # type: ignore[arg-type]
    assert outcome is ClaimOutcome.CLAIMED_BY_OTHER
    assert session.insert_calls == 1
