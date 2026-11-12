"""Self-test of check_ui_tokens.py (run: check_ui_tokens.py --self-test)."""

import contextlib
import io
import tempfile
from pathlib import Path

from check_ui_tokens import (
    BASELINE,
    FEATURES,
    count_aliases,
    count_literals,
    main,
    scan,
)

count = count_literals
NL = chr(10)
aliases = count_aliases


def _edge_insets() -> None:
    """EdgeInsets: per literal; tokens and arithmetic on tokens do not count."""
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


def _sized_box() -> None:
    """SizedBox: own top-level arguments only."""
    assert count("SizedBox(height: 12)") == 1
    assert count("SizedBox(width: 4, height: 8)") == 2
    assert count("SizedBox(height: 0)") == 0
    assert count("SizedBox(width: double.infinity, height: PillPalSpacing.lg)") == 0
    assert count("SizedBox(height: 8, child: Container(width: 3, height: 5))") == 1
    assert count("SizedBox(child: Row(children: [SizedBox(width: PillPalSpacing.sm)]))") == 0
    assert count("SizedBox(height: PillPalSpacing.lg * 2)") == 0
    assert count("SizedBox.square(dimension: 24)") == 1


def _dividers_icons() -> None:
    """Dividers, icons, avatars."""
    assert count("Divider(height: 32)") == 1
    assert count("Divider(height: PillPalSpacing.xxxl)") == 0
    assert count("Divider(thickness: 2, indent: 8, endIndent: 8)") == 3
    assert count("VerticalDivider(width: 1)") == 1
    assert count("Icon(Icons.add, size: 20)") == 1
    assert count("Icon(Icons.add)") == 0
    assert count("IconButton(iconSize: 30, onPressed: null)") == 1
    assert count("CircleAvatar(radius: 18)") == 1


def _radii() -> None:
    """Radii."""
    assert count("BorderRadius.circular(20)") == 1
    assert count("Radius.circular(PillPalRadius.xl)") == 0


def _aliases() -> None:
    """Retired aliases are hard failures of their own, not literals."""
    assert aliases("BorderRadius.circular(PillPalSizes.cardRadius)") == 1
    assert aliases("PillPalSizes.controlRadius + PillPalSizes.sheetRadius") == 2
    assert aliases("width: PillPalSizes.statusSquare") == 1
    assert aliases("PillPalSizes.statusDisc") == 0
    assert aliases("const InfoNote(text: t)") == 1
    assert aliases("final n = InfoNoteX(1);") == 0
    assert aliases("// InfoNote(text: t)") == 0
    assert aliases("final u = 'InfoNote(';") == 0
    assert aliases("TodaySummaryCard(state: state)") == 1
    assert aliases("const TodaySummaryCard({required this.state})") == 1
    assert aliases("class TodaySummaryCard extends StatelessWidget {}") == 0
    assert aliases("InfoNote(text: t) // ui-literal-ok: later") == 1
    assert count("InfoNote(text: t) PillPalSizes.statusSquare") == 0


def _colours() -> None:
    """Colours."""
    assert count("Color(0xFFFFFFFF)") == 1
    assert count("Color.fromARGB(255, 1, 2, 3)") == 1
    assert count("Color.fromRGBO(1, 2, 3, 1)") == 1
    assert count("Colors.white") == 1
    assert count("Colors.transparent") == 0
    assert count("c.withOpacity(0.5)") == 1
    assert count("c.withOpacity(o)") == 0
    assert count("c.withValues(alpha: 0.5)") == 1


def _text() -> None:
    """Text."""
    assert count("TextStyle(color: c)") == 0
    assert count("TextStyle(fontSize: 14)") == 1
    assert count("TextStyle(fontSize: size)") == 1
    assert count("TextStyle(fontWeight: FontWeight.w700)") == 1
    assert count("t.copyWith(fontSize: 14, fontWeight: FontWeight.w800)") == 2
    assert count("t.copyWith(color: c)") == 0
    assert count("Wrap(spacing: 8, runSpacing: 6)") == 2
    assert count("Wrap(spacing: PillPalSpacing.chips)") == 0


def _comments_strings() -> None:
    """Comments and strings."""
    assert count("// SizedBox(height: 12)") == 0
    assert count("/* SizedBox(height: 12) */") == 0
    assert count("final u = 'Colors.red SizedBox(height: 12)';") == 0
    assert count("final u = 'https://x'; SizedBox(height: 4)") == 1
    assert count("final u = '''a\nColors.red\n'''; Colors.red") == 1
    assert count("final u = r'it\\'; Colors.red") == 1
    assert count("final u = 'a ${SizedBox(height: 4)} b';") == 1
    assert count("final u = \"it's\"; SizedBox(height: 4)") == 1


def _motion() -> None:
    """Animation durations and curves come from PillPalMotion (docs/design.md)."""
    assert count("Duration(milliseconds: 250)") == 1
    assert count("const Duration(" + NL + "  milliseconds: 300," + NL + ")") == 1
    assert count("AnimatedContainer(duration: PillPalMotion.base)") == 0
    assert count("Duration(seconds: 30)") == 0
    assert count("Duration(minutes: 1)") == 0
    assert count("Duration(milliseconds: ms)") == 1
    assert count("curve: Curves.easeOut") == 1
    assert count("curve: Curves.linear, x: Curves.ease") == 2
    assert count("curve: PillPalMotion.standard") == 0
    assert count("final a = 'Curves.easeOut Duration(milliseconds: 5)';") == 0
    assert count("// Curves.easeOut" + NL + "final a = 1;") == 0
    # Sub-second in any argument position, across lines, nested.
    assert count("Duration(seconds: 1, milliseconds: 500)") == 1
    multi = "Duration(" + NL + "  seconds: 1," + NL + "  microseconds: 5," + NL + ")"
    assert count(multi) == 1
    assert count("Duration(microseconds: 900)") == 1
    assert count("Duration(seconds: f(x), minutes: 2)") == 0
    assert count("Duration(seconds: g(Duration(milliseconds: 5)))") == 1
    assert count("Duration(milliseconds: 5) * 2 + Duration(milliseconds: 1)") == 2
    assert count("PillPalMotion.base.inMilliseconds") == 0
    # The framework's own timing tokens and numeric curves.
    assert count("duration: Durations.medium2") == 1
    assert count("curve: Easing.emphasizedDecelerate") == 1
    assert count("duration: kThemeAnimationDuration") == 1
    assert count("kThemeAnimationDurationX") == 0
    assert count("const Cubic(0.2, 0, 0, 1)") == 1
    assert count("Cubic(.2, 0, 0, 1)") == 1
    assert count("Interval(0.5, 1)") == 1
    assert count("Interval(.5, 1, curve: PillPalMotion.standard)") == 1
    assert count("Interval(start, 1)") == 0
    assert count("Interval(PillPalMotion.fast.inMicroseconds / t, 1)") == 0
    assert count("SomeCubic(0.2)") == 0
    # The escape goes on the line of the first number of a numeric curve.
    assert count("Interval(" + NL + "  0, // ui-literal-ok: why" + NL + "  e)") == 0
    assert count("Interval( // ui-literal-ok: why" + NL + "  0," + NL + "  e)") == 1
    # Not an animation: excused on the line with the reason.
    assert count("Duration(milliseconds: 500) // ui-literal-ok: guard") == 0
    assert count("Duration(milliseconds: 500) // ui-literal-ok:") == 1


def _escape() -> None:
    """Escape: a real comment on the line of the literal only."""
    assert count("SizedBox(height: 12) // ui-literal-ok: QR quiet zone") == 0
    assert count("SizedBox(height: 12) // ui-literal-ok:") == 1
    assert count("final s = 'ui-literal-ok: x'; SizedBox(height: 12)") == 1
    assert count("SizedBox(height: 12) /* ui-literal-ok: why */") == 0
    assert count("// ui-literal-ok: why\nSizedBox(height: 12)") == 1
    assert count("EdgeInsets.fromLTRB(\n  8, // ui-literal-ok: why\n  4,\n  0, 0)") == 1


def _tree(root: Path) -> tuple[Path, Path]:
    features = root / FEATURES
    features.mkdir(parents=True)
    (root / BASELINE).parent.mkdir(parents=True, exist_ok=True)
    (root / BASELINE).write_text("{}" + NL, encoding="utf-8")
    return features, root / BASELINE


def _run(root: Path, *argv: str) -> tuple[int, str]:
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        code = main(list(argv), root)
    return code, buffer.getvalue()


def _check_literals(root: Path, features: Path) -> None:
    key = "app/lib/src/features/screen.dart"
    screen = features / "screen.dart"
    screen.write_text("SizedBox(height: PillPalSpacing.lg);" + NL, encoding="utf-8")
    (features / "report_pdf.dart").write_text("SizedBox(height: 8);", encoding="utf-8")
    assert scan(root) == {} and _run(root, "check") == (0, "")
    assert _run(root) == (0, "") and _run(root, "bogus")[0] == 2
    two = "SizedBox(height: 8);" + NL + "SizedBox(width: 4);" + NL
    screen.write_text(two, encoding="utf-8")
    code, output = _run(root, "check")
    assert code == 1 and output.count("::error") == 1, output
    assert output.startswith(f"::error file={key},title=ui-tokens::2 raw")
    excused = "SizedBox(height: 8); // ui-literal-ok: why" + NL
    screen.write_text(excused, encoding="utf-8")
    assert _run(root, "check")[0] == 0
    screen.unlink()


def _check_aliases_and_baseline(root: Path, features: Path, baseline: Path) -> None:
    screen = features / "screen.dart"
    # A retired alias fails, even with an escape comment.
    text = "const InfoNote(text: t); // ui-literal-ok: x" + NL
    screen.write_text(text, encoding="utf-8")
    code, output = _run(root, "check")
    assert code == 1 and "retired alias" in output and output.count("::error") == 1
    screen.unlink()
    # A non-empty baseline fails on its own.
    baseline.write_text('{"app/lib/src/features/x.dart": 1}' + NL, encoding="utf-8")
    code, output = _run(root, "check")
    assert code == 1 and "must be `{}`" in output, output
    baseline.write_text("{}" + NL, encoding="utf-8")
    assert _run(root, "check")[0] == 0


def _check_tree() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        features, baseline = _tree(root)
        _check_literals(root, features)
        _check_aliases_and_baseline(root, features, baseline)


def self_test() -> None:
    for case in (
        _edge_insets,
        _sized_box,
        _dividers_icons,
        _radii,
        _aliases,
        _colours,
        _text,
        _motion,
        _comments_strings,
        _escape,
        _check_tree,
    ):
        case()
    print("check_ui_tokens self-test passed")
