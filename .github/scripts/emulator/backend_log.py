"""Reads the backend's JSON log in dev mode (LOG_EMAIL_CODES=true, rejected when
ENVIRONMENT=prod). The line carries no e-mail address: callers ask for "the first
code after N". Test-only, never deployed."""

import json
from pathlib import Path


def codes(log_path: Path, purpose: str = "verify_email") -> list[str]:
    """One-time codes of [purpose] logged so far, oldest first."""
    found: list[str] = []
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        return found
    for line in lines:
        if not line.startswith("{"):
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            entry.get("event") == "email_code_sent"
            and entry.get("purpose") == purpose
            and isinstance(entry.get("dev_code"), str)
        ):
            found.append(entry["dev_code"])
    return found
