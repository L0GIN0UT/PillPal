"""Push abstraction: the payload, the message and the result of one send (ADR 0008).

``PushPayload`` is the only way to build what goes over the wire: ids and enums, no
text. Names, doses, times and occurrence keys never leave the server in a push (the
device renders from its own, already projected, data). The same field set is enforced
in PostgreSQL (``push_outbox.payload`` CHECK).
"""

from __future__ import annotations

import enum
import re
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from typing import Any, Literal, Protocol, Self, get_args

from pydantic import BaseModel, ConfigDict, model_validator

PushKind = Literal["missed", "resolved", "link_accepted", "link_restored"]
PUSH_KINDS: tuple[str, ...] = get_args(PushKind)
PushProvider = Literal["fcm", "apns", "rustore"]
PUSH_PROVIDERS: tuple[str, ...] = get_args(PushProvider)
ApnsEnvironment = Literal["sandbox", "production"]

# Token formats, also CHECK constraints on ``push_tokens`` (the APNs token is placed in a URL
# path, so it must be lower-case hex; PostgreSQL limits regex repetition counts to 255, so the
# 4096-character limit of FCM and RuStore tokens is a separate length check).
APNS_TOKEN_PATTERN = "^[0-9a-f]{64,200}$"  # noqa: S105 - a pattern, not a secret
OPAQUE_TOKEN_PATTERN = "^[A-Za-z0-9_:-]+$"  # noqa: S105
MAX_TOKEN_LENGTH = 4096

# Keys of the wire payload; the database CHECK on ``push_outbox.payload`` lists the same.
PAYLOAD_KEYS = ("v", "t", "a", "p", "m", "g", "s")


class PushPayload(BaseModel):
    """``v`` version, ``t`` kind, ``a`` alert id, ``p`` subject profile id, ``m`` medication id,
    ``g`` grant id, ``s`` = ``u`` for an unconfirmed alert (never names, doses or times)."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    v: Literal[1] = 1
    t: PushKind
    a: uuid.UUID | None = None
    p: uuid.UUID | None = None
    m: uuid.UUID | None = None
    g: uuid.UUID | None = None
    s: Literal["u"] | None = None

    @model_validator(mode="after")
    def _ids_match_the_kind(self) -> Self:
        required: tuple[object, ...]
        forbidden: tuple[object, ...]
        if self.t in ("missed", "resolved"):
            required, forbidden = (self.a, self.p), (self.g,)
        else:
            required, forbidden = (self.g, self.p), (self.a, self.m, self.s)
        if any(value is None for value in required) or any(v is not None for v in forbidden):
            raise ValueError("payload fields do not match its kind")
        if self.s is not None and self.t != "missed":
            raise ValueError("only a missed alert can be unconfirmed")
        return self

    def to_wire(self) -> dict[str, Any]:
        """The JSON object stored in the outbox and sent to providers (strings only for ids)."""
        return self.model_dump(mode="json", exclude_none=True)


@dataclass(frozen=True)
class PushMessage:
    """One delivery attempt: where to send, what, and until when it is still worth sending."""

    provider: PushProvider
    token: str
    payload: PushPayload
    # Outbox row id, for logs and correlation (never the token).
    delivery_id: str
    apns_environment: ApnsEnvironment | None = None
    ttl_seconds: int = 7200

    def __repr__(self) -> str:  # a stray log of a message must not carry the token
        return f"PushMessage(provider={self.provider}, delivery_id={self.delivery_id})"


class Outcome(enum.Enum):
    OK = "ok"
    INVALID_TOKEN = "invalid_token"  # noqa: S105 - the provider says the token is dead
    RETRY = "retry"
    FATAL = "fatal"  # configuration or payload problem: retrying cannot help


_CODE_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
UNKNOWN_CODE = "unknown"


def safe_code(value: object) -> str:
    """A provider error code as a short token, or ``unknown``: provider text is never kept."""
    return value if isinstance(value, str) and _CODE_RE.match(value) else UNKNOWN_CODE


@dataclass(frozen=True)
class SendResult:
    outcome: Outcome
    # Provider error code (``UNREGISTERED``, ``http_503``, ``transport_error``): never a token,
    # a URL or provider message text.
    code: str | None = None
    retry_after_seconds: float | None = None
    # APNs 410: the instant the token stopped being valid; a token registered later is kept.
    invalid_since: datetime | None = None

    @classmethod
    def ok(cls) -> Self:
        return cls(Outcome.OK)

    @classmethod
    def retry(cls, code: str, retry_after_seconds: float | None = None) -> Self:
        return cls(Outcome.RETRY, safe_code(code), retry_after_seconds)

    @classmethod
    def fatal(cls, code: str) -> Self:
        return cls(Outcome.FATAL, safe_code(code))

    @classmethod
    def invalid_token(cls, code: str, invalid_since: datetime | None = None) -> Self:
        return cls(Outcome.INVALID_TOKEN, safe_code(code), None, invalid_since)


class PushSender(Protocol):
    provider: PushProvider

    async def send(self, message: PushMessage) -> SendResult: ...

    async def aclose(self) -> None: ...


def parse_retry_after(value: str | None, now: datetime) -> float | None:
    """``Retry-After`` as seconds (delta or HTTP date), or ``None`` when absent or unusable."""
    if not value:
        return None
    value = value.strip()
    if value.isdigit():
        return float(value)
    try:
        moment = parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=UTC)
    return max(0.0, (moment - now).total_seconds())
