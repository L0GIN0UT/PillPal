"""Archive extraction guards: zip-slip, absolute paths, links, size and count bombs. Pure unit
tests on synthetic archives built in memory."""

from __future__ import annotations

import stat
import zipfile
from pathlib import Path

import pytest

from catalog.importers.archive import ArchiveLimits, ArchiveRejected, safe_extract_zip

LIMITS = ArchiveLimits(max_files=3, max_total_bytes=1_000, max_file_bytes=600, max_ratio=50)


def _zip(path: Path, members: dict[str, bytes]) -> Path:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, payload in members.items():
            archive.writestr(name, payload)
    return path


def test_a_normal_archive_is_extracted(tmp_path: Path) -> None:
    archive = _zip(tmp_path / "a.zip", {"data.json": b"{}", "sub/more.txt": b"x"})
    dest = tmp_path / "out"

    safe_extract_zip(archive, dest, LIMITS)

    assert (dest / "data.json").read_bytes() == b"{}"
    assert (dest / "sub" / "more.txt").read_bytes() == b"x"


@pytest.mark.parametrize(
    "name", ["../evil.txt", "a/../../evil.txt", "/abs/evil.txt", "C:/evil.txt", "..\\evil.txt"]
)
def test_zip_slip_and_absolute_names_are_rejected(tmp_path: Path, name: str) -> None:
    archive = _zip(tmp_path / "a.zip", {name: b"x"})
    dest = tmp_path / "out"

    with pytest.raises(ArchiveRejected) as caught:
        safe_extract_zip(archive, dest, LIMITS)

    assert caught.value.code == "unsafe_archive_path"
    assert not (tmp_path / "evil.txt").exists()
    assert not dest.exists() or not any(dest.rglob("*"))


def test_symlink_members_are_rejected(tmp_path: Path) -> None:
    path = tmp_path / "a.zip"
    with zipfile.ZipFile(path, "w") as archive:
        info = zipfile.ZipInfo("link")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(info, "/etc/passwd")

    with pytest.raises(ArchiveRejected) as caught:
        safe_extract_zip(path, tmp_path / "out", LIMITS)

    assert caught.value.code == "unsafe_archive_path"


def test_too_many_members_are_rejected(tmp_path: Path) -> None:
    archive = _zip(tmp_path / "a.zip", {f"{i}.txt": b"x" for i in range(4)})

    with pytest.raises(ArchiveRejected) as caught:
        safe_extract_zip(archive, tmp_path / "out", LIMITS)

    assert caught.value.code == "archive_too_large"


def test_a_declared_size_bomb_is_rejected_before_writing(tmp_path: Path) -> None:
    archive = _zip(tmp_path / "a.zip", {"big.bin": b"\0" * 5_000})
    dest = tmp_path / "out"

    with pytest.raises(ArchiveRejected) as caught:
        safe_extract_zip(archive, dest, LIMITS)

    assert caught.value.code == "archive_too_large"
    assert not (dest / "big.bin").exists()


def test_the_total_size_is_capped(tmp_path: Path) -> None:
    import os

    archive = _zip(
        tmp_path / "a.zip", {"a": os.urandom(550), "b": os.urandom(550)}
    )  # each under the file cap, together over the total cap

    with pytest.raises(ArchiveRejected) as caught:
        safe_extract_zip(archive, tmp_path / "out", LIMITS)

    assert caught.value.code == "archive_too_large"


def test_a_suspicious_compression_ratio_is_rejected(tmp_path: Path) -> None:
    limits = ArchiveLimits(max_files=3, max_total_bytes=10_000, max_file_bytes=10_000, max_ratio=20)
    archive = _zip(tmp_path / "a.zip", {"zeros.bin": b"\0" * 9_000})

    with pytest.raises(ArchiveRejected) as caught:
        safe_extract_zip(archive, tmp_path / "out", limits)

    assert caught.value.code == "archive_too_large"


def test_a_lying_header_cannot_exceed_the_cap_while_streaming(tmp_path: Path) -> None:
    # The central directory claims 10 bytes, the data is bigger: the stream is capped as well.
    path = _zip(tmp_path / "a.zip", {"x.bin": b"A" * 900})
    data = bytearray(path.read_bytes())
    # Patch every uncompressed-size field (local header at 22, central directory) to 10.
    for marker, offset in ((b"PK\x03\x04", 22), (b"PK\x01\x02", 24)):
        at = data.find(marker)
        data[at + offset : at + offset + 4] = (10).to_bytes(4, "little")
    path.write_bytes(bytes(data))
    limits = ArchiveLimits(max_files=3, max_total_bytes=100, max_file_bytes=100, max_ratio=1000)

    with pytest.raises(ArchiveRejected):
        safe_extract_zip(path, tmp_path / "out", limits)
    assert (
        not (tmp_path / "out" / "x.bin").exists()
        or (tmp_path / "out" / "x.bin").stat().st_size <= 100
    )


def test_not_a_zip_is_a_stable_error(tmp_path: Path) -> None:
    path = tmp_path / "a.zip"
    path.write_bytes(b"not a zip")

    with pytest.raises(ArchiveRejected) as caught:
        safe_extract_zip(path, tmp_path / "out", LIMITS)

    assert caught.value.code == "invalid_archive"
