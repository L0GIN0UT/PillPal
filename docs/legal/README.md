# PillPal legal documents — working drafts

> **Status: DRAFT. Not legal advice.** Every document here must be reviewed and approved by a
> qualified lawyer before production. The operator is a fictional placeholder
> («ООО «Пример Медтех» (ЗАГЛУШКА)», ИНН 0000000000, ОГРН 0000000000000,
> privacy@example.invalid); it does not refer to any real company.

The texts describe only what the code does today (ADRs 0005–0010, 0015–0018,
`docs/spec/export.md`, `backend/README.md`, `backend/app/services/personal_data.py`, the in-app
consent stubs in `app/lib/l10n/app_*.arb`). Features that are built but switched off (payments,
OAuth, ads, catalog contributions, data export) are described as "once enabled" or "after the
app update". RU is the primary language; `en/` holds courtesy translations.

## Files

| File | What it is | Status |
|---|---|---|
| `ru/privacy-policy.md` | Policy on personal data processing (152-FZ art. 18.1): operator, purposes and categories, legal grounds, localisation, transfers, processors, retention, rights, cookies/analytics/ads, relatives' privacy levels, managed profiles | DRAFT |
| `ru/consent-health-data.md` | Consent to process health data (152-FZ art. 9(4), art. 10(2)(1)); in-app kind `health_data` | DRAFT |
| `ru/consent-personal-data.md` | Consent to process ordinary personal data; **unused fallback** — the policy relies on art. 6(1)(5) and (7); kept in case counsel requires it; no matching in-app kind (Q2) | DRAFT, UNUSED |
| `ru/terms-of-use.md` | User agreement with the medical disclaimer; in-app kind `terms` | DRAFT |
| `ru/processors.md` | Processors and third parties per region, data and location | DRAFT |
| `ru/rkn-notification-draft.md` | Fields for the Roskomnadzor notification (art. 22(3)) | DRAFT |
| `eu/privacy-notice.md` | GDPR Art. 13 notice — **Шаблон: запуск в ЕС позже** | TEMPLATE |
| `eu/consent-health-data.md` | GDPR Art. 9(2)(a) explicit consent — **Шаблон: запуск в ЕС позже** | TEMPLATE |
| `en/*.md` | Courtesy translations of the six RU documents; the Russian text prevails | DRAFT |

## Values to fill in (`[ЗАПОЛНИТЬ: …]` / `[FILL IN: …]`)

Operator and contacts
1. Full name, INN, OGRN, registered address of the operator (the TZ says publishing is by a private
   person for now — decide the operator's legal form first).
2. Privacy e-mail, support address (terms of use, section 9: claims address and court), person
   responsible for processing (art. 22.1) with phone and address (RKN draft, fields 5 and 7.1:
   other legal bases such as the charter, and the responsible person's phone, e-mail, address).
3. RKN registry number (after the notification), start date of processing in RU.
4. Where the documents are published (About screen, web address).

Infrastructure
5. RU hosting: provider and Russian city, data centre address; EU hosting provider and city.
6. Where the self-hosted Sentry runs (same hosting?).
7. SMTP provider and its country.
8. Catalog service hosting.
9. Retention of logs, of Sentry events and of backups (staging: at most 14 days).
10. Security: disk encryption, protection level of the ИСПДн (Resolution 1119), threat model,
    certified crypto tools, incident response and the art. 21(3.1) breach notice.

Third parties and money
11. Ad network («[ЗАПОЛНИТЬ: рекламная сеть, по умолчанию Яндекс Реклама]»), the data its SDK gets
    and the consent it needs.
12. AppMetrica: event list, if it is ever added.
13. Countries of Google FCM, Apple APNs, the Firebase SDK on the device, Google ML Kit and the App
    Store, and the cross-border answer (Q1); `processors.md` row "App Store, RuStore" (location).
14. Price, refund procedure, support procedure for moving a purchase (owner and counsel decision),
    promo code terms.
14a. `consent-personal-data.md` item 8: which art. 6(1)(2–11) grounds allow processing without
    consent (e.g. purchase records), if that fallback is ever used.
15. Territory of the licence, court/jurisdiction.

Consent mechanics
16. Version numbers and effective dates of `health_data`, `terms`, `privacy` (see "Versions").
17. Subject identification in the consent (name, address, ID document are not collected).
18. Basis and form of consent for managed profiles; age check (none in the app today).
19. EU: controller, DPO, Art. 27 representative, lead supervisory authority, transfer mechanism.

## Open legal questions

From the plans and ADRs (`docs/phase3-plan.md`, `docs/phase4-plan.md` "Legal review", ADR 0016 §10):
1. 30 days of blocked storage after a deletion request (consent withdrawal) only for restore; must
   an "erase immediately" option be offered too; must the user be told about destruction?
2. Consent texts and versions; whether one `terms`/`privacy` screen with a separate health-data
   tick satisfies «отдельным документом» (TZ §5).
3. Withdrawal of health-data consent implemented as account deletion (RU art. 21(5); EU Art. 7(3)-(4)).
4. Erasing consent records with the account, with no retained proof (Q4).
5. Processing of already-held data while the re-consent gate is open (Q3).
6. Export exclusions (`sync_changes`, `push_outbox`, `missed_dose_alerts`, `email_codes`) and the
   D1 heir rule; 1-hour cooldown and single 24-hour download as adequate access (art. 14, GDPR 15/20);
   the 10-working-day answer; GDPR Art. 15 supplementary information.
7. Cross-border transfer (art. 12) from RU for: FCM and APNs push (device token, opaque ids, event
   type — `push_outbox` is classified medical metadata, so a `missed` push at a given time is
   visible to Google, Apple and VK); Firebase SDK traffic from the device (installation id, IP);
   ML Kit scanner metrics from the device; App Store purchases (`appAccountToken`, the purchase).
8. EU to US transfers to Apple and Google (sign-in, purchases, push): DPF or SCC.
9. Retention of purchase records against the accounting duty after erasure.
10. Owner's last sync hour shown to relatives; the invite disclosure screen and `disclosure_version`
    as the record of what was disclosed.
11. Backups vs erasure (staging keeps dumps up to 14 days; production rule undecided).
12. Catalog: ЕСКЛП/ГРЛС reuse, source attributions, catalog accuracy disclaimer, liability for
    consensus links, Честный знак scanning, contribution consent wording («Анонимно»), whether
    counts are anonymous data.
13. Medical-device classification risk of the overlap hint and "same composition" prompt.
14. Promo and ad-removal terms.

Added for these drafts:
15. **Q1** How to qualify the flows of item 7 (FCM, APNs, Firebase SDK, ML Kit, App Store). The
    drafts state only that stored data stays in Russia and leave the art. 12 qualification, the
    countries and the RKN notice as placeholders.
16. **Q2** Whether a separate consent under art. 9 is needed for ordinary personal data (art. 9(1) as
    in force since 01.09.2025: consent separate from other documents), or contract (art. 6(1)(5))
    is enough; if needed, whether to reword the `privacy` tick or add a new consent kind.
17. Whether an in-app checkbox counts as written form for health data (art. 9(4), art. 10; simple
    electronic signature under 63-FZ), and which subject details the consent must contain.
18. Legal basis for managed profiles of children (legal representative) and of adults/elderly
    people (own consent or guardianship); pets are not personal data.
19. The per-region third-party list inside the policy (now in `processors.md`, referenced).
20. Separate GDPR texts for the EU (templates here) vs one text per kind across regions.
21. Whether erasure must cover Sentry events (no message or body, but the request path without the
    query, the user-agent, x-request-id and ids).
22. Ad SDK and advertising identifiers: consent (RU and ePrivacy), and whether the ad network is a
    processor or a separate operator. A dedicated `ads` or `analytics` consent kind (a code change)
    will be needed once an ad SDK or analytics appears.
23. Minimum age 18 without an age check; ML Kit telemetry as a third party at all.
24. iOS backups: the local database is currently not excluded from iCloud/Finder backups (disclosed
    in the policy; a code fix is planned). Whether this is acceptable until the fix.
25. Purchase transfer: during pending deletion only via support; after erasure a new account can
    claim the purchase. Owner and counsel to confirm the rule and the terms wording.
26. Legal basis for showing the inviter's masked e-mail (ADR 0020 section 3) to whoever holds an open
    invite code the inviter chose to show or send (consent through the act of sharing, contract, or
    legitimate interest in recognising the inviter), and whether the masking rule is adequate.
27. Excluding a private note about a relative (ADR 0020 section 4) from the export of the person it
    is about: it is the author's free text, but it concerns the subject (art. 14, GDPR Art. 15).

## Known inaccuracies in the in-app stubs (consent version 1)

The in-app health-data stub (`consentTextBodyHealth`, RU and EN) says that (1) notifications about
missed doses go to "you" — the server never alerts the owner of their own profile, only relatives,
guardians and the owner of a managed profile with co-guardians; and (2) reports are made on the
server — PDF reports are made on the device. Both are fixed by adopting the reviewed texts as
consent version 2 (below).

## How the texts map to in-app consent versions (ADR 0016 §1)

- In-app kinds: `health_data` ↔ `consent-health-data.md`; `terms` ↔ `terms-of-use.md`; `privacy` ↔
  `privacy-policy.md` (today an acknowledgement tick); `catalog_contribution` ↔ the per-link checkbox
  of ADR 0015 §4 (`GTIN_LINK_CONSENT_VERSIONS`); withdrawing it (once enabled) does not delete the
  account, and links already published stay. `consent-personal-data.md` has no kind (unused
  fallback, Q2).
- The health-data tick is given at registration: it travels with `POST /v1/auth/register` and is
  recorded with source `registration`; the e-mail is verified with a code afterwards. Existing
  accounts (version bump, restore after a deletion request) record it with source `in_app`.
- Versions are per region (`CONSENT_VERSIONS_HEALTH_DATA`, `_TERMS`, `_PRIVACY`, default `[1]`); the
  current version is the last list entry. Version 1 is the placeholder stub dated 2026-11-01 in
  `app/lib/src/features/consent/consent_documents.dart` and the `consentTextBody*` ARB strings.
- **Any change of a text means a new version, never an edit of an existing one.** A translation
  does not need a new version. Adopting these drafts after review is therefore version 2: set
  `CONSENT_VERSIONS_*=[1,2]` in the region, update the app's version table and texts in the same
  release; accounts with version 1 then see the blocking re-consent screen (ADR 0016 §5).
- Each document's header carries its version and effective date; keep them in sync with the app.
