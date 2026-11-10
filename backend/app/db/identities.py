"""Sign-in identities of an account (ADR 0017 section 2; migration 0022).

``subject`` is the provider's stable id of the person: personal data of the account holder, exported
with the account (it is their own id, GDPR art. 15) and erased with it. The API never returns it
and it is never logged. ``provider_refresh_token_enc`` is reserved for Apple (milestone 5.8) and is
never exported.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, ForeignKey, Index, LargeBinary, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, sql_in
from app.db.models import NOW
from app.domain.auth_providers import PROVIDERS

MAX_SUBJECT_LENGTH = 255


class AuthIdentity(Base):
    __tablename__ = "auth_identities"
    __table_args__ = (
        UniqueConstraint("provider", "subject"),
        CheckConstraint(sql_in("provider", PROVIDERS), name="provider"),
        CheckConstraint(f"char_length(subject) BETWEEN 1 AND {MAX_SUBJECT_LENGTH}", name="subject"),
        Index("ix_auth_identities_user_id", "user_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    provider: Mapped[str] = mapped_column(Text)
    subject: Mapped[str] = mapped_column(Text)
    # The address the provider asserted when the identity was linked; informational only.
    email_at_link: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(server_default=NOW)
    last_used_at: Mapped[datetime | None]
    provider_refresh_token_enc: Mapped[bytes | None] = mapped_column(LargeBinary)
