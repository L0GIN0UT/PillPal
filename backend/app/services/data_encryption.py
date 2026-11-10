"""Encryption at rest for blobs that hold personal data (ADR 0016 section 9).

AES-256-GCM with a key derived per row: ``HKDF-SHA256(keyring key, salt = row id, info =
purpose)``. The blob is ``key_id (1 byte) || nonce (12 bytes) || ciphertext || tag`` and the
associated data is ``key_id || purpose || row id``, so a blob cannot be moved to another row or
purpose. The keyring (``DATA_ENCRYPTION_KEYS``) lives in the regional environment only; a key
leaves it when no row references it any more (rotation: ``reencrypt``). Nothing here logs.
"""

from __future__ import annotations

import secrets
import uuid
from collections.abc import Mapping

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from app.config import Settings
from app.settings_export import KEY_BYTES, MAX_KEY_ID, MIN_KEY_ID

EXPORT_PURPOSE = "pillpal-export/v1"
NONCE_BYTES = 12
TAG_BYTES = 16
_HEADER_BYTES = 1 + NONCE_BYTES


class DecryptionError(Exception):
    """The blob is malformed, names an unknown key or fails authentication (message: none)."""


class UnknownKeyError(DecryptionError):
    """The blob names a key this keyring does not hold: a configuration problem (a retired key
    still in use), not damage; the blob may open again once the key is back."""


class DataKeyring:
    def __init__(self, keys: Mapping[int, bytes], current_id: int) -> None:
        for key_id, key in keys.items():
            if not MIN_KEY_ID <= key_id <= MAX_KEY_ID:
                raise ValueError(f"key ids are {MIN_KEY_ID}..{MAX_KEY_ID}")
            if len(key) != KEY_BYTES:
                raise ValueError(f"every key is {KEY_BYTES} bytes")
        if current_id not in keys:
            raise ValueError("the current key id is not in the keyring")
        self._keys = dict(keys)
        self._current_id = current_id

    @classmethod
    def from_settings(cls, settings: Settings) -> DataKeyring | None:
        """The configured keyring, or ``None`` when none is configured (validated at startup)."""
        if not settings.data_encryption_keys or settings.data_encryption_key_id is None:
            return None
        return cls(settings.decoded_data_encryption_keys(), settings.data_encryption_key_id)

    @property
    def current_id(self) -> int:
        return self._current_id

    def derived_key(self, key_id: int, purpose: str, row_id: uuid.UUID) -> bytes:
        return HKDF(
            algorithm=hashes.SHA256(),
            length=KEY_BYTES,
            salt=row_id.bytes,
            info=purpose.encode(),
        ).derive(self._keys[key_id])

    @staticmethod
    def _aad(key_id: int, purpose: str, row_id: uuid.UUID) -> bytes:
        return bytes([key_id]) + purpose.encode() + row_id.bytes

    def encrypt(self, purpose: str, row_id: uuid.UUID, plaintext: bytes) -> bytes:
        key_id = self._current_id
        nonce = secrets.token_bytes(NONCE_BYTES)
        sealed = AESGCM(self.derived_key(key_id, purpose, row_id)).encrypt(
            nonce, plaintext, self._aad(key_id, purpose, row_id)
        )
        return bytes([key_id]) + nonce + sealed

    def key_id_of(self, blob: bytes) -> int:
        if len(blob) < _HEADER_BYTES + TAG_BYTES:
            raise DecryptionError
        return blob[0]

    def can_decrypt(self, blob: bytes) -> bool:
        """Whether the blob names a key this ring holds (checked before an export is claimed)."""
        try:
            return self.key_id_of(blob) in self._keys
        except DecryptionError:
            return False

    def decrypt(self, purpose: str, row_id: uuid.UUID, blob: bytes) -> bytes:
        key_id = self.key_id_of(blob)
        if key_id not in self._keys:
            raise UnknownKeyError
        nonce, sealed = blob[1:_HEADER_BYTES], blob[_HEADER_BYTES:]
        try:
            return AESGCM(self.derived_key(key_id, purpose, row_id)).decrypt(
                nonce, sealed, self._aad(key_id, purpose, row_id)
            )
        except InvalidTag:
            raise DecryptionError from None

    def reencrypt(self, purpose: str, row_id: uuid.UUID, blob: bytes) -> bytes:
        """The same plaintext under the current key (key rotation)."""
        return self.encrypt(purpose, row_id, self.decrypt(purpose, row_id, blob))
