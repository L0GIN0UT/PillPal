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
| `ru/consent-personal-data.md` | Consent to process ordinary personal data; **no matching in-app kind yet** (see Q2) | DRAFT |
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
2. Privacy e-mail, support address, person responsible for processing (art. 22.1).
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
13. Countries of Google FCM, Apple APNs and Google ML Kit and the cross-border answer (Q1).
14. Price, refund procedure, support procedure for moving a purchase, promo code terms.
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
7. Cross-border transfer (art. 12) for FCM and APNs tokens and for ML Kit usage metrics from RU;
   push metadata visible to Google, Apple and VK (a `missed` push at a given time).
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
15. **Q1** Whether there are truly no cross-border transfers (item 7) — the brief asked to state
    "none", the drafts leave it as a placeholder until counsel answers.
16. **Q2** Whether a separate consent under art. 9 is needed for ordinary personal data (art. 9(1) as
    in force since 01.09.2025: consent separate from other documents), or contract (art. 6(1)(5))
    is enough; if needed, whether to reword the `privacy` tick or add a new consent kind.
17. Whether an in-app checkbox counts as written form for health data (art. 9(4), art. 10; simple
    electronic signature under 63-FZ), and which subject details the consent must contain.
18. Legal basis for managed profiles of children (legal representative) and of adults/elderly
    people (own consent or guardianship); pets are not personal data.
19. The per-region third-party list inside the policy (now in `processors.md`, referenced).
20. Separate GDPR texts for the EU (templates here) vs one text per kind across regions.
21. Whether erasure must cover Sentry events (they hold no message or body, but may hold ids).
22. Ad SDK and advertising identifiers: consent (RU and ePrivacy), and whether the ad network is a
    processor or a separate operator.
23. Minimum age 18 without an age check; ML Kit telemetry as a third party at all.

## How the texts map to in-app consent versions (ADR 0016 §1)

- In-app kinds: `health_data` ↔ `consent-health-data.md`; `terms` ↔ `terms-of-use.md`; `privacy` ↔
  `privacy-policy.md` (today an acknowledgement tick); `catalog_contribution` ↔ the per-link checkbox
  of ADR 0015 §4 (`GTIN_LINK_CONSENT_VERSIONS`). `consent-personal-data.md` has no kind yet (Q2).
- Versions are per region (`CONSENT_VERSIONS_HEALTH_DATA`, `_TERMS`, `_PRIVACY`, default `[1]`); the
  current version is the last list entry. Version 1 is the placeholder stub dated 2026-11-01 in
  `app/lib/src/features/consent/consent_documents.dart` and the `consentTextBody*` ARB strings.
- **Any change of a text means a new version, never an edit of an existing one.** A translation
  does not need a new version. Adopting these drafts after review is therefore version 2: set
  `CONSENT_VERSIONS_*=[1,2]` in the region, update the app's version table and texts in the same
  release; accounts with version 1 then see the blocking re-consent screen (ADR 0016 §5).
- Each document's header carries its version and effective date; keep them in sync with the app.
