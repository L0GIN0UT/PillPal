"""Write the admin audit (ADR 0018 section 5). Account ids only, never an e-mail."""

from __future__ import annotations

import os
import socket
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy.ext.asyncio import AsyncSession

from app.db.entitlements import MAX_ACTOR_LENGTH, MAX_OPERATOR_FIELD_LENGTH, AdminAudit

UNKNOWN = "unknown"


@dataclass(frozen=True)
class Operator:
    """Who acted. ``actor`` is self-declared; the OS user and the host are read, not declared."""

    actor: str
    os_user: str | None = None
    host: str | None = None

    def __post_init__(self) -> None:
        if (
            not 1 <= len(self.actor) <= MAX_ACTOR_LENGTH
            or "@" in self.actor
            or not self.actor.isprintable()
        ):
            raise ValueError("actor must be 1..64 printable characters without '@'")


def _plain(value: str) -> str:
    """An operator field must not look like an e-mail (the database refuses '@' as well)."""
    return value.replace("@", "_")[:MAX_OPERATOR_FIELD_LENGTH]


def os_user_name() -> str:
    """The effective user of the process from the passwd database, never from the environment
    (``USER``/``LOGNAME`` are set by the caller). Inside a container this names the container
    user; the real operator is attributed from the host's logs (backend/README.md)."""
    if sys.platform == "win32":  # development machines only
        return UNKNOWN
    import pwd

    uid = os.geteuid()
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:  # a uid without a passwd entry
        return f"uid:{uid}"


def current_operator(actor: str) -> Operator:
    return Operator(actor, _plain(os_user_name()), _plain(socket.gethostname()))


def record_audit(
    session: AsyncSession,
    operator: Operator,
    *,
    action: str,
    at: datetime,
    object_id: uuid.UUID,
    kind: str,
    target_user_id: uuid.UUID | None = None,
) -> None:
    """Add the row to the session; it is committed with the change it describes.

    ``object_id`` is an entitlement or promo code id, never a user id; ``target_user_id`` is the
    account acted on (none for a promo code, which belongs to no account).
    """
    session.add(
        AdminAudit(
            id=uuid.uuid4(),
            at=at,
            actor=operator.actor,
            action=action,
            target_user_id=target_user_id,
            object_id=object_id,
            kind=kind,
            os_user=operator.os_user,
            host=operator.host,
        )
    )
