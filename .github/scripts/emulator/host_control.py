"""Runner-side helper of the emulator job (test-only, never deployed).

Serves on 127.0.0.1, which the Android emulator reaches as 10.0.2.2:

  GET /phase -> {"phase": "<contents of the phase file>"}
  GET /code  -> {"count": <codes logged so far>, "code": "<latest>" | null}

The verification code comes from the backend's JSON log in dev mode
(LOG_EMAIL_CODES=true, rejected when ENVIRONMENT=prod); the log line carries
no e-mail address, so the test asks for "the first code after N".

The `relatives` phase also asks the host to play the owner and to deliver the invite
link (relatives_host.py; needs --api and adb):

  POST /relatives/setup     -> medication names per privacy level; the invite stays here
  POST /relatives/open-link -> `adb shell am start` with the invite link
  POST /relatives/revoke    -> the owner revokes the grant

Usage: host_control.py --log <backend.log> --phase-file <file> [--port 8090]
                       [--api http://127.0.0.1:8000] [--adb <path>] [--serial emulator-5554]
"""

import argparse
import json
import os
import shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import backend_log
from relatives_host import RelativesHost

APP_PACKAGE = "com.pillpal.pillpal"


def latest_code(log_path: Path) -> tuple[int, str | None]:
    found = backend_log.codes(log_path)
    return len(found), found[-1] if found else None


def make_handler(
    log_path: Path, phase_file: Path, relatives: RelativesHost
) -> type[BaseHTTPRequestHandler]:
    actions = {
        "/relatives/setup": relatives.setup,
        "/relatives/open-link": relatives.open_link,
        "/relatives/revoke": relatives.revoke,
    }

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 - http.server API
            path = self.path.split("?", 1)[0]
            if path == "/phase":
                body = {"phase": phase_file.read_text(encoding="utf-8").strip()}
            elif path == "/code":
                count, code = latest_code(log_path)
                body = {"count": count, "code": code}
            else:
                self.send_error(404)
                return
            self._send(200, body)

        def do_POST(self) -> None:  # noqa: N802 - http.server API
            action = actions.get(self.path.split("?", 1)[0])
            if action is None:
                self.send_error(404)
                return
            try:
                result = action()
            except Exception as error:  # noqa: BLE001 - any failure is a 500 for the test
                # Type only: messages may carry the invite token.
                print(f"host_control: {self.path} failed: {type(error).__name__}", flush=True)
                self._send(500, {"error": type(error).__name__})
                return
            self._send(200, result if isinstance(result, dict) else {})

        def _send(self, status: int, body: dict[str, object]) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002
            # Request lines only (no codes): the job log stays readable.
            print(f"host_control: {self.command} {self.path.split('?', 1)[0]}", flush=True)

    return Handler


def default_adb() -> str:
    """adb from PATH, else the runner's Android SDK (not on PATH outside the emulator step)."""
    found = shutil.which("adb")
    if found:
        return found
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or ""
    return str(Path(sdk) / "platform-tools" / "adb")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--phase-file", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--api", default="http://127.0.0.1:8000")
    parser.add_argument("--adb", default=default_adb())
    parser.add_argument("--serial", default="emulator-5554")
    args = parser.parse_args()
    relatives = RelativesHost(args.api, args.log, args.adb, args.serial, APP_PACKAGE)
    server = ThreadingHTTPServer(
        ("127.0.0.1", args.port), make_handler(args.log, args.phase_file, relatives)
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
