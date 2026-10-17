"""A real SMTP server in the test process (aiosmtpd): the one true external of the mail tests."""

from __future__ import annotations

import datetime as dt
import ipaddress
import socket
import ssl
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from email import message_from_bytes, policy
from email.message import EmailMessage
from pathlib import Path
from typing import Any

from aiosmtpd.controller import Controller
from aiosmtpd.smtp import AuthResult
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

LOOPBACK = "127.0.0.1"
USERNAME = "mailer"
PASSWORD = "mail-pass-0123"


@dataclass
class Delivered:
    envelope_from: str
    envelope_to: list[str]
    message: EmailMessage

    @property
    def text(self) -> str:
        body = self.message.get_content()
        assert isinstance(body, str)
        return body


@dataclass
class FakeSmtp:
    port: int
    ca_pem: str
    delivered: list[Delivered] = field(default_factory=list)
    logins: list[tuple[str, str]] = field(default_factory=list)

    def client_context(self) -> ssl.SSLContext:
        return ssl.create_default_context(cadata=self.ca_pem)


class _Handler:
    def __init__(self, server: FakeSmtp) -> None:
        self._server = server

    async def handle_DATA(self, server: Any, session: Any, envelope: Any) -> str:
        message = message_from_bytes(envelope.original_content, policy=policy.default)
        assert isinstance(message, EmailMessage)
        self._server.delivered.append(
            Delivered(envelope.mail_from, list(envelope.rcpt_tos), message)
        )
        return "250 OK"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind((LOOPBACK, 0))
        port: int = sock.getsockname()[1]
        return port


def _self_signed() -> tuple[bytes, bytes]:
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "pillpal-test-smtp")])
    now = dt.datetime.now(dt.UTC)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=5))
        .not_valid_after(now + dt.timedelta(hours=1))
        .add_extension(
            x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address(LOOPBACK))]),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    key_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    return cert.public_bytes(serialization.Encoding.PEM), key_pem


def _authenticate(server: FakeSmtp) -> Any:
    def check(_s: Any, _sess: Any, _env: Any, mechanism: str, data: Any) -> AuthResult:
        login, password = bytes(data.login).decode(), bytes(data.password).decode()
        server.logins.append((login, password))
        ok = (login, password) == (USERNAME, PASSWORD)
        return AuthResult(success=ok, handled=ok)

    return check


@contextmanager
def fake_smtp(*, security: str) -> Iterator[FakeSmtp]:
    """``security``: ``ssl`` (implicit TLS) or ``starttls``, both with a required login;
    ``plain``: no TLS and no login (a server that cannot be trusted with credentials)."""
    cert_pem, key_pem = _self_signed()
    with tempfile.TemporaryDirectory() as tmp:
        cert_file, key_file = Path(tmp, "cert.pem"), Path(tmp, "key.pem")
        cert_file.write_bytes(cert_pem)
        key_file.write_bytes(key_pem)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert_file, key_file)
        fake = FakeSmtp(port=free_port(), ca_pem=cert_pem.decode())
        common: dict[str, Any] = {
            "authenticator": _authenticate(fake),
            "auth_required": True,
        }
        if security == "plain":
            controller = Controller(_Handler(fake), hostname=LOOPBACK, port=fake.port)
        elif security == "ssl":
            # aiosmtpd only counts STARTTLS as "TLS" for this check; the socket is TLS already.
            common["auth_require_tls"] = False
            controller = Controller(
                _Handler(fake), hostname=LOOPBACK, port=fake.port, ssl_context=context, **common
            )
        else:
            controller = Controller(
                _Handler(fake),
                hostname=LOOPBACK,
                port=fake.port,
                tls_context=context,
                require_starttls=True,
                auth_require_tls=True,
                **common,
            )
        controller.start()
        try:
            yield fake
        finally:
            controller.stop()
