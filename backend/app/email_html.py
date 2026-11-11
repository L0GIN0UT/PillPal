"""HTML part of a mail: one column, inline styles, system fonts, no links, images or remote loads.

Layout follows the board ``docs/design/b2/B2-EmailCode.dc.html`` with system font stacks only.
Privacy: same words as the text part (``app.email_copy``), nothing medical, the code in one
element only. The brand is a CSS square and the text wordmark "PillPal". Every interpolated
value is escaped.
"""

from __future__ import annotations

from html import escape
from string import Template
from typing import NamedTuple

BG = "#F2F6F5"
CARD = "#FFFFFF"
INK = "#10201D"
MUTED = "#4D5F5B"
ACTION = "#0C6B5D"
BORDER = "#D3DEDB"
RAISED = "#E6EEEC"
FONT = "-apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
CODE_FONT_SIZE = "40px"
CODE_LETTER_SPACING = ".32em"
TABULAR = "font-variant-numeric: tabular-nums"


class HtmlBlock(NamedTuple):
    """One language: ``paragraphs`` (17px, muted) come right under the heading, then the code
    (if any), then ``ttl`` and ``tail``."""

    heading: str
    paragraphs: list[str]
    tail: str
    ttl: str | None = None


_TABLE = 'role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"'
_BODY_STYLE = (
    f"margin:0;padding:0;background:{BG};color:{INK};color-scheme: light;font-family:{FONT};"
)
_CARD_STYLE = (
    f"width:100%;max-width:560px;background:{CARD};border:1px solid {BORDER};border-radius:20px;"
)
_BRAND_TEXT = (
    f"padding-left:10px;font-size:22px;line-height:22px;font-weight:800;"
    f"letter-spacing:-.02em;color:{INK};"
)
_MARK = f"width:36px;height:36px;background:{ACTION};border-radius:10px;font-size:0;line-height:0;"
_FOOTER_STYLE = (
    f"margin:20px 0 0 0;font-size:13px;line-height:1.45;color:{MUTED};text-align:center;"
)

_PAGE = Template(
    f"""<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>$title</title>
</head>
<body style="{_BODY_STYLE}">
<table {_TABLE} style="background:{BG};">
<tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" border="0" \
style="{_CARD_STYLE}">
<tr><td style="padding:32px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0">
<tr><td width="36" height="36" style="{_MARK}">&nbsp;</td>\
<td style="{_BRAND_TEXT}">PillPal</td></tr>
</table>
$ru
<hr style="border:0;border-top:1px solid {BORDER};margin:28px 0;">
<div lang="en">
$en
</div>
</td></tr>
</table>
<p style="{_FOOTER_STYLE}">$footer_ru<br><span lang="en">$footer_en</span></p>
</td></tr>
</table>
</body>
</html>
"""
)

_HEADING = Template(
    '<h1 style="margin:28px 0 0 0;font-size:26px;line-height:1.2;font-weight:800;'
    f'letter-spacing:-.01em;color:{INK};">$text</h1>'
)
_PARAGRAPH = Template(
    f'<p style="margin:8px 0 0 0;font-size:17px;line-height:1.45;color:{MUTED};">$text</p>'
)
_CODE = Template(
    f'<p style="margin:22px 0 0 0;padding:18px 0;border-radius:16px;background:{RAISED};'
    f"text-align:center;font-family:{FONT};font-size:{CODE_FONT_SIZE};line-height:1;"
    f"font-weight:800;letter-spacing:{CODE_LETTER_SPACING};text-indent:{CODE_LETTER_SPACING};"
    f'{TABULAR};color:{INK};">$code</p>'
)
_TTL = Template(
    f'<p style="margin:16px 0 0 0;font-size:15px;line-height:1.4;font-weight:600;color:{INK};">'
    "$text</p>"
)
_TAIL = Template(
    f'<p style="margin:6px 0 0 0;font-size:15px;line-height:1.45;color:{MUTED};">$text</p>'
)


def _block(block: HtmlBlock, code: str | None) -> str:
    parts = [_HEADING.substitute(text=escape(block.heading))]
    parts.extend(_PARAGRAPH.substitute(text=escape(text)) for text in block.paragraphs)
    if code is not None:
        parts.append(_CODE.substitute(code=escape(code)))
    if block.ttl is not None:
        parts.append(_TTL.substitute(text=escape(block.ttl)))
    parts.append(_TAIL.substitute(text=escape(block.tail)))
    return "\n".join(parts)


def render_html(
    *, title: str, ru: HtmlBlock, en: HtmlBlock, footer_ru: str, footer_en: str, code: str | None
) -> str:
    """The page. All text is plain (escaped here). The code sits in the Russian block only, so
    it appears once; the English block follows the divider."""
    return _PAGE.substitute(
        title=escape(title),
        ru=_block(ru, code),
        en=_block(en, None),
        footer_ru=escape(footer_ru),
        footer_en=escape(footer_en),
    )
