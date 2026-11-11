"""Guard against raw UI literals under app/lib/src/features (docs/ui-pass-plan.md, UI-1).

Screens use the tokens in app/lib/src/theme (spacing, radius, palette, text theme)
and the shared widgets in features/common. This script counts raw literals per
file. Since R8 (docs/redesign-plan.md) it is strict: any literal fails, and the
legacy ratchet file app/tool/ui_literals_baseline.json must stay `{}`; a non-empty
baseline fails `check` too, so nobody can hide a literal in it.

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

Separately, the retired aliases PillPalSizes.(card|control|sheet)Radius and
PillPalSizes.statusSquare and the widgets InfoNote( and TodaySummaryCard(
(docs/redesign-plan.md, R8) are hard failures: no baseline, no escape comment.
A number that is an operand of arithmetic on a token (`PillPalSpacing.md * 2`) is
derived from the scale and does not count. Strings are ignored. A literal is excused
by `// ui-literal-ok: <reason>` in a real comment on the line of the literal.
report_pdf.dart renders a PDF, not Flutter UI, and is not scanned.

Usage: check_ui_tokens.py [check]     fail on literals, aliases or a non-empty baseline
       check_ui_tokens.py --self-test (cases live in check_ui_tokens_selftest.py)
"""

import bisect
import json
import re
import sys
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
)
# Retired aliases of the «Забота» redesign (docs/redesign-plan.md, R8). Any use
# is a hard failure that no baseline and no `ui-literal-ok` excuses.
ALIAS_PATTERNS = (
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


def count_aliases(text: str) -> int:
    """Uses of the retired aliases (comments and strings do not count)."""
    code, _ = mask(text)
    return sum(len(p.findall(code)) for p in ALIAS_PATTERNS)


def scan_aliases(root: Path) -> dict[str, int]:
    """Per-file counts of retired aliases, keyed by repo-relative path."""
    counts: dict[str, int] = {}
    for path in sorted((root / FEATURES).rglob("*.dart")):
        n = count_aliases(path.read_text(encoding="utf-8"))
        if n:
            counts[path.relative_to(root).as_posix()] = n
    return counts


def alias_problems(root: Path) -> list[tuple[str, str]]:
    return [
        (
            file,
            f"{n} use(s) of a retired alias (PillPalSizes.statusSquare, "
            "PillPalSizes.*Radius, InfoNote, TodaySummaryCard). Use PillPalRadius, "
            "StatusDisc and PillPalBanner.",
        )
        for file, n in scan_aliases(root).items()
    ]


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


def baseline_problems(root: Path) -> list[tuple[str, str]]:
    """The legacy baseline must be empty: it may not excuse any literal."""
    path = root / BASELINE
    if not path.exists() or not json.loads(path.read_text(encoding="utf-8")):
        return []
    return [(BASELINE.as_posix(), "the literal baseline must be `{}`: fix the literals.")]


def literal_problems(root: Path) -> list[tuple[str, str]]:
    return [
        (
            file,
            f"{n} raw UI literals. Use the tokens in app/lib/src/theme (PillPalSpacing, "
            "PillPalRadius, palette, textTheme) or mark a justified case with "
            "`// ui-literal-ok: <reason>`.",
        )
        for file, n in scan(root).items()
    ]


def problems_of(root: Path) -> list[tuple[str, str]]:
    return literal_problems(root) + alias_problems(root) + baseline_problems(root)


def _report(problems: list[tuple[str, str]]) -> int:
    for file, message in problems:
        print(f"::error file={file},title=ui-tokens::{message}")
    return 1 if problems else 0


def main(argv: list[str], root: Path = ROOT) -> int:
    if argv == ["--self-test"]:
        from check_ui_tokens_selftest import self_test

        self_test()
        return 0
    if argv in ([], ["check"]):
        return _report(problems_of(root))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
