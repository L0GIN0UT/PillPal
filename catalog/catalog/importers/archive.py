"""Safe extraction of downloaded archives (ESKLP XML/ZIP, RxNorm RRF zips). A snapshot is
untrusted input: member names may climb out of the target (zip-slip), sizes may lie, a few
kilobytes may inflate to gigabytes. Every cap is checked before and while writing."""

from __future__ import annotations

import stat
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

COPY_CHUNK_BYTES = 64 * 1024
WINDOWS_DRIVE_LENGTH = 2


class ArchiveRejected(Exception):
    """The archive violates a guard; ``code`` is stable and carries no member names."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class ArchiveLimits:
    max_files: int = 10_000
    max_total_bytes: int = 4 * 1024**3
    max_file_bytes: int = 2 * 1024**3
    # Uncompressed / compressed; real data compresses far less than a bomb does.
    max_ratio: int = 200


def _safe_target(dest: Path, name: str) -> Path:
    normalized = name.replace("\\", "/")
    parts = PurePosixPath(normalized).parts
    drive = len(normalized) >= WINDOWS_DRIVE_LENGTH and normalized[1] == ":"
    if not parts or normalized.startswith("/") or drive or ".." in parts:
        raise ArchiveRejected("unsafe_archive_path")
    target = (dest / Path(*parts)).resolve()
    if not target.is_relative_to(dest.resolve()):
        raise ArchiveRejected("unsafe_archive_path")
    return target


def _check_member(info: zipfile.ZipInfo, limits: ArchiveLimits) -> None:
    mode = info.external_attr >> 16
    if stat.S_ISLNK(mode):
        raise ArchiveRejected("unsafe_archive_path")
    if info.file_size > limits.max_file_bytes:
        raise ArchiveRejected("archive_too_large")
    if info.compress_size and info.file_size / info.compress_size > limits.max_ratio:
        raise ArchiveRejected("archive_too_large")


def safe_extract_zip(archive: Path, dest: Path, limits: ArchiveLimits | None = None) -> None:
    """Extract ``archive`` into ``dest`` or raise ``ArchiveRejected`` having written nothing
    for rejected members. Directories are created as needed; links are refused."""
    limits = limits or ArchiveLimits()
    try:
        with zipfile.ZipFile(archive) as zf:
            members = [m for m in zf.infolist() if not m.is_dir()]
            if len(members) > limits.max_files:
                raise ArchiveRejected("archive_too_large")
            planned = [(m, _safe_target(dest, m.filename)) for m in members]
            for member, _ in planned:
                _check_member(member, limits)
            if sum(m.file_size for m in members) > limits.max_total_bytes:
                raise ArchiveRejected("archive_too_large")
            written = 0
            for member, target in planned:
                written += _copy_member(zf, member, target, limits.max_file_bytes)
                if written > limits.max_total_bytes:
                    raise ArchiveRejected("archive_too_large")
    except (zipfile.BadZipFile, NotImplementedError, OSError) as exc:
        raise ArchiveRejected("invalid_archive") from exc


def _copy_member(zf: zipfile.ZipFile, member: zipfile.ZipInfo, target: Path, cap: int) -> int:
    """Copy one member, counting the bytes actually produced (headers can lie)."""
    target.parent.mkdir(parents=True, exist_ok=True)
    copied = 0
    try:
        with zf.open(member) as source, target.open("wb") as out:
            while chunk := source.read(COPY_CHUNK_BYTES):
                copied += len(chunk)
                if copied > cap:
                    raise ArchiveRejected("archive_too_large")
                out.write(chunk)
    except ArchiveRejected:
        target.unlink(missing_ok=True)
        raise
    return copied
