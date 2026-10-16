"""Runner-side helper of the emulator job (test-only, never deployed).

Serves on 127.0.0.1, which the Android emulator reaches as 10.0.2.2:

  GET /phase -> {"phase": "<contents of the phase file>"}
  GET /code  -> {"count": <codes logged so far>, "code": "<latest>" | null}

The verification code comes from the backend's JSON log in dev mode
(LOG_EMAIL_CODES=true, rejected when ENVIRONMENT=prod); the log line carries
no e-mail address, so the test asks for "the first code after N".

Usage: host_control.py --log <backend.log> --phase-file <file> [--port 8090]
"""

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def latest_code(log_path: Path) -> tuple[int, str | None]:
    count, code = 0, None
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        return 0, None
    for line in lines:
        if not line.startswith("{"):
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            entry.get("event") == "email_code_sent"
            and entry.get("purpose") == "verify_email"
            and isinstance(entry.get("dev_code"), str)
        ):
            count += 1
            code = entry["dev_code"]
    return count, code


def make_handler(log_path: Path, phase_file: Path) -> type[BaseHTTPRequestHandler]:
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
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002
            # Request lines only (no codes): the job log stays readable.
            print(f"host_control: {self.command} {self.path.split('?', 1)[0]}", flush=True)

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--phase-file", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8090)
    args = parser.parse_args()
    server = ThreadingHTTPServer(
        ("127.0.0.1", args.port), make_handler(args.log, args.phase_file)
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
