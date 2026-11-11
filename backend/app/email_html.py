"""HTML part of a mail: one column, inline styles, system font, no links, images or remote loads.

Privacy: same words as the text part (``app.email_copy``), nothing medical, the code in one
element only. The brand is the text wordmark "PillPal". Every interpolated value is escaped.
"""

from __future__ import annotations

from html import escape
from string import Template

BG = "#F2F6F5"
CARD = "#FFFFFF"
INK = "#10201D"
MUTED = "#4D5F5B"
ACTION = "#0C6B5D"
BORDER = "#D3DEDB"
_FONT = "-apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
_MONO = "ui-monospace, 'SFMono-Regular', Menlo, Consolas, 'Courier New', monospace"

_TABLE = 'role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"'
_BODY_STYLE = (
    f"margin:0;padding:0;background:{BG};color:{INK};color-scheme: light;font-family:{_FONT};"
)
_CARD_STYLE = f"max-width:560px;background:{CARD};border:1px solid {BORDER};border-radius:16px;"
_BRAND_STYLE = f"padding:28px 28px 8px 28px;font-size:20px;font-weight:700;color:{ACTION};"

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
<tr><td align="center" style="padding:24px 12px;">
<table {_TABLE} style="{_CARD_STYLE}">
<tr><td style="{_BRAND_STYLE}">PillPal</td></tr>
<tr><td style="padding:8px 28px 24px 28px;">
$ru
<hr style="border:0;border-top:1px solid {BORDER};margin:24px 0;">
$en
</td></tr>
</table>
</td></tr>
</table>
</body>
</html>
"""
)

_HEADING = Template(
    f'<h1 style="margin:0 0 12px 0;font-size:18px;line-height:24px;color:{INK};">$text</h1>'
)
_CODE = Template(
    f'<p style="margin:0 0 16px 0;padding:16px;background:{BG};border:1px solid {BORDER};'
    f"border-radius:12px;text-align:center;font-family:{_MONO};font-size:32px;"
    "letter-spacing:6px;font-weight:700;font-variant-numeric: tabular-nums;"
    f'color:{ACTION};">$code</p>'
)
_PARAGRAPH = Template(
    f'<p style="margin:0 0 12px 0;font-size:15px;line-height:22px;color:{MUTED};">$text</p>'
)


def _block(heading: str, paragraphs: list[str], code: str | None) -> str:
    parts = [_HEADING.substitute(text=escape(heading))]
    if code is not None:
        parts.append(_CODE.substitute(code=escape(code)))
    parts.extend(_PARAGRAPH.substitute(text=escape(text)) for text in paragraphs)
    return "\n".join(parts)


def render_html(
    *,
    title: str,
    heading_ru: str,
    paragraphs_ru: list[str],
    heading_en: str,
    paragraphs_en: list[str],
    code: str | None = None,
) -> str:
    """The page. Headings and paragraphs are plain text (escaped here). The code sits under the
    Russian heading only, so it appears once; the English block follows the divider."""
    return _PAGE.substitute(
        title=escape(title),
        ru=_block(heading_ru, paragraphs_ru, code),
        en=_block(heading_en, paragraphs_en, None),
    )
