"""Guard against raw UI literals under app/lib/src/features (docs/ui-pass-plan.md, UI-1).

Screens use the tokens in app/lib/src/theme (spacing, radius, palette, text theme)
and the shared widgets in features/common. This script counts raw literals per
file and compares them with a ratchet baseline (app/tool/ui_literals_baseline.json)
that may only go down:

  * a count above the baseline fails (new literal);
  * a baseline above the count fails too (stale: run --update to lower it);
  * a file missing from the baseline has a baseline of 0; a baseline entry of a
    deleted file is stale.

One literal is counted per occurrence of:
  * a non-zero number in EdgeInsets.*( / EdgeInsetsDirectional.*(;
  * a non-zero number as the own (top-level) width/height of SizedBox, as
    SizedBox.square(dimension:), and as height/width/thickness/indent/endIndent
    of Divider/VerticalDivider;
  * Icon(size:), IconButton(iconSize:), CircleAvatar(radius:), Radius.circular(N),
    spacing:/runSpacing: N;
  * Color(0x..), Color.fromARGB/fromRGBO, Colors.* (except transparent),
    .withOpacity(N), .withValues(alpha: N);
  * TextStyle( with fontSize, copyWith(fontSize: N), FontWeight.wNNN;
  * the deprecated aliases PillPalSizes.(card|control|sheet)Radius and
    PillPalSizes.statusSquare, and the widgets the «Забота» redesign replaces
    (docs/redesign-plan.md): InfoNote( and TodaySummaryCard(. Each screen
    milestone lowers their counts; R8 empties the baseline.
A number that is an operand of arithmetic on a token (`PillPalSpacing.md * 2`) is
derived from the scale and does not count. Strings are ignored. A literal is excused
by `// ui-literal-ok: <reason>` in a real comment on the line of the literal.
report_pdf.dart renders a PDF, not Flutter UI, and is not scanned.

Usage: check_ui_tokens.py [check]     compare with the baseline (default)
       check_ui_tokens.py --update    lower the baseline to today's counts
       check_ui_tokens.py --self-test
"""

import bisect
import contextlib
import io
import json
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FEATURES = Path("app/lib/src/features")
BASELINE = Path("app/tool/ui_literals_baseline.json")
EXCLUDED_FILES = {"report_pdf.dart"}

ESCAPE = re.compile(r"ui-literal-ok:\s*\S")
NUMBER = re.compile(r"(?<![\w.$])(?:\d+\.\d*|\.\d+|\d+)")
OPERATORS = "*/+-%"
SIMPLE_PATTERNS = (
    re.compile(r"\bColor\(\s*0x"),
    re.compile(r"\bColor\.from(?:ARGB|RGBO)\("),
    re.compile(r"\bColors\.(?!transparent\b)\w+"),
    re.compile(r"\bFontWeight\.w\d+"),
    re.compile(r"\bPillPalSizes\.(?:card|control|sheet)Radius\b"),
    re.compile(r"\bPillPalSizes\.statusSquare\b"),
    re.compile(r"\bInfoNote\("),
    re.compile(r"\bTodaySummaryCard\("),
)
# Counted unless the number (group 1) is derived from a token.
NUMERIC_PATTERNS = (
    re.compile(r"\b(?:Border)?Radius\.circular\(\s*(\d+(?:\.\d+)?)"),
    re.compile(r"\b(?:spacing|runSpacing):\s*(\d+(?:\.\d+)?)"),
    re.compile(r"\.withOpacity\(\s*(\d+(?:\.\d+)?)"),
    re.compile(r"\.withValues\(\s*alpha:\s*(\d+(?:\.\d+)?)"),
)
CALL = re.compile(
    r"\b(EdgeInsets(?:Directional)?\.\w+|SizedBox(?:\.square)?|Divider|VerticalDivider"
    r"|TextStyle|Icon|IconButton|CircleAvatar|copyWith)\("
)
# Top-level named arguments whose numeric value is a literal, per call.
NUMERIC_ARGS = {
    "SizedBox": {"height", "width"},
    "SizedBox.square": {"dimension"},
    "Divider": {"height", "thickness", "indent", "endIndent"},
    "VerticalDivider": {"width", "thickness", "indent", "endIndent"},
    "Icon": {"size"},
    "IconButton": {"iconSize"},
    "CircleAvatar": {"radius"},
    "copyWith": {"fontSize"},
}


def mask(text: str) -> tuple[str, set[int]]:
    """Blank comments and string contents (offsets and newlines kept).

    Returns the masked code and the 0-based lines with a `ui-literal-ok:` in a
    real comment. `${...}` interpolations inside strings stay code.
    """
    out = list(text)
    escaped: set[int] = set()
    # code entry: ["code", brace depth]; string entry: ["str", delimiter, raw]
    stack: list[list[object]] = [["code", 0]]

    def blank(start: int, end: int) -> None:
        for k in range(start, end):
            if out[k] != "\n":
                out[k] = " "

    def note_comment(start: int, end: int) -> None:
        first = text.count("\n", 0, start)
        for offset, line in enumerate(text[start:end].split("\n")):
            if ESCAPE.search(line):
                escaped.add(first + offset)

    i, n = 0, len(text)
    while i < n:
        top = stack[-1]
        if top[0] == "code":
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = n if end < 0 else end
                note_comment(i, end)
                blank(i, end)
                i = end
            elif text.startswith("/*", i):
                end = text.find("*/", i + 2)
                end = n if end < 0 else end + 2
                note_comment(i, end)
                blank(i, end)
                i = end
            elif text[i] in "'\"":
                quote = text[i]
                delim = quote * 3 if text.startswith(quote * 3, i) else quote
                raw = (
                    i > 0
                    and text[i - 1] == "r"
                    and not (i > 1 and (text[i - 2].isalnum() or text[i - 2] == "_"))
                )
                stack.append(["str", delim, raw])
                blank(i, i + len(delim))
                i += len(delim)
            else:
                depth = int(str(top[1]))
                if len(stack) > 1 and text[i] == "}" and depth == 0:
                    stack.pop()
                    blank(i, i + 1)
                elif len(stack) > 1 and text[i] == "{":
                    top[1] = depth + 1
                elif len(stack) > 1 and text[i] == "}":
                    top[1] = depth - 1
                i += 1
        else:
            delim, raw = str(top[1]), bool(top[2])
            if text.startswith(delim, i):
                stack.pop()
                blank(i, i + len(delim))
                i += len(delim)
            elif not raw and text[i] == "\\":
                blank(i, min(i + 2, n))
                i += 2
            elif not raw and text.startswith("${", i):
                stack.append(["code", 0])
                blank(i, i + 2)
                i += 2
            else:
                blank(i, i + 1)
                i += 1
    return "".join(out), escaped


def _balanced_end(code: str, open_index: int) -> int:
    depth = 0
    for i in range(open_index, len(code)):
        if code[i] in "([{":
            depth += 1
        elif code[i] in ")]}":
            depth -= 1
            if depth == 0:
                return i
    return len(code) - 1


def _top_level_args(code: str, start: int, end: int) -> list[tuple[str, int, int]]:
    """(name, value start, value end) of each top-level named argument."""
    args: list[tuple[str, int, int]] = []
    depth, seg = 0, start
    for i in range(start, end + 1):
        ch = code[i] if i < end else ","
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            m = re.match(r"\s*(\w+)\s*:(?!:)", code[seg:i])
            if m:
                args.append((m.group(1), seg + m.end(), i))
            seg = i + 1
    return args


def _derived(code: str, a: int, b: int) -> bool:
    """True when the number at code[a:b] is an operand of arithmetic on a token."""
    before = code[:a].rstrip()
    if before and before[-1] in OPERATORS:
        left = before[:-1].rstrip()
        if left and (left[-1].isalpha() or left[-1] in "_)"):
            return True
    after = code[b:].lstrip()
    if after and after[0] in OPERATORS:
        right = after[1:].lstrip()
        if right and (right[0].isalpha() or right[0] == "_"):
            return True
    return False


def _literals(code: str, start: int, end: int) -> list[int]:
    """Offsets of non-zero, non-derived numbers in code[start:end]."""
    return [
        m.start()
        for m in NUMBER.finditer(code, start, end)
        if float(m.group()) != 0 and not _derived(code, m.start(), m.end())
    ]


def count_literals(text: str) -> int:
    """Number of raw UI literals in a Dart source that are not excused."""
    code, escaped = mask(text)
    newlines = [i for i, ch in enumerate(code) if ch == "\n"]
    offsets: list[int] = []
    for m in CALL.finditer(code):
        name = m.group(1)
        end = _balanced_end(code, m.end() - 1)
        if name.startswith(("EdgeInsets.", "EdgeInsetsDirectional.")):
            offsets += _literals(code, m.end(), end)
            continue
        for arg, a, b in _top_level_args(code, m.end(), end):
            if arg in NUMERIC_ARGS.get(name, ()):
                offsets += _literals(code, a, b)
            elif name == "TextStyle" and arg == "fontSize":
                offsets.append(a)
    for pattern in SIMPLE_PATTERNS:
        offsets += [m.start() for m in pattern.finditer(code)]
    for pattern in NUMERIC_PATTERNS:
        for m in pattern.finditer(code):
            if float(m.group(1)) != 0 and not _derived(code, m.start(1), m.end(1)):
                offsets.append(m.start(1))
    lines = [bisect.bisect_left(newlines, o) for o in offsets]
    return sum(1 for line in lines if line not in escaped)


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


def compare(counts: dict[str, int], baseline: dict[str, int]) -> list[tuple[str, str]]:
    """(file, message) for new literals and for stale baseline entries."""
    problems: list[tuple[str, str]] = []
    for file in sorted(set(counts) | set(baseline)):
        now, allowed = counts.get(file, 0), baseline.get(file, 0)
        if now > allowed:
            problems.append(
                (
                    file,
                    f"{now} raw UI literals, baseline {allowed}. Use the tokens in "
                    "app/lib/src/theme (PillPalSpacing, PillPalRadius, palette, textTheme) "
                    "or mark a justified case with `// ui-literal-ok: <reason>`.",
                )
            )
        elif now < allowed:
            problems.append(
                (
                    file,
                    f"baseline {allowed} is stale, only {now} literals left. "
                    "Run `python3 .github/scripts/check_ui_tokens.py --update` and commit it.",
                )
            )
    return problems


def write_baseline(root: Path, counts: dict[str, int]) -> None:
    path = root / BASELINE
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(counts, indent=2, sort_keys=True) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")


def update(root: Path) -> list[tuple[str, str]]:
    """Lower the baseline to today's counts; refuses to raise any entry."""
    counts, baseline = scan(root), load_baseline(root)
    if baseline:
        raising = [p for p in compare(counts, baseline) if "raw UI literals" in p[1]]
        if raising:
            return raising
    write_baseline(root, counts)
    return []


def _report(problems: list[tuple[str, str]]) -> int:
    for file, message in problems:
        print(f"::error file={file},title=ui-tokens::{message}")
    return 1 if problems else 0


def main(argv: list[str], root: Path = ROOT) -> int:
    if argv == ["--self-test"]:
        self_test()
        return 0
    if argv == ["--update"]:
        code = _report(update(root))
        if code == 0:
            print(f"baseline updated: {BASELINE}")
        return code
    if argv in ([], ["check"]):
        return _report(compare(scan(root), load_baseline(root)))
    print(__doc__)
    return 2


def self_test() -> None:
    count = count_literals

    # EdgeInsets: per literal; tokens and arithmetic on tokens do not count.
    assert count("const EdgeInsets.all(16)") == 1
    assert count("EdgeInsets.fromLTRB(\n  PillPalSpacing.xl,\n  8,\n  0,\n  4)") == 2
    assert count("EdgeInsets.all(PillPalSpacing.lg)") == 0
    assert count("EdgeInsets.zero + EdgeInsets.all(0)") == 0
    assert count("EdgeInsetsDirectional.only(start: 12)") == 1
    assert count("EdgeInsets.all(PillPalSpacing.md * 2)") == 0
    assert count("EdgeInsets.all(2 * PillPalSpacing.md)") == 0
    assert count("EdgeInsets.all(PillPalSpacing.md + 3)") == 0
    assert count("EdgeInsets.all(-4)") == 1
    assert count("EdgeInsets.all(8 + 4)") == 2
    # SizedBox: own top-level arguments only.
    assert count("SizedBox(height: 12)") == 1
    assert count("SizedBox(width: 4, height: 8)") == 2
    assert count("SizedBox(height: 0)") == 0
    assert count("SizedBox(width: double.infinity, height: PillPalSpacing.lg)") == 0
    assert count("SizedBox(height: 8, child: Container(width: 3, height: 5))") == 1
    assert count("SizedBox(child: Row(children: [SizedBox(width: PillPalSpacing.sm)]))") == 0
    assert count("SizedBox(height: PillPalSpacing.lg * 2)") == 0
    assert count("SizedBox.square(dimension: 24)") == 1
    # Dividers, icons, avatars.
    assert count("Divider(height: 32)") == 1
    assert count("Divider(height: PillPalSpacing.xxxl)") == 0
    assert count("Divider(thickness: 2, indent: 8, endIndent: 8)") == 3
    assert count("VerticalDivider(width: 1)") == 1
    assert count("Icon(Icons.add, size: 20)") == 1
    assert count("Icon(Icons.add)") == 0
    assert count("IconButton(iconSize: 30, onPressed: null)") == 1
    assert count("CircleAvatar(radius: 18)") == 1
    # Radii and the deprecated aliases.
    assert count("BorderRadius.circular(20)") == 1
    assert count("Radius.circular(PillPalRadius.xl)") == 0
    assert count("BorderRadius.circular(PillPalSizes.cardRadius)") == 1
    assert count("PillPalSizes.controlRadius + PillPalSizes.sheetRadius") == 2
    # Aliases of the redesign: counted until the screens move off them.
    assert count("width: PillPalSizes.statusSquare") == 1
    assert count("PillPalSizes.statusDisc") == 0
    assert count("const InfoNote(text: t)") == 1
    assert count("final n = InfoNoteX(1);") == 0
    assert count("// InfoNote(text: t)") == 0
    assert count("TodaySummaryCard(state: state)") == 1
    assert count("const TodaySummaryCard({required this.state})") == 1
    assert count("class TodaySummaryCard extends StatelessWidget {}") == 0
    assert count("InfoNote(text: t) // ui-literal-ok: migrates in R4a") == 0
    # Colours.
    assert count("Color(0xFFFFFFFF)") == 1
    assert count("Color.fromARGB(255, 1, 2, 3)") == 1
    assert count("Color.fromRGBO(1, 2, 3, 1)") == 1
    assert count("Colors.white") == 1
    assert count("Colors.transparent") == 0
    assert count("c.withOpacity(0.5)") == 1
    assert count("c.withOpacity(o)") == 0
    assert count("c.withValues(alpha: 0.5)") == 1
    # Text.
    assert count("TextStyle(color: c)") == 0
    assert count("TextStyle(fontSize: 14)") == 1
    assert count("TextStyle(fontSize: size)") == 1
    assert count("TextStyle(fontWeight: FontWeight.w700)") == 1
    assert count("t.copyWith(fontSize: 14, fontWeight: FontWeight.w800)") == 2
    assert count("t.copyWith(color: c)") == 0
    assert count("Wrap(spacing: 8, runSpacing: 6)") == 2
    assert count("Wrap(spacing: PillPalSpacing.chips)") == 0
    # Comments and strings.
    assert count("// SizedBox(height: 12)") == 0
    assert count("/* SizedBox(height: 12) */") == 0
    assert count("final u = 'Colors.red SizedBox(height: 12)';") == 0
    assert count("final u = 'https://x'; SizedBox(height: 4)") == 1
    assert count("final u = '''a\nColors.red\n'''; Colors.red") == 1
    assert count("final u = r'it\\'; Colors.red") == 1
    assert count("final u = 'a ${SizedBox(height: 4)} b';") == 1
    assert count("final u = \"it's\"; SizedBox(height: 4)") == 1
    # Escape: a real comment on the line of the literal only.
    assert count("SizedBox(height: 12) // ui-literal-ok: QR quiet zone") == 0
    assert count("SizedBox(height: 12) // ui-literal-ok:") == 1
    assert count("final s = 'ui-literal-ok: x'; SizedBox(height: 12)") == 1
    assert count("SizedBox(height: 12) /* ui-literal-ok: why */") == 0
    assert count("// ui-literal-ok: why\nSizedBox(height: 12)") == 1
    assert count("EdgeInsets.fromLTRB(\n  8, // ui-literal-ok: why\n  4,\n  0, 0)") == 1

    stale = compare({"a.dart": 3, "b.dart": 1}, {"a.dart": 3, "b.dart": 2, "c.dart": 1})
    assert [f for f, _ in stale] == ["b.dart", "c.dart"]
    assert all("stale" in m for _, m in stale)
    assert compare({"a.dart": 4}, {"a.dart": 3})[0][0] == "a.dart"
    assert compare({"new.dart": 1}, {}) != []
    assert compare({"a.dart": 3}, {"a.dart": 3}) == []

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        features = root / FEATURES
        features.mkdir(parents=True)
        key = "app/lib/src/features/screen.dart"
        screen = features / "screen.dart"
        two = "SizedBox(height: 8);\nSizedBox(width: 4);\n"
        screen.write_text(two, encoding="utf-8")
        (features / "report_pdf.dart").write_text("SizedBox(height: 8);", encoding="utf-8")
        assert scan(root) == {key: 2}

        def run(*argv: str) -> tuple[int, str]:
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                code = main(list(argv), root)
            return code, buffer.getvalue()

        assert run("--update")[0] == 0
        assert load_baseline(root) == {key: 2}
        assert run("check") == (0, "")
        assert run() == (0, "")
        assert run("bogus")[0] == 2

        screen.write_text(two + "SizedBox(width: 5);\n", encoding="utf-8")
        code, output = run("check")
        assert code == 1 and output.count("::error") == 1, output
        assert output.startswith(f"::error file={key},title=ui-tokens::")
        assert run("--update")[0] == 1 and load_baseline(root) == {key: 2}

        screen.write_text("SizedBox(height: 8);\n", encoding="utf-8")
        code, output = run("check")
        assert code == 1 and "stale" in output and output.count("::error") == 1
        assert run("--update")[0] == 0 and load_baseline(root) == {key: 1}
        assert run("check")[0] == 0

        screen.unlink()
        code, output = run("check")
        assert code == 1 and "stale" in output and key in output
        assert run("--update")[0] == 0 and load_baseline(root) == {}
        assert run("check")[0] == 0
    print("check_ui_tokens self-test passed")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
