"""Encryption at rest of exports (ADR 0016 section 9): keyring, blob layout, AAD binding."""

from __future__ import annotations

import uuid

import pytest

from app.services.data_encryption import (
    EXPORT_PURPOSE,
    DataKeyring,
    DecryptionError,
)

KEY_1 = bytes(range(32))
KEY_2 = bytes(range(32, 64))
ROW = uuid.UUID("11111111-1111-4111-8111-111111111111")
OTHER_ROW = uuid.UUID("22222222-2222-4222-8222-222222222222")


def test_round_trip_and_blob_layout() -> None:
    ring = DataKeyring({1: KEY_1}, current_id=1)
    blob = ring.encrypt(EXPORT_PURPOSE, ROW, b"zip bytes")
    assert blob[0] == 1  # key id
    assert len(blob) == 1 + 12 + len(b"zip bytes") + 16  # nonce, ciphertext, GCM tag
    assert b"zip bytes" not in blob
    assert ring.decrypt(EXPORT_PURPOSE, ROW, blob) == b"zip bytes"


def test_a_random_nonce_per_encryption() -> None:
    ring = DataKeyring({1: KEY_1}, current_id=1)
    assert ring.encrypt(EXPORT_PURPOSE, ROW, b"x") != ring.encrypt(EXPORT_PURPOSE, ROW, b"x")


def test_a_blob_moved_to_another_row_does_not_decrypt() -> None:
    ring = DataKeyring({1: KEY_1}, current_id=1)
    blob = ring.encrypt(EXPORT_PURPOSE, ROW, b"secret")
    with pytest.raises(DecryptionError):
        ring.decrypt(EXPORT_PURPOSE, OTHER_ROW, blob)


def test_a_blob_moved_to_another_purpose_does_not_decrypt() -> None:
    ring = DataKeyring({1: KEY_1}, current_id=1)
    blob = ring.encrypt(EXPORT_PURPOSE, ROW, b"secret")
    with pytest.raises(DecryptionError):
        ring.decrypt("pillpal-oauth-refresh/v1", ROW, blob)


def test_a_flipped_bit_or_a_short_blob_fails() -> None:
    ring = DataKeyring({1: KEY_1}, current_id=1)
    blob = bytearray(ring.encrypt(EXPORT_PURPOSE, ROW, b"secret"))
    blob[-1] ^= 1
    with pytest.raises(DecryptionError):
        ring.decrypt(EXPORT_PURPOSE, ROW, bytes(blob))
    with pytest.raises(DecryptionError):
        ring.decrypt(EXPORT_PURPOSE, ROW, b"\x01short")


def test_rotation_new_writes_use_the_current_key_and_old_blobs_still_decrypt() -> None:
    old = DataKeyring({1: KEY_1}, current_id=1)
    blob = old.encrypt(EXPORT_PURPOSE, ROW, b"secret")
    rotated = DataKeyring({1: KEY_1, 2: KEY_2}, current_id=2)
    assert rotated.encrypt(EXPORT_PURPOSE, ROW, b"x")[0] == 2
    assert rotated.decrypt(EXPORT_PURPOSE, ROW, blob) == b"secret"
    assert rotated.key_id_of(blob) == 1
    # Re-encryption with the current key.
    blob2 = rotated.reencrypt(EXPORT_PURPOSE, ROW, blob)
    assert blob2[0] == 2
    assert rotated.decrypt(EXPORT_PURPOSE, ROW, blob2) == b"secret"


def test_a_key_removed_from_the_ring_cannot_decrypt() -> None:
    blob = DataKeyring({1: KEY_1}, current_id=1).encrypt(EXPORT_PURPOSE, ROW, b"secret")
    with pytest.raises(DecryptionError):
        DataKeyring({2: KEY_2}, current_id=2).decrypt(EXPORT_PURPOSE, ROW, blob)


def test_the_keys_are_derived_per_row() -> None:
    # The same plaintext under two rows never shares a derived key: a ciphertext of one row,
    # re-labelled with the other row's id, fails even without the AAD check being the only guard.
    ring = DataKeyring({1: KEY_1}, current_id=1)
    assert ring.derived_key(1, EXPORT_PURPOSE, ROW) != ring.derived_key(
        1, EXPORT_PURPOSE, OTHER_ROW
    )
    assert ring.derived_key(1, EXPORT_PURPOSE, ROW) != ring.derived_key(1, "other/v1", ROW)
    assert ring.derived_key(1, EXPORT_PURPOSE, ROW) != KEY_1


def test_the_current_key_must_be_in_the_ring_and_keys_must_be_32_bytes() -> None:
    with pytest.raises(ValueError, match="current"):
        DataKeyring({1: KEY_1}, current_id=2)
    with pytest.raises(ValueError, match="32 bytes"):
        DataKeyring({1: b"short"}, current_id=1)
    with pytest.raises(ValueError, match=r"1..255"):
        DataKeyring({0: KEY_1}, current_id=0)
