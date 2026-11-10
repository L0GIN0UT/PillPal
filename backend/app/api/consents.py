"""/v1/me/consents: which texts the account accepted (Phase 5.2a)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Response, status

from app.deps import CurrentUser, NowDep, SessionDep, SettingsDep, limit_by_user
from app.domain.consents import BASELINE_KINDS
from app.errors import AppError
from app.schemas.consents import (
    ConsentIn,
    ConsentRecordOut,
    ConsentsOut,
    ConsentWithdrawIn,
    ConsentWithdrawOut,
)
from app.services import consent_ledger, consents

router = APIRouter(prefix="/v1/me/consents", tags=["consents"])


@router.get("")
async def get_consents(
    user: CurrentUser, session: SessionDep, settings: SettingsDep
) -> ConsentsOut:
    """The current version of every text, the account's records and the required kinds that
    have no active record of the current version (the app shows a blocking screen for them)."""
    records = await consents.list_records(session, user.id)
    return ConsentsOut(
        current=consents.current_versions(settings),
        records=[ConsentRecordOut.model_validate(r) for r in records],
        missing=consents.missing_kinds(settings, records),
    )


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(limit_by_user("consent"))],
    responses={
        200: {"description": "The same version was already accepted; the record is unchanged"},
        422: {"description": "unsupported_consent_version, unsupported_consent_kind"},
    },
)
async def accept_consent(
    body: ConsentIn,
    response: Response,
    user: CurrentUser,
    session: SessionDep,
    settings: SettingsDep,
    now: NowDep,
) -> ConsentRecordOut:
    """Accept the current version of health data, terms or privacy. The catalog contribution
    is recorded where it is given, not here."""
    row, created = await consents.accept(session, settings, user.id, body, now)
    if not created:
        response.status_code = status.HTTP_200_OK
    return ConsentRecordOut.model_validate(row)


@router.post(
    "/withdraw",
    dependencies=[Depends(limit_by_user("consent"))],
    responses={409: {"description": "withdraw_via_account_deletion"}},
)
async def withdraw_consent(
    body: ConsentWithdrawIn, user: CurrentUser, session: SessionDep, now: NowDep
) -> ConsentWithdrawOut:
    """Health data, terms and privacy are withdrawn by deleting the account (ADR 0010). The
    catalog contribution is withdrawn here: it resets the account's links to the catalog, and
    the account's other devices see that in their next pull (ADR 0016 section 4)."""
    if body.kind in BASELINE_KINDS:
        raise AppError(
            409,
            "withdraw_via_account_deletion",
            "This consent is withdrawn by deleting the account",
        )
    reset = await consent_ledger.withdraw_contribution(session, user.id, now)
    await session.commit()
    return ConsentWithdrawOut(reset_links=reset)
