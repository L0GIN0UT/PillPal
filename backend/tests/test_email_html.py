"""HTML mail part: inert (no links, images, style blocks), light, escaped, no medical wording."""

from __future__ import annotations

import re
from datetime import UTC, datetime
from html.parser import HTMLParser

import pytest

from app import email_copy, email_html
from app.email import EmailKind
from app.email_templates import RenderedMail, render, render_mail

CODE = "482913"
ERASE_AFTER = datetime(2026, 11, 16, 8, 30, tzinfo=UTC)
WHEN = "2026-11-16 08:30 UTC"
CODE_KINDS: tuple[EmailKind, ...] = (
    "verify_email",
    "password_reset",
    "restore_account",
    "password_change",
)
NOTICE_KINDS: tuple[EmailKind, ...] = (
    "account_exists",
    "deletion_requested",
    "account_restored",
    "account_pending_deletion",
    "export_requested",
    "oauth_not_linked",
    "identity_linked",
    "identity_unlinked",
    "password_changed",
)
ALL_KINDS = (*CODE_KINDS, *NOTICE_KINDS)
FORBIDDEN_MARKUP = ("<a", "<img", "<script", "<style", "<link", "src=", "href=", "url(")
MEDICAL = (
    "лекарств",
    "препарат",
    "доз",
    "приём",
    "прием",
    "таблет",
    "расписан",
    "medication",
    "dose",
    "pill",
    "schedule",
)


class _Page(HTMLParser):
    """Visible text nodes with the attributes of the element each one sits in."""

    def __init__(self) -> None:
        super().__init__()
        self.texts: list[tuple[str, dict[str, str]]] = []
        self._stack: list[dict[str, str]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag not in ("meta", "hr"):  # void elements have no end tag
            self._stack.append({k: v or "" for k, v in attrs})

    def handle_endtag(self, tag: str) -> None:
        if self._stack:
            self._stack.pop()

    def handle_data(self, data: str) -> None:
        if data.strip():
            self.texts.append((data.strip(), self._stack[-1] if self._stack else {}))


def _mail(kind: EmailKind, provider: str = "google") -> RenderedMail:
    return render_mail(
        kind,
        code=CODE if kind in CODE_KINDS else None,
        ttl_minutes=15,
        erase_after=ERASE_AFTER,
        provider=provider if kind.startswith("identity") else None,
    )


def _page(html: str) -> _Page:
    page = _Page()
    page.feed(html)
    return page


def _visible(html: str) -> str:
    return " ".join(text for text, _ in _page(html).texts)


@pytest.mark.parametrize("kind", ALL_KINDS)
def test_html_is_inert(kind: EmailKind) -> None:
    lowered = _mail(kind).html.lower()
    for marker in (*FORBIDDEN_MARKUP, "http", "://"):
        assert marker not in lowered


@pytest.mark.parametrize("kind", ALL_KINDS)
def test_html_is_light_utf8_and_branded(kind: EmailKind) -> None:
    html = _mail(kind).html
    assert '<html lang="ru">' in html
    assert '<meta charset="utf-8">' in html
    assert "color-scheme: light" in html
    for colour in ("#F2F6F5", "#FFFFFF", "#10201D", "#0C6B5D"):
        assert colour in html
    assert "PillPal" in _visible(html)
    assert "Забота" not in html
    assert 'role="presentation"' in html
    assert "max-width:560px" in html
    assert 'width="560"' in html  # Outlook ignores max-width
    assert '<div lang="en">' in html


@pytest.mark.parametrize("kind", CODE_KINDS)
def test_code_appears_once_in_a_monospace_tabular_element(kind: EmailKind) -> None:
    html = _mail(kind).html
    assert html.count(CODE) == 1
    (attrs,) = [a for text, a in _page(html).texts if text == CODE]
    style = attrs["style"]
    assert email_html.TABULAR in style
    assert f"font-size:{email_html.CODE_FONT_SIZE}" in style
    spacing = email_html.CODE_LETTER_SPACING
    assert f"letter-spacing:{spacing}" in style
    assert f"text-indent:{spacing}" in style  # keeps the digits centred


@pytest.mark.parametrize("kind", CODE_KINDS)
def test_code_mail_says_ttl_and_ignore_in_both_languages(kind: EmailKind) -> None:
    visible = _visible(_mail(kind).html)
    assert "Код действует 15 мин." in visible
    assert "It is valid for 15 minutes." in visible
    assert email_copy.IGNORE_RU in visible
    assert email_copy.IGNORE_EN in visible


@pytest.mark.parametrize("kind", NOTICE_KINDS)
def test_notices_have_no_digits_except_the_date(kind: EmailKind) -> None:
    visible = _visible(_mail(kind).html).replace(WHEN, "")
    assert not any(ch.isdigit() for ch in visible)


@pytest.mark.parametrize("kind", ALL_KINDS)
def test_footer_is_outside_the_card_in_both_languages(kind: EmailKind) -> None:
    html = _mail(kind).html
    before = html[: html.index(email_copy.FOOTER_RU)]
    assert before.count("<table") - before.count("</table>") == 1  # only the outer table is open
    assert email_copy.FOOTER_EN in _visible(html)
    assert "Регион" not in html


@pytest.mark.parametrize("kind", ["deletion_requested", "account_pending_deletion"])
def test_deletion_notices_show_the_date(kind: EmailKind) -> None:
    assert WHEN in _visible(_mail(kind).html)


@pytest.mark.parametrize("kind", ALL_KINDS)
def test_no_medical_words(kind: EmailKind) -> None:
    visible = _visible(_mail(kind).html).replace("PillPal", "").lower()
    for word in MEDICAL:
        assert word not in visible


@pytest.mark.parametrize("kind", ALL_KINDS)
def test_html_carries_the_same_sentences_as_the_text(kind: EmailKind) -> None:
    mail = _mail(kind)
    visible = re.sub(r"\s+", " ", _visible(mail.html))
    for sentence in re.split(r"(?<=[.])\s+|\n+", mail.text.replace("\n\n--\n\n", "\n")):
        if sentence and CODE not in sentence:
            assert sentence in visible


@pytest.mark.parametrize("kind", ALL_KINDS)
def test_render_is_the_text_part_of_render_mail(kind: EmailKind) -> None:
    mail = _mail(kind)
    plain = render(
        kind,
        code=CODE if kind in CODE_KINDS else None,
        ttl_minutes=15,
        erase_after=ERASE_AFTER,
        provider="google" if kind.startswith("identity") else None,
    )
    assert plain == (mail.subject, mail.text)


def test_interpolated_values_are_escaped(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(email_copy.PROVIDER_NAMES, "evil", '<b>x</b> & "y"')
    html = _mail("identity_linked", "evil").html
    assert "<b>" not in html
    assert "&lt;b&gt;x&lt;/b&gt; &amp; &quot;y&quot;" in html
