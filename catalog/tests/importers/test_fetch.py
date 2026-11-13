"""Downloads of snapshots: https only, allow-listed hosts, size caps, sha256. No network: every
request goes through ``httpx.MockTransport``."""

from __future__ import annotations

import hashlib
import ssl
from collections.abc import Callable, Iterator
from pathlib import Path

import httpx
import pytest

from catalog.importers.base import ImporterError
from catalog.importers.fetch import download_file, get_json, new_client, trust_context
from tests.helpers import CATALOG_DIR

HOST = "files.example.invalid"
URL = f"https://{HOST}/data.zip"
HOSTS = frozenset({HOST})
PAYLOAD = b"synthetic snapshot bytes" * 10
CAP = 10_000

Handler = Callable[[httpx.Request], httpx.Response]


def _client(handler: Handler) -> httpx.Client:
    return new_client(httpx.MockTransport(handler))


def _download(handler: Handler, target: Path, **kwargs: object) -> object:
    options: dict[str, object] = {"max_bytes": CAP, "allowed_hosts": HOSTS}
    options.update(kwargs)
    with _client(handler) as client:
        return download_file(client, URL, target, **options)  # type: ignore[arg-type]


def _ok(_: httpx.Request) -> httpx.Response:
    return httpx.Response(200, content=PAYLOAD)


def test_download_writes_the_file_and_reports_size_and_sha256(tmp_path: Path) -> None:
    target = tmp_path / "data.zip"

    result = _download(_ok, target)

    assert target.read_bytes() == PAYLOAD
    assert result.size == len(PAYLOAD)  # type: ignore[attr-defined]
    assert result.sha256 == hashlib.sha256(PAYLOAD).hexdigest()  # type: ignore[attr-defined]


def test_a_matching_expected_sha256_is_accepted_in_any_case(tmp_path: Path) -> None:
    expected = hashlib.sha256(PAYLOAD).hexdigest().upper()

    _download(_ok, tmp_path / "data.zip", expected_sha256=expected)

    assert (tmp_path / "data.zip").exists()


def test_a_wrong_sha256_is_refused_and_leaves_no_file(tmp_path: Path) -> None:
    with pytest.raises(ImporterError) as caught:
        _download(_ok, tmp_path / "data.zip", expected_sha256="0" * 64)

    assert caught.value.code == "checksum_mismatch"
    assert list(tmp_path.iterdir()) == []


def test_a_declared_size_over_the_cap_is_refused_before_the_body(tmp_path: Path) -> None:
    with pytest.raises(ImporterError) as caught:
        _download(_ok, tmp_path / "data.zip", max_bytes=len(PAYLOAD) - 1)

    assert caught.value.code == "download_too_large"
    assert list(tmp_path.iterdir()) == []


def test_a_stream_that_outgrows_the_cap_is_stopped(tmp_path: Path) -> None:
    def chunks() -> Iterator[bytes]:
        for _ in range(100):
            yield b"x" * 1000  # no Content-Length: only counting can stop it

    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=chunks())

    with pytest.raises(ImporterError) as caught:
        _download(handler, tmp_path / "data.zip", max_bytes=5_000)

    assert caught.value.code == "download_too_large"
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize(
    ("url", "code"),
    [
        (f"http://{HOST}/data.zip", "fetch_insecure_url"),
        ("https://other.example.invalid/data.zip", "fetch_host_not_allowed"),
        (f"https://user:pw@{HOST}/data.zip", "fetch_host_not_allowed"),
        ("ftp://files.example.invalid/data.zip", "fetch_insecure_url"),
    ],
)
def test_only_https_urls_of_allowed_hosts_are_fetched(tmp_path: Path, url: str, code: str) -> None:
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        return httpx.Response(200, content=PAYLOAD)

    with _client(handler) as client, pytest.raises(ImporterError) as caught:
        download_file(client, url, tmp_path / "x", max_bytes=CAP, allowed_hosts=HOSTS)

    assert caught.value.code == code
    assert calls == []


def test_a_redirect_inside_the_allowed_hosts_is_followed(tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/data.zip":
            return httpx.Response(302, headers={"location": "/moved/data.zip"})
        return httpx.Response(200, content=PAYLOAD)

    _download(handler, tmp_path / "data.zip")

    assert (tmp_path / "data.zip").read_bytes() == PAYLOAD


@pytest.mark.parametrize(
    "location",
    ["https://evil.example.invalid/x", f"http://{HOST}/x", "file:///etc/passwd"],
)
def test_a_redirect_out_of_policy_is_refused(tmp_path: Path, location: str) -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(302, headers={"location": location})

    with pytest.raises(ImporterError) as caught:
        _download(handler, tmp_path / "data.zip")

    assert caught.value.code in {"fetch_host_not_allowed", "fetch_insecure_url"}
    assert list(tmp_path.iterdir()) == []


def test_a_redirect_loop_is_cut(tmp_path: Path) -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(302, headers={"location": URL})

    with pytest.raises(ImporterError) as caught:
        _download(handler, tmp_path / "data.zip")

    assert caught.value.code == "fetch_failed"


def test_http_errors_and_transport_errors_are_one_stable_code(tmp_path: Path) -> None:
    def server_error(_: httpx.Request) -> httpx.Response:
        return httpx.Response(503, content=b"secret body")

    def unreachable(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("boom " + str(request.url))

    for handler in (server_error, unreachable):
        with pytest.raises(ImporterError) as caught:
            _download(handler, tmp_path / "data.zip")
        assert caught.value.code == "fetch_failed"
        assert HOST not in str(caught.value)
        assert caught.value.__cause__ is None  # nothing of the exchange is chained
    assert list(tmp_path.iterdir()) == []


def test_get_json_reads_a_small_document(tmp_path: Path) -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"results": [1, 2]})

    with _client(handler) as client:
        assert get_json(client, URL, max_bytes=CAP, allowed_hosts=HOSTS) == {"results": [1, 2]}


def test_get_json_refuses_invalid_or_oversized_documents() -> None:
    def invalid(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"<html>")

    with _client(invalid) as client, pytest.raises(ImporterError) as caught:
        get_json(client, URL, max_bytes=CAP, allowed_hosts=HOSTS)
    assert caught.value.code == "invalid_download"

    with _client(_ok) as client, pytest.raises(ImporterError) as caught:
        get_json(client, URL, max_bytes=10, allowed_hosts=HOSTS)
    assert caught.value.code == "download_too_large"


def test_a_redirect_without_a_location_is_a_stable_failure(tmp_path: Path) -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(302)

    with pytest.raises(ImporterError) as caught:
        _download(handler, tmp_path / "data.zip")

    assert caught.value.code == "fetch_failed"


def test_get_json_survives_a_document_that_nests_too_deeply() -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"[" * 200_000 + b"]" * 200_000)

    with _client(handler) as client, pytest.raises(ImporterError) as caught:
        get_json(client, URL, max_bytes=1_000_000, allowed_hosts=HOSTS)

    assert caught.value.code == "invalid_download"


def test_a_slow_download_hits_the_overall_deadline_and_leaves_no_file(tmp_path: Path) -> None:
    ticks = iter(range(0, 1000, 10))

    def chunks() -> Iterator[bytes]:
        for _ in range(50):
            yield b"x" * 70_000

    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=chunks())

    with _client(handler) as client, pytest.raises(ImporterError) as caught:
        download_file(
            client,
            URL,
            tmp_path / "data.zip",
            max_bytes=10_000_000,
            allowed_hosts=HOSTS,
            max_seconds=25,
            clock=lambda: float(next(ticks)),
        )

    assert caught.value.code == "fetch_timeout"
    assert list(tmp_path.iterdir()) == []


def test_the_client_ignores_proxy_environment_variables(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HTTPS_PROXY", "http://proxy.invalid:3128")
    monkeypatch.setenv("ALL_PROXY", "http://proxy.invalid:3128")

    with new_client() as client:
        assert not client._mounts


SYNTHETIC_CA = CATALOG_DIR / "tests" / "fixtures" / "tls" / "synthetic_root_ca.pem"
RU_HOSTS = frozenset({"esklp.egisz.rosminzdrav.ru"})


def test_the_extra_ca_is_added_to_certifi_and_verification_stays_strict() -> None:
    context = trust_context(SYNTHETIC_CA)

    subjects = [dict(field[0] for field in cert["subject"]) for cert in context.get_ca_certs()]
    assert {"commonName": "PillPal Synthetic Test Root CA"} in subjects
    assert len(subjects) > 50  # certifi's roots are still trusted
    assert context.verify_mode == ssl.CERT_REQUIRED
    assert context.check_hostname is True


@pytest.mark.parametrize("content", [None, b"", b"not a certificate"])
def test_a_missing_or_unreadable_ca_file_is_refused(tmp_path: Path, content: bytes | None) -> None:
    path = tmp_path / "ca.pem"
    if content is not None:
        path.write_bytes(content)

    with pytest.raises(ImporterError) as caught:
        trust_context(path)
    assert caught.value.code == "ca_file_invalid"
    assert str(tmp_path) not in str(caught.value)


@pytest.mark.parametrize(
    "hosts",
    [
        frozenset({HOST}),
        frozenset({"esklp.egisz.rosminzdrav.ru", "roszdravnadzor.gov.ru"}),
        frozenset({"rosminzdrav.ru.example.invalid"}),
        frozenset(),
    ],
)
def test_the_extra_ca_is_only_for_rosminzdrav_hosts(hosts: frozenset[str]) -> None:
    with pytest.raises(ImporterError) as caught:
        new_client(allowed_hosts=hosts, extra_ca_file=SYNTHETIC_CA)
    assert caught.value.code == "extra_ca_not_allowed"


def test_a_rosminzdrav_client_takes_the_extra_ca() -> None:
    with new_client(allowed_hosts=RU_HOSTS, extra_ca_file=SYNTHETIC_CA) as client:
        assert client.headers["user-agent"] == "pillpal-catalog-importer"
