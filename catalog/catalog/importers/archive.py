"""Safe extraction of downloaded archives (ESKLP XML/ZIP, RxNorm RRF zips). A snapshot is
untrusted input: member names may climb out of the target (zip-slip), sizes may lie, a few
kilobytes may inflate to gigabytes. Every cap is checked before and while writing, and the
archive is extracted into a private temporary directory that is removed on any failure, so a
rejected archive leaves nothing behind."""

from __future__ import annotations

import lzma
import shutil
import stat
import tempfile
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

COPY_CHUNK_BYTES = 64 * 1024
WINDOWS_DRIVE_LENGTH = 2
DEFAULT_MAX_FILES = 10_000
DEFAULT_MAX_TOTAL_BYTES = 4 * 1024**3
DEFAULT_MAX_FILE_BYTES = 2 * 1024**3
# Uncompressed / compressed; real data compresses far less than a bomb does.
DEFAULT_MAX_RATIO = 200
# Everything the zip readers can raise for a corrupt, encrypted or unsupported archive.
_BAD_ARCHIVE = (
    zipfile.BadZipFile,
    NotImplementedError,
    OSError,
    RuntimeError,
    EOFError,
    zlib.error,
    lzma.LZMAError,
    ValueError,
)


class ArchiveRejected(Exception):
    """The archive violates a guard; ``code`` is stable and carries no member names."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class ArchiveLimits:
    max_files: int = DEFAULT_MAX_FILES
    max_total_bytes: int = DEFAULT_MAX_TOTAL_BYTES
    max_file_bytes: int = DEFAULT_MAX_FILE_BYTES
    max_ratio: int = DEFAULT_MAX_RATIO


def _safe_target(root: Path, name: str) -> Path:
    normalized = name.replace("\\", "/")
    parts = PurePosixPath(normalized).parts
    drive = len(normalized) >= WINDOWS_DRIVE_LENGTH and normalized[1] == ":"
    if not parts or normalized.startswith("/") or drive or ".." in parts:
        raise ArchiveRejected("unsafe_archive_path")
    target = (root / Path(*parts)).resolve()
    if not target.is_relative_to(root.resolve()):
        raise ArchiveRejected("unsafe_archive_path")
    return target


def _check_member(info: zipfile.ZipInfo, limits: ArchiveLimits) -> None:
    if stat.S_ISLNK(info.external_attr >> 16):
        raise ArchiveRejected("unsafe_archive_path")
    if info.file_size > limits.max_file_bytes:
        raise ArchiveRejected("archive_too_large")
    # compress_size == 0 means an empty member (ratio undefined); a header that lies about it
    # is still stopped by the byte count of the stream in _copy_member.
    if info.compress_size and info.file_size / info.compress_size > limits.max_ratio:
        raise ArchiveRejected("archive_too_large")


def _extract_into(archive: Path, root: Path, limits: ArchiveLimits) -> None:
    with zipfile.ZipFile(archive) as zf:
        members = [m for m in zf.infolist() if not m.is_dir()]
        if len(members) > limits.max_files:
            raise ArchiveRejected("archive_too_large")
        names = [m.filename.replace("\\", "/").casefold() for m in members]
        if len(set(names)) != len(names):
            raise ArchiveRejected("unsafe_archive_path")  # a duplicate would shadow a member
        planned = [(m, _safe_target(root, m.filename)) for m in members]
        for member, _ in planned:
            _check_member(member, limits)
        if sum(m.file_size for m in members) > limits.max_total_bytes:
            raise ArchiveRejected("archive_too_large")
        written = 0
        for member, target in planned:
            written += _copy_member(zf, member, target, limits.max_file_bytes)
            if written > limits.max_total_bytes:
                raise ArchiveRejected("archive_too_large")


def safe_extract_zip(archive: Path, dest: Path, limits: ArchiveLimits | None = None) -> None:
    """Extract ``archive`` into ``dest`` or raise ``ArchiveRejected`` leaving ``dest`` untouched."""
    limits = limits or ArchiveLimits()
    dest.parent.mkdir(parents=True, exist_ok=True)
    # mkdtemp creates the directory with mode 0700, next to dest so the final move is a rename.
    staging = Path(tempfile.mkdtemp(prefix=".extract-", dir=dest.parent))
    try:
        _extract_into(archive, staging, limits)
        dest.mkdir(parents=True, exist_ok=True)
        for child in staging.iterdir():
            shutil.move(str(child), str(dest / child.name))
    except _BAD_ARCHIVE:
        raise ArchiveRejected("invalid_archive") from None
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def _copy_member(zf: zipfile.ZipFile, member: zipfile.ZipInfo, target: Path, cap: int) -> int:
    """Copy one member, counting the bytes actually produced (headers can lie)."""
    target.parent.mkdir(parents=True, exist_ok=True)
    copied = 0
    with zf.open(member) as source, target.open("wb") as out:
        while chunk := source.read(COPY_CHUNK_BYTES):
            copied += len(chunk)
            if copied > cap:
                raise ArchiveRejected("archive_too_large")
            out.write(chunk)
    return copied
