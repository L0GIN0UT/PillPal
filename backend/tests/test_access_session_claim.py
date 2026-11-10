"""The access token carries ``sid``: the refresh family of its session (ADR 0016 section 8)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import jwt

from app.security import JWT_ALGORITHM, TokenService
from tests.conftest import make_settings


def test_sid_round_trips() -> None:
    tokens = TokenService(make_settings())
    user, session = uuid.uuid4(), uuid.uuid4()
    claims = tokens.decode_access(tokens.issue_access(user, session_id=session))
    assert claims is not None
    assert (claims.user_id, claims.session_id) == (user, session)


def test_a_token_without_sid_still_decodes_with_no_session() -> None:
    tokens = TokenService(make_settings())
    claims = tokens.decode_access(tokens.issue_access(uuid.uuid4(), datetime.now(UTC)))
    assert claims is not None
    assert claims.session_id is None


def test_a_malformed_sid_is_an_invalid_token() -> None:
    settings = make_settings()
    tokens = TokenService(settings)
    good = tokens.issue_access(uuid.uuid4(), session_id=uuid.uuid4())
    claims = jwt.decode(good, options={"verify_signature": False})
    claims["sid"] = "not-a-uuid"
    forged = jwt.encode(claims, settings.jwt_secret.get_secret_value(), algorithm=JWT_ALGORITHM)
    assert tokens.decode_access(forged) is None
