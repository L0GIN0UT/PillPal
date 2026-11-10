"""Guard against raw UI literals under app/lib/src/features (docs/ui-pass-plan.md, UI-1).

Screens use the tokens in app/lib/src/theme (spacing, radius, palette, text theme)
and the shared widgets in features/common. This script counts raw literals per
file and compares them with a ratchet baseline (app/tool/ui_literals_baseline.json)
that may only go down:

  * a count above the baseline fails (new literal);
  * a baseline above the count fails too (stale: run --update to lower it);
  * a file missing from the baseline has a baseline of 0.

Counted: EdgeInsets.*( with a non-zero number, SizedBox(height|width: N != 0),
Radius.circular(N), Color(0x..), Colors.* (except transparent), TextStyle( with
fontSize/fontWeight, spacing/runSpacing: N, Icon(size: N). A literal is excused
by `// ui-literal-ok: <reason>` on a line of the same expression.
report_pdf.dart renders a PDF, not Flutter UI, and is not scanned.

Usage: check_ui_tokens.py [check]     compare with the baseline (default)
       check_ui_tokens.py --update    lower the baseline to today's counts
       check_ui_tokens.py --self-test
"""

import json
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FEATURES = Path("app/lib/src/features")
BASELINE = Path("app/tool/ui_literals_baseline.json")
EXCLUDED_FILES = {"report_pdf.dart"}

ESCAPE = re.compile(r"//\s*ui-literal-ok:\s*\S")
NUMBER = re.compile(r"(?<![\w.$])(?:\d+\.\d*|\.\d+|\d+)")
SIZED_BOX_ARG = re.compile(r"\b(?:height|width):\s*(\d+(?:\.\d+)?)")
SPACING_ARG = re.compile(r"\b(?:spacing|runSpacing):\s*(\d+(?:\.\d+)?)")
ICON_SIZE_ARG = re.compile(r"\bsize:\s*(\d+(?:\.\d+)?)")
RADIUS = re.compile(r"\b(?:Border)?Radius\.circular\(\s*(\d+(?:\.\d+)?)")
COLOR_HEX = re.compile(r"\bColor\(\s*0x")
COLORS = re.compile(r"\bColors\.(?!transparent\b)\w+")
CALL = re.compile(r"\b(EdgeInsets\.\w+|SizedBox|TextStyle|Icon)\(")
TEXT_STYLE_ARG = re.compile(r"\b(?:fontSize|fontWeight):")


def _strip_comments(text: str) -> str:
    """Blank out // comments (not the // of a URL) keeping offsets and lines."""
    return re.sub(r"(?<!:)//[^\n]*", lambda m: " " * len(m.group()), text)


def _balanced_end(text: str, open_index: int) -> int:
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    return len(text) - 1


def _nonzero(values: list[str]) -> int:
    return sum(1 for v in values if float(v) != 0)


def count_literals(text: str) -> int:
    """Number of raw UI literals in a Dart source that are not excused."""
    lines = text.split("\n")
    excused = {i for i, line in enumerate(lines) if ESCAPE.search(line)}
    code = _strip_comments(text)
    starts = [0]
    for line in lines:
        starts.append(starts[-1] + len(line) + 1)

    def line_of(index: int) -> int:
        lo, hi = 0, len(lines) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= index:
                lo = mid
            else:
                hi = mid - 1
        return lo

    def is_excused(start: int, end: int) -> bool:
        return any(i in excused for i in range(line_of(start), line_of(end) + 1))

    total = 0

    def add(n: int, start: int, end: int) -> None:
        nonlocal total
        if n and not is_excused(start, end):
            total += n

    for m in CALL.finditer(code):
        end = _balanced_end(code, m.end() - 1)
        args = code[m.end() : end]
        name = m.group(1)
        if name.startswith("EdgeInsets."):
            add(_nonzero(NUMBER.findall(args)), m.start(), end)
        elif name == "SizedBox":
            add(_nonzero(SIZED_BOX_ARG.findall(args)), m.start(), end)
        elif name == "Icon":
            add(_nonzero(ICON_SIZE_ARG.findall(args)), m.start(), end)
        elif TEXT_STYLE_ARG.search(args):
            add(1, m.start(), end)
    for pattern in (COLOR_HEX, COLORS):
        for m in pattern.finditer(code):
            add(1, m.start(), m.end())
    for pattern in (RADIUS, SPACING_ARG):
        for m in pattern.finditer(code):
            add(_nonzero([m.group(1)]), m.start(), m.end())
    return total


def scan(root: Path) -> dict[str, int]:
    """Per-file counts (files with none are omitted), keyed by repo-relative path."""
    counts: dict[str, int] = {}
    for path in sorted((root / FEATURES).rglob("*.dart")):
        if path.name in EXCLUDED_FILES:
            continue
        n = count_literals(path.read_text(encoding="utf-8"))
        if n:
            counts[path.relative_to(root).as_posix()] = n
    return counts


def load_baseline(root: Path) -> dict[str, int]:
    path = root / BASELINE
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    return {k: int(v) for k, v in data.items()}


def compare(counts: dict[str, int], baseline: dict[str, int]) -> list[str]:
    """Messages for new literals and for stale baseline entries."""
    problems: list[str] = []
    for file in sorted(set(counts) | set(baseline)):
        now, allowed = counts.get(file, 0), baseline.get(file, 0)
        if now > allowed:
            problems.append(
                f"{file}: {now} raw UI literals, baseline {allowed}. Use the tokens in "
                "app/lib/src/theme (PillPalSpacing, PillPalRadius, palette, textTheme) "
                "or mark a justified case with `// ui-literal-ok: <reason>`."
            )
        elif now < allowed:
            problems.append(
                f"{file}: baseline {allowed} is stale, only {now} literals left. "
                "Run `python3 .github/scripts/check_ui_tokens.py --update` and commit it."
            )
    return problems


def write_baseline(root: Path, counts: dict[str, int]) -> None:
    path = root / BASELINE
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(counts, indent=2, sort_keys=True) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")


def update(root: Path) -> list[str]:
    """Lower the baseline to today's counts; refuses to raise any entry."""
    counts, baseline = scan(root), load_baseline(root)
    if baseline:
        raising = [p for p in compare(counts, baseline) if "raw UI literals" in p]
        if raising:
            return raising
    write_baseline(root, counts)
    return []


def _report(problems: list[str]) -> int:
    for problem in problems:
        print(f"::error title=ui-tokens::{problem}")
        print(problem)
    return 1 if problems else 0


def self_test() -> None:
    assert count_literals("const EdgeInsets.all(16)") == 1
    assert count_literals("EdgeInsets.fromLTRB(\n  PillPalSpacing.xl,\n  8,\n  0,\n  0)") == 1
    assert count_literals("EdgeInsets.all(PillPalSpacing.lg)") == 0
    assert count_literals("EdgeInsets.zero + EdgeInsets.all(0)") == 0
    assert count_literals("SizedBox(height: 12)") == 1
    assert count_literals("SizedBox(width: 4, height: 8)") == 2
    assert count_literals("SizedBox(height: 0)") == 0
    assert count_literals("SizedBox(width: double.infinity, height: PillPalSpacing.lg)") == 0
    assert count_literals("BorderRadius.circular(20)") == 1
    assert count_literals("Radius.circular(PillPalRadius.xl)") == 0
    assert count_literals("Color(0xFFFFFFFF)") == 1
    assert count_literals("Colors.white") == 1
    assert count_literals("Colors.transparent") == 0
    assert count_literals("TextStyle(color: c)") == 0
    assert count_literals("TextStyle(fontSize: 14)") == 1
    assert count_literals("Wrap(spacing: 8, runSpacing: 6)") == 2
    assert count_literals("Wrap(spacing: PillPalSpacing.chips)") == 0
    assert count_literals("Icon(Icons.add, size: 20)") == 1
    assert count_literals("Icon(Icons.add)") == 0
    assert count_literals("// SizedBox(height: 12)") == 0
    assert count_literals("final u = 'https://x'; SizedBox(height: 4)") == 1
    escaped = "SizedBox(height: 12) // ui-literal-ok: QR quiet zone"
    assert count_literals(escaped) == 0
    assert count_literals("SizedBox(height: 12) // ui-literal-ok:") == 1
    multi = (
        "EdgeInsets.symmetric(\n  // ui-literal-ok: legacy\n  vertical: 3,\n)\n"
        "SizedBox(height: 5)"
    )
    assert count_literals(multi) == 1

    stale = compare({"a.dart": 3, "b.dart": 1}, {"a.dart": 3, "b.dart": 2, "c.dart": 1})
    assert len(stale) == 2 and all("stale" in p for p in stale)
    assert compare({"a.dart": 4}, {"a.dart": 3})[0].startswith("a.dart: 4 raw")
    assert compare({"new.dart": 1}, {}) != []
    assert compare({"a.dart": 3}, {"a.dart": 3}) == []

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        features = root / FEATURES
        features.mkdir(parents=True)
        key = "app/lib/src/features/screen.dart"
        screen = features / "screen.dart"
        screen.write_text("SizedBox(height: 8);\nSizedBox(width: 4);\n", encoding="utf-8")
        (features / "report_pdf.dart").write_text("SizedBox(height: 8);", encoding="utf-8")
        assert scan(root) == {key: 2}
        assert update(root) == []
        assert compare(scan(root), load_baseline(root)) == []
        screen.write_text("SizedBox(height: 8);\n", encoding="utf-8")
        assert any("stale" in p for p in compare(scan(root), load_baseline(root)))
        assert update(root) == []
        assert load_baseline(root) == {key: 1}
        screen.write_text("SizedBox(height: 8);\nSizedBox(height: 9);\n", encoding="utf-8")
        assert update(root) != []
        assert load_baseline(root) == {key: 1}
    print("check_ui_tokens self-test passed")


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        self_test()
        return 0
    if argv == ["--update"]:
        code = _report(update(ROOT))
        if code == 0:
            print(f"baseline updated: {BASELINE}")
        return code
    if argv in ([], ["check"]):
        return _report(compare(scan(ROOT), load_baseline(ROOT)))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
