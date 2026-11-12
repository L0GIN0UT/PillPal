"""Check the staging landing page (infra/staging/site/) against its routing and CSP.

The page is served from the API host (docs/staging.md "Landing page"): the proxy
serves exactly / (index.html) and /site/* from this folder, everything else goes to
the API. Caddy sends a CSP with 'self' only and no inline code, and no request of a
visitor may go to another host. This script fails when:

* any entry of the folder is a symlink or has a name starting with "." (the proxy
  would serve, or hide, files nobody reviewed);
* an .html, .css, .js or .svg file contains a URL with a host (scheme://host or
  //host, IPs and localhost included), javascript:, @import or http-equiv
  (XML namespace declarations are not requests and are ignored);
* the HTML has inline code the CSP blocks: a <style> element, a style= attribute,
  an on*= handler or a <script> without src;
* an href, src, srcset or poster value, or og:image content, is anything other than
  "#...", "/" or "/site/<an existing file>" (query and fragment stripped), or is
  unquoted;
* a CSS url() does not resolve to an existing file under site/ (data: included:
  the CSP blocks it).

Usage: check_landing_site.py <site dir>
       check_landing_site.py --self-test
"""

import re
import sys
import tempfile
from pathlib import Path

CHECKED_SUFFIXES = (".html", ".css", ".js", ".svg")
SERVED_PREFIX = "site/"  # the folder behind the /site/* route
NAMESPACE = re.compile(r"""xmlns(?::\w+)?=["'][^"']+["']""")
HOST_URL = re.compile(r"""(?i)(?:[a-z][a-z0-9+.-]*:)?//[^\s"'()<>/]+""")
FORBIDDEN = (
    (re.compile(r"(?i)javascript:"), "javascript: URL"),
    (re.compile(r"(?i)@import"), "@import"),
    (re.compile(r"(?i)http-equiv"), "http-equiv"),
)
INLINE_CODE = (
    (re.compile(r"(?i)<style[\s>]"), "inline <style> element"),
    (re.compile(r"(?i)\sstyle\s*="), "style= attribute"),
    (re.compile(r"(?i)\son[a-z]+\s*="), "inline event handler"),
    (re.compile(r"(?i)<script(?![^>]*\ssrc\s*=)[^>]*>"), "<script> without src"),
)
URL_ATTRIBUTE = re.compile(
    r"""(?i)\s(?:xlink:)?(href|src|srcset|poster)\s*=\s*"""
    r"""(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"""
)
META_TAG = re.compile(r"(?i)<meta\b[^>]*>")
META_CONTENT = re.compile(r"""(?i)\scontent\s*=\s*(?:"([^"]*)"|'([^']*)')""")
CSS_URL = re.compile(r"""url\(\s*["']?([^"')]+?)["']?\s*\)""")


def _strip(reference: str) -> str:
    return re.split(r"[?#]", reference, maxsplit=1)[0]


def _served(site: Path, relative: str) -> bool:
    """True when the folder-relative path is a file behind the /site/* route."""
    return (
        relative.startswith(SERVED_PREFIX)
        and ".." not in relative.split("/")
        and (site / relative).is_file()
    )


def _reference_problem(site: Path, value: str) -> str | None:
    value = value.strip()
    if value.startswith("#") or value == "/":
        return None
    path = _strip(value)
    if path.startswith("/site/") and _served(site, path.lstrip("/")):
        return None
    return f"reference {value!r} is not '#...', '/' or '/site/<existing file>'"


def _attribute_values(name: str, value: str) -> list[str]:
    if name.lower() != "srcset":
        return [value]
    return [candidate.split()[0] for candidate in value.split(",") if candidate.split()]


def _html_problems(text: str, site: Path) -> list[str]:
    found = [label for pattern, label in INLINE_CODE if pattern.search(text)]
    for match in URL_ATTRIBUTE.finditer(text):
        name, double, single, bare = match.groups()
        if bare is not None:
            found.append(f"unquoted {name}= value")
            continue
        value = double if double is not None else single
        for candidate in _attribute_values(name, value):
            if problem := _reference_problem(site, candidate):
                found.append(problem)
    for tag in META_TAG.findall(text):
        content = META_CONTENT.search(tag)
        if "og:image" in tag.lower() and content:
            value = content.group(1) if content.group(1) is not None else content.group(2)
            if problem := _reference_problem(site, value):
                found.append(f"og:image {problem}")
    return found


def _css_problems(text: str, path: Path, site: Path) -> list[str]:
    root = site.resolve()
    found = []
    for reference in CSS_URL.findall(text):
        stripped = _strip(reference)
        relative = ""
        if ":" not in stripped:
            base = site if stripped.startswith("/") else path.parent
            target = (base / stripped.lstrip("/")).resolve()
            if target.is_relative_to(root):
                relative = target.relative_to(root).as_posix()
        if not _served(site, relative):
            found.append(f"url({reference}) is not an existing file under /site/")
    return found


def _file_problems(path: Path, site: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    scanned = NAMESPACE.sub("", text)
    found = [f"URL with a host {m.group(0)}" for m in HOST_URL.finditer(scanned)]
    found += [label for pattern, label in FORBIDDEN if pattern.search(scanned)]
    suffix = path.suffix.lower()
    if suffix == ".html":
        found += _html_problems(text, site)
    elif suffix == ".css":
        found += _css_problems(text, path, site)
    name = path.relative_to(site).as_posix()
    return [f"{name}: {message}" for message in found]


def problems(site: Path) -> list[str]:
    """Return one message per problem (empty: all good)."""
    found: list[str] = []
    for path in sorted(site.rglob("*")):
        name = path.relative_to(site).as_posix()
        if path.is_symlink():
            found.append(f"{name}: symlink")
        elif path.name.startswith("."):
            found.append(f"{name}: dotfile")
        elif path.is_file() and path.suffix.lower() in CHECKED_SUFFIXES:
            found += _file_problems(path, site)
    if not (site / "index.html").is_file():
        found.append("index.html is missing")
    return found


GOOD_HTML = (
    '<!doctype html><link rel="stylesheet" href="/site/site.css?v=1">'
    '<script src="/site/site.js" defer></script><a href="/">home</a>'
    "<meta property='og:image' content='/site/favicon.svg'>"
    '<svg xmlns:xlink="http://www.w3.org/1999/xlink"><use href="#mono"/></svg>'
)
GOOD_SITE = {
    "index.html": GOOD_HTML,
    "site/site.css": '@font-face{src:url("fonts/A.ttf")}b{c:url(/site/favicon.svg#x)}',
    "site/site.js": "// a comment\ndocument.title;",
    "site/fonts/A.ttf": "x",
    "site/favicon.svg": '<svg xmlns="http://www.w3.org/2000/svg"></svg>',
}
# label -> (files replacing or adding to GOOD_SITE, expected message part or None)
SELF_TEST_CASES: dict[str, tuple[dict[str, str], str | None]] = {
    "clean site": ({}, None),
    "google fonts": (
        {"index.html": GOOD_HTML + '<link href="https://fonts.googleapis.com/x">'},
        "index.html: URL with a host https://fonts.googleapis.com",
    ),
    "ip host": ({"site/site.js": "f('http://10.0.0.1:8000/x')"}, "URL with a host http://10.0.0.1:8000"),
    "localhost": ({"site/site.js": "f('//localhost/x')"}, "URL with a host //localhost"),
    "css remote": ({"site/site.css": "a{b:url(https://x.example/a.png)}"}, "URL with a host https://x.example"),
    "css data": ({"site/site.css": "a{b:url(data:image/png;base64,AA)}"}, "url(data:image/png;base64,AA) is not"),
    "css missing": ({"site/site.css": "@font-face{src:url(fonts/B.ttf)}"}, "url(fonts/B.ttf) is not"),
    "css outside": ({"site/site.css": "a{b:url(../index.html)}"}, "url(../index.html) is not"),
    "import": ({"site/site.css": "@import 'x.css';"}, "site/site.css: @import"),
    "javascript": ({"index.html": GOOD_HTML + "<a href='javascript:x()'>"}, "javascript: URL"),
    "http-equiv": ({"index.html": GOOD_HTML + '<meta http-equiv="refresh" content="0">'}, "http-equiv"),
    "inline style": ({"index.html": GOOD_HTML + "<style>a{}</style>"}, "inline <style> element"),
    "style attribute": ({"index.html": GOOD_HTML + '<svg style="x">'}, "style= attribute"),
    "inline script": ({"index.html": GOOD_HTML + "<script>x()</script>"}, "<script> without src"),
    "event handler": ({"index.html": GOOD_HTML + '<a onclick="x()">'}, "inline event handler"),
    "api path": ({"index.html": GOOD_HTML + '<a href="/v1/x">'}, "reference '/v1/x' is not"),
    "relative": ({"index.html": GOOD_HTML + "<img src='site/favicon.svg'>"}, "reference 'site/favicon.svg'"),
    "missing": ({"index.html": GOOD_HTML + '<link href="/site/nope.css">'}, "reference '/site/nope.css'"),
    "traversal": ({"index.html": GOOD_HTML + '<a href="/site/../index.html">'}, "reference '/site/../index.html'"),
    "srcset": ({"index.html": GOOD_HTML + '<img srcset="/site/favicon.svg 1x, /i 2x">'}, "reference '/i' is not"),
    "poster": ({"index.html": GOOD_HTML + '<video poster="/healthz">'}, "reference '/healthz' is not"),
    "og:image": ({"index.html": GOOD_HTML + '<meta content="/x.png" property="og:image">'}, "og:image reference '/x.png'"),
    "unquoted": ({"index.html": GOOD_HTML + "<a href=/v1>"}, "unquoted href= value"),
    "dotfile": ({"site/.hidden": "x"}, "site/.hidden: dotfile"),
    "dot folder": ({"site/.git/config": "x"}, "site/.git: dotfile"),
    "no index": ({"index.html": ""}, "index.html is missing"),
}


def _make_site(root: Path, overrides: dict[str, str]) -> None:
    for name, text in {**GOOD_SITE, **overrides}.items():
        if name == "index.html" and not text:
            continue
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")


def _case_failed(label: str, found: list[str], expected: str | None) -> bool:
    ok = not found if expected is None else any(expected in message for message in found)
    if not ok:
        print(f"self-test FAILED: {label}: expected {expected!r}, got {found}", file=sys.stderr)
    return not ok


def _symlink_case_failed() -> bool:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        _make_site(root, {})
        try:
            (root / "site" / "link.css").symlink_to(root / "site" / "site.css")
        except OSError:  # Windows without the symlink privilege; CI (Linux) runs it
            print("self-test: symlink case skipped (no symlink privilege)", file=sys.stderr)
            return False
        return _case_failed("symlink", problems(root), "site/link.css: symlink")


def _self_test() -> int:
    failed = 0
    for label, (overrides, expected) in SELF_TEST_CASES.items():
        with tempfile.TemporaryDirectory() as directory:
            _make_site(Path(directory), overrides)
            failed += _case_failed(label, problems(Path(directory)), expected)
    failed += _symlink_case_failed()
    print("self-test ok" if not failed else f"self-test: {failed} failed")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        return _self_test()
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    found = problems(Path(argv[1]))
    for message in found:
        print(f"::error::landing page: {message}")
    if not found:
        print("landing page: same-origin only, no inline code, references only / and /site/*")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
