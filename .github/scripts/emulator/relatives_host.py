"""Host side of the emulator `relatives` phase (test-only, never deployed).

Plays the owner of a profile through the backend API (the app under test is the
relative): an owner with a `shared`, an `anonymous` and a `hidden` medication and a
viewer invite; delivery of the invite link to the app like a tap on a link would
(`adb shell am start`, explicit package, so no domain verification is needed); and
revocation of the grant. Synthetic data only; names are returned to the app, which
checks what the privacy levels let through.
"""

import json
import shlex
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

import backend_log

LINK_HOST = "links-ru.pillpal.invalid"  # placeholder host of the RU build (build.gradle.kts)
PASSWORD = "emulator-owner-password-1"
START_DATE = "2026-01-01"  # before any run date: the doses show on today's view
NAMES = {
    "shared": "Relshared",
    "anonymous": "Relanonymous",
    "hidden": "Relhidden",
}
CODE_WAIT_SECONDS = 30
HTTP_TIMEOUT_SECONDS = 30
ADB_TIMEOUT_SECONDS = 60


class HostError(Exception):
    pass


class RelativesHost:
    def __init__(
        self, api: str, log: Path, adb: str, serial: str, package: str
    ) -> None:
        self._api = api.rstrip("/")
        self._log = log
        self._adb = adb
        self._serial = serial
        self._package = package
        self._token: str | None = None  # invite token: a bearer capability, never printed
        self._access: str | None = None

    # --- API ---------------------------------------------------------------------------------

    def _call(
        self, method: str, path: str, body: Any = None, *, authorized: bool = True
    ) -> Any:
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self._api + path, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        if authorized:
            request.add_header("Authorization", f"Bearer {self._access}")
        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            # Status and path only: bodies may hold tokens.
            raise HostError(f"{method} {path} answered {error.code}") from None
        return json.loads(raw) if raw else None

    def _sign_up_owner(self) -> None:
        email = f"emulator-owner-{time.time_ns()}@example.com"
        known = len(backend_log.codes(self._log))
        self._call(
            "POST",
            "/v1/auth/register",
            {
                "email": email,
                "password": PASSWORD,
                "region": "ru",
                "locale": "en",
                "timezone": "Europe/Samara",
            },
            authorized=False,
        )
        deadline = time.monotonic() + CODE_WAIT_SECONDS
        while len(backend_log.codes(self._log)) <= known:
            if time.monotonic() > deadline:
                raise HostError("no verification code of the owner in the backend log")
            time.sleep(0.25)
        tokens = self._call(
            "POST",
            "/v1/auth/verify-email",
            {"email": email, "code": backend_log.codes(self._log)[-1]},
            authorized=False,
        )
        self._access = tokens["access_token"]

    def _add_medication(self, profile_id: str, privacy: str, time_of_day: str) -> None:
        medication_id = str(uuid.uuid4())
        self._call(
            "POST",
            f"/v1/profiles/{profile_id}/medications",
            {"id": medication_id, "name": NAMES[privacy], "privacy": privacy},
        )
        rule = {
            "v": 1,
            "kind": "daily",
            "start_date": START_DATE,
            "end_date": None,
            "times": [{"time": time_of_day, "dose": {"amount": "1", "unit": "tablet"}}],
        }
        self._call(
            "POST",
            f"/v1/medications/{medication_id}/schedules",
            {"id": str(uuid.uuid4()), "rule": rule},
        )

    def setup(self) -> dict[str, str]:
        """An owner with one medication per privacy level and a viewer invite."""
        self._sign_up_owner()
        profiles = self._call("GET", "/v1/profiles")["items"]
        profile_id = next(p["id"] for p in profiles if p["kind"] == "self")
        for privacy, time_of_day in (("shared", "08:00"), ("anonymous", "09:00"), ("hidden", "10:00")):
            self._add_medication(profile_id, privacy, time_of_day)
        invite = self._call(
            "POST",
            f"/v1/profiles/{profile_id}/invites",
            {"id": str(uuid.uuid4()), "role": "viewer", "disclosure_version": 1},
        )
        self._token = invite["url"].split("#", 1)[1]
        return dict(NAMES)

    def revoke(self) -> None:
        """The owner revokes every grant they gave."""
        grants = self._call("GET", "/v1/grants")["outgoing"]
        if not grants:
            raise HostError("the owner has no grant to revoke")
        for grant in grants:
            self._call("DELETE", f"/v1/grants/{grant['id']}")

    # --- device ------------------------------------------------------------------------------

    def open_link(self) -> None:
        """Delivers the invite link to the running app as a view intent."""
        if self._token is None:
            raise HostError("no invite: setup first")
        url = f"https://{LINK_HOST}/i#{self._token}"
        remote = shlex.join(
            ["am", "start", "-a", "android.intent.action.VIEW", "-d", url, self._package]
        )
        result = subprocess.run(
            [self._adb, "-s", self._serial, "shell", remote],
            capture_output=True,
            text=True,
            timeout=ADB_TIMEOUT_SECONDS,
            check=False,
        )
        # The output holds the intent, hence the token: report the verdict only.
        if result.returncode != 0 or "Error" in result.stdout + result.stderr:
            raise HostError(f"am start failed (exit {result.returncode})")
