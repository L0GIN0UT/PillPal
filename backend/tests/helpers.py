"""Test helpers: migrations runner and API shortcuts."""

from __future__ import annotations

import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from alembic.config import Config
from httpx import AsyncClient

from alembic import command

BACKEND_DIR = Path(__file__).resolve().parent.parent
DEFAULT_PASSWORD = "correct horse battery"


def alembic_config(url: str) -> Config:
    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND_DIR / "alembic"))
    cfg.set_main_option("sqlalchemy.url", url)
    return cfg


def _in_thread(fn: Any, *args: Any) -> Any:
    # Alembic's async env.py calls asyncio.run(); keep it off any running loop.
    with ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(fn, *args).result()


def run_migrations(url: str, revision: str) -> None:
    _in_thread(command.upgrade, alembic_config(url), revision)


def downgrade(url: str, revision: str) -> None:
    _in_thread(command.downgrade, alembic_config(url), revision)


def run_sync(fn: Any, *args: Any) -> Any:
    return _in_thread(fn, *args)


@dataclass
class User:
    id: str
    email: str
    password: str
    access_token: str
    refresh_token: str
    self_profile_id: str

    @property
    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.access_token}"}

    def device(self, device_id: str) -> dict[str, str]:
        return {**self.headers, "X-Device-ID": device_id}


def outbox(client: AsyncClient) -> list[Any]:
    """The in-memory e-mail outbox of the app behind ``client``."""
    app = client._transport.app  # type: ignore[attr-defined]
    return list(app.state.email_sender.outbox)


def last_code(client: AsyncClient, email: str, purpose: str = "verify_email") -> str:
    codes = [m.code for m in outbox(client) if m.to == email.lower() and m.purpose == purpose]
    assert codes, f"no {purpose} e-mail sent to {email}"
    return str(codes[-1])


async def register_unverified(
    client: AsyncClient,
    email: str | None = None,
    password: str = DEFAULT_PASSWORD,
    region: str = "ru",
    timezone: str = "Europe/Samara",
    **extra: Any,
) -> str:
    """POST /v1/auth/register only; returns the (lowercased) e-mail."""
    email = email or f"user-{uuid.uuid4().hex[:10]}@example.com"
    resp = await client.post(
        "/v1/auth/register",
        json={
            "email": email,
            "password": password,
            "region": region,
            "timezone": timezone,
            **extra,
        },
    )
    assert resp.status_code == 202, resp.text
    assert resp.json() == {"status": "verification_sent"}
    return email.strip().lower()


async def verify(
    client: AsyncClient, email: str, headers: dict[str, str] | None = None
) -> dict[str, Any]:
    resp = await client.post(
        "/v1/auth/verify-email",
        json={"email": email, "code": last_code(client, email)},
        headers=headers or {},
    )
    assert resp.status_code == 200, resp.text
    return dict(resp.json())


async def register(
    client: AsyncClient,
    email: str | None = None,
    password: str = DEFAULT_PASSWORD,
    region: str = "ru",
    timezone: str = "Europe/Samara",
) -> User:
    """Register, verify the e-mail with the mailed code and return the logged-in user."""
    email = await register_unverified(client, email, password, region, timezone)
    tokens = await verify(client, email)
    auth = {"Authorization": f"Bearer {tokens['access_token']}"}
    me = await client.get("/v1/me", headers=auth)
    assert me.status_code == 200, me.text
    profiles = await client.get("/v1/profiles", headers=auth)
    self_profile = next(p for p in profiles.json()["items"] if p["kind"] == "self")
    return User(
        id=me.json()["id"],
        email=email,
        password=password,
        access_token=tokens["access_token"],
        refresh_token=tokens["refresh_token"],
        self_profile_id=self_profile["id"],
    )


def daily_rule(times: tuple[str, ...] = ("08:00",), start: str = "2026-10-16") -> dict[str, Any]:
    return {
        "v": 1,
        "kind": "daily",
        "start_date": start,
        "end_date": None,
        "times": [{"time": t, "dose": {"amount": "1", "unit": "tablet"}} for t in times],
    }


def medication_payload(**overrides: Any) -> dict[str, Any]:
    data: dict[str, Any] = {
        "id": str(uuid.uuid4()),
        "name": "Aspirin",
        "form": "tablet",
        "strength_text": "100 mg",
        "notes": "after food",
        "tz_mode": "local",
        "fixed_tz": None,
        "privacy": "shared",
    }
    data.update(overrides)
    return data


async def create_medication(client: AsyncClient, user: User, **overrides: Any) -> dict[str, Any]:
    profile_id = overrides.pop("profile_id", user.self_profile_id)
    resp = await client.post(
        f"/v1/profiles/{profile_id}/medications",
        json=medication_payload(**overrides),
        headers=user.headers,
    )
    assert resp.status_code == 201, resp.text
    return dict(resp.json())


async def create_schedule(
    client: AsyncClient, user: User, medication_id: str, rule: dict[str, Any] | None = None
) -> dict[str, Any]:
    resp = await client.post(
        f"/v1/medications/{medication_id}/schedules",
        json={"id": str(uuid.uuid4()), "rule": rule or daily_rule()},
        headers=user.headers,
    )
    assert resp.status_code == 201, resp.text
    return dict(resp.json())


async def create_managed_profile(
    client: AsyncClient, owner: User, name: str = "Synthetic Ward", timezone: str = "UTC"
) -> str:
    profile_id = str(uuid.uuid4())
    resp = await client.post(
        "/v1/profiles",
        json={"id": profile_id, "display_name": name, "timezone": timezone},
        headers=owner.headers,
    )
    assert resp.status_code == 201, resp.text
    return profile_id


async def create_invite(
    client: AsyncClient,
    owner: User,
    profile_id: str | None = None,
    role: str = "viewer",
    **overrides: Any,
) -> dict[str, Any]:
    """POST /v1/profiles/{id}/invites (the owner's self profile by default)."""
    body = {"id": str(uuid.uuid4()), "role": role, "disclosure_version": 1, **overrides}
    resp = await client.post(
        f"/v1/profiles/{profile_id or owner.self_profile_id}/invites",
        json=body,
        headers=owner.headers,
    )
    assert resp.status_code == 201, resp.text
    return dict(resp.json())


def token_of(invite: dict[str, Any]) -> str:
    """The token of a created invite: the fragment of its URL."""
    return str(invite["url"]).split("#", 1)[1]


async def accept_invite(client: AsyncClient, user: User, token: str) -> Any:
    return await client.post("/v1/invites/accept", json={"token": token}, headers=user.headers)


async def link_accounts(
    client: AsyncClient,
    owner: User,
    relative: User,
    role: str = "viewer",
    profile_id: str | None = None,
) -> dict[str, Any]:
    """Invite and accept: returns the relative's grant."""
    invite = await create_invite(client, owner, profile_id, role)
    resp = await accept_invite(client, relative, token_of(invite))
    assert resp.status_code == 201, resp.text
    return dict(resp.json())
