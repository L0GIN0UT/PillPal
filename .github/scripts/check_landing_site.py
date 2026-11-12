"""Check the staging landing page (infra/staging/site/) for third-party loads.

The page is Russian and is served from the API host: no request of a visitor may
go to another host (no visitor IP leaves for a foreign server), and Caddy sends a
CSP that allows only same-origin styles, scripts and fonts and no inline code
(docs/staging.md "Landing page"). This script fails when:

* an .html, .css, .js or .svg file contains an absolute or protocol-relative URL
  (the SVG namespace identifier is not a request and is allowed);
* the HTML has inline code the CSP would block: a <style> element, a style=
  attribute, an on*= handler or a <script> without src;
* a local reference (/site/... or a relative url() in CSS) points to a missing file.

Usage: check_landing_site.py <site dir>
       check_landing_site.py --self-test
"""

import re
import sys
import tempfile
from pathlib import Path

CHECKED_SUFFIXES = (".html", ".css", ".js", ".svg")
SVG_NAMESPACE = 'xmlns="http://www.w3.org/2000/svg"'
ABSOLUTE_URL = re.compile(r"(?i)(?:https?:)?//[a-z0-9.-]+\.[a-z]{2,}")
INLINE_CODE = (
    (re.compile(r"(?i)<style[\s>]"), "inline <style> element"),
    (re.compile(r"(?i)\sstyle\s*="), "style= attribute"),
    (re.compile(r"(?i)\son[a-z]+\s*="), "inline event handler"),
    (re.compile(r"(?i)<script(?![^>]*\ssrc=)[^>]*>"), "<script> without src"),
)
SITE_REFERENCE = re.compile(r"""(?:href|src)="(/site/[^"#?]*)\"""")
CSS_URL = re.compile(r"""url\(\s*["']?([^"')]+)["']?\s*\)""")


def _file_problems(path: Path, site: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    name = path.relative_to(site).as_posix()
    found = [
        f"{name}: external URL {match.group(0)}"
        for match in ABSOLUTE_URL.finditer(text.replace(SVG_NAMESPACE, ""))
    ]
    if path.suffix == ".html":
        found += [f"{name}: {label}" for pattern, label in INLINE_CODE if pattern.search(text)]
        for reference in SITE_REFERENCE.findall(text):
            if not (site / reference.lstrip("/")).is_file():
                found.append(f"{name}: missing file {reference}")
    if path.suffix == ".css":
        for reference in CSS_URL.findall(text):
            if reference.startswith(("data:", "#")):
                continue
            if not (path.parent / reference).is_file():
                found.append(f"{name}: missing file {reference}")
    return found


def problems(site: Path) -> list[str]:
    """Return one message per problem (empty: all good)."""
    if not (site / "index.html").is_file():
        return ["index.html is missing"]
    found: list[str] = []
    for path in sorted(site.rglob("*")):
        if path.is_file() and path.suffix in CHECKED_SUFFIXES:
            found += _file_problems(path, site)
    return found


def _site(files: dict[str, str]) -> Path:
    root = Path(tempfile.mkdtemp())
    for name, text in files.items():
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    return root


def _self_test() -> int:
    good_html = (
        '<!doctype html><link rel="stylesheet" href="/site/site.css">'
        '<script src="/site/site.js" defer></script>'
        '<svg><use href="#mono"/></svg>'
    )
    good = {
        "index.html": good_html,
        "site/site.css": '@font-face{src:url("fonts/A.ttf")}',
        "site/site.js": "document.title;",
        "site/fonts/A.ttf": "x",
        "site/favicon.svg": '<svg xmlns="http://www.w3.org/2000/svg"></svg>',
    }
    cases = {
        "clean site": (good, False),
        "google fonts link": (
            {**good, "index.html": good_html + '<link href="https://fonts.googleapis.com/css2">'},
            True,
        ),
        "protocol-relative": ({**good, "site/site.js": "fetch('//cdn.example.com/x')"}, True),
        "css remote url": ({**good, "site/site.css": "a{background:url(https://x.example/a.png)}"}, True),
        "inline style element": ({**good, "index.html": good_html + "<style>a{}</style>"}, True),
        "style attribute": ({**good, "index.html": good_html + '<svg style="position:absolute">'}, True),
        "inline script": ({**good, "index.html": good_html + "<script>alert(1)</script>"}, True),
        "event handler": ({**good, "index.html": good_html + '<a onclick="x()">'}, True),
        "missing asset": ({**good, "index.html": good_html + '<link href="/site/nope.css">'}, True),
        "missing font": ({**good, "site/site.css": "@font-face{src:url(fonts/B.ttf)}"}, True),
        "no index": ({"site/site.css": ""}, True),
    }
    failed = 0
    for label, (files, expect_problem) in cases.items():
        found = problems(_site(files))
        if bool(found) != expect_problem:
            failed += 1
            print(f"self-test FAILED: {label}: {found}")
    print("self-test ok" if not failed else f"self-test: {failed} failed")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        return _self_test()
    if len(argv) != 2:
        print(__doc__)
        return 2
    found = problems(Path(argv[1]))
    for message in found:
        print(f"::error::landing page: {message}")
    if not found:
        print("landing page: same-origin only, no inline code")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
