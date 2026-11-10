"""The revoke sweep never stalls on rows that always fail (milestone 5.9, from the 5.8 re-check).

Each run pages through every pending row, and a blob that cannot be opened is dropped."""

from __future__ import annotations

import uuid
from collections.abc import Callable
from datetime import UTC, datetime

import httpx
from sqlalchemy import text

from app.oauth.apple_tokens import APPLE_REVOKE_URL
from app.services.data_encryption import DataKeyring
from app.services.provider_tokens import REFRESH_PURPOSE, revoke_pending_tokens
from tests.grace_helpers import count, request_deletion, scalar
from tests.helpers import register
from tests.oauth_real_flow_helpers import Real, bearer
from tests.oauth_real_helpers import REFRESH_TOKEN

POISON = "poison-"
PENDING_TOKENS = "provider_refresh_token_enc IS NOT NULL"


async def plant(real: Real, number: int, blob: Callable[[uuid.UUID], bytes]) -> None:
    """A pending-deletion account with an Apple identity older than any real one."""
    user = await register(real.client, email=f"poison-{number}@example.com", region="eu")
    assert (await request_deletion(real.client, user)).status_code == 204
    identity_id = uuid.uuid4()
    async with real.engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO auth_identities (id, user_id, provider, subject, created_at,"
                " provider_refresh_token_enc) VALUES (CAST(:id AS uuid), CAST(:user AS uuid),"
                " 'apple', :subject, now() - make_interval(days => :age), CAST(:blob AS bytea))"
            ),
            {
                "id": str(identity_id),
                "user": user.id,
                "subject": f"poison-subject-{number}",
                "age": 10 - number,
                "blob": blob(identity_id),
            },
        )


def sealed_poison(real: Real) -> Callable[[uuid.UUID], bytes]:
    keyring = DataKeyring.from_settings(real.app.state.settings)
    assert keyring is not None

    def seal(identity_id: uuid.UUID) -> bytes:
        return keyring.encrypt(REFRESH_PURPOSE, identity_id, f"{POISON}{identity_id}".encode())

    return seal


async def pending_real_account(real: Real) -> None:
    tokens = await real.apple_account()
    headers = bearer(tokens)
    form = await real.reauth_apple(headers)
    resp = await real.client.request("DELETE", "/v1/me", json=form, headers=headers)
    assert resp.status_code == 204, resp.text


def apple_refuses_poison(real: Real) -> None:
    original = real.apple.handler

    def handler(request: httpx.Request) -> httpx.Response:
        if str(request.url) == APPLE_REVOKE_URL and POISON in request.content.decode():
            real.apple.calls.append((str(request.url), {"token": POISON}))
            return httpx.Response(500)
        return original(request)

    real.apple.handler = handler  # type: ignore[method-assign,assignment]


async def test_rows_that_keep_failing_do_not_starve_the_rows_behind_them(real: Real) -> None:
    for number in range(3):
        await plant(real, number, sealed_poison(real))
    await pending_real_account(real)  # the newest row: behind all the failing ones
    apple_refuses_poison(real)
    cleared = await real.sweep(limit=2)  # a page is smaller than the failing backlog
    assert cleared == 1
    revoked = [form for _, form in real.apple.calls if form.get("token") == REFRESH_TOKEN]
    assert len(revoked) == 1
    assert await count(real.engine, "auth_identities", PENDING_TOKENS) == 3  # only the poison


async def test_a_failing_row_is_tried_again_by_the_next_sweep(real: Real) -> None:
    await plant(real, 0, sealed_poison(real))
    apple_refuses_poison(real)
    assert await real.sweep() == 0
    assert await real.sweep() == 0
    assert await count(real.engine, "auth_identities", PENDING_TOKENS) == 1


async def test_a_blob_that_cannot_be_opened_is_dropped_and_the_rest_continue(real: Real) -> None:
    for number in range(3):
        await plant(real, number, lambda _id: b"not a sealed token")
    await pending_real_account(real)
    cleared = await real.sweep(limit=1)  # one row per page: the sweep must keep paging
    assert cleared == 4  # three dropped, one revoked
    assert len(real.revokes()) == 1  # Apple was asked about the readable one only
    assert await count(real.engine, "auth_identities", PENDING_TOKENS) == 0
    assert await real.sweep() == 0  # nothing left


async def test_a_sweep_for_one_account_ignores_the_others(real: Real) -> None:
    await plant(real, 0, lambda _id: b"not a sealed token")
    await pending_real_account(real)
    user_id = await scalar(
        real.engine, "SELECT user_id FROM auth_identities WHERE subject NOT LIKE 'poison-%'"
    )
    cleared = await revoke_pending_tokens(
        real.app.state.sessionmaker,
        real.tokens(),
        datetime.now(UTC),
        limit=10,
        user_id=uuid.UUID(str(user_id)),
    )
    assert cleared == 1
    assert await count(real.engine, "auth_identities", PENDING_TOKENS) == 1  # the other one stays


async def test_an_outage_stops_the_run_after_a_few_failures_and_the_next_run_continues(
    real: Real,
) -> None:
    for number in range(4):
        await plant(real, number, sealed_poison(real))
    apple_refuses_poison(real)
    maker = real.app.state.sessionmaker
    stopped = await revoke_pending_tokens(
        maker, real.tokens(), datetime.now(UTC), limit=10, max_consecutive_failures=2
    )
    assert stopped == 0
    asked = len([1 for _, form in real.apple.calls if form.get("token") == POISON])
    assert asked == 4  # two rows, one try and one retry each; the other two were not asked


async def test_a_spent_time_budget_stops_the_run(real: Real) -> None:
    await plant(real, 0, lambda _id: b"not a sealed token")
    ticks = iter([0.0, 1000.0, 2000.0])
    cleared = await revoke_pending_tokens(
        real.app.state.sessionmaker,
        real.tokens(),
        datetime.now(UTC),
        limit=10,
        budget_seconds=10,
        monotonic=lambda: next(ticks),
    )
    assert cleared == 0
    assert await count(real.engine, "auth_identities", PENDING_TOKENS) == 1
