# Draft Roskomnadzor notification on personal data processing

> **Courtesy translation** of `docs/legal/ru/rkn-notification-draft.md`; the Russian text
> prevails. **DRAFT, not legal advice.** Fields for the form at pd.rkn.gov.ru under art. 22(3)
> 152-FZ, filled per purpose.

| # | Field (art. 22(3)) | Value |
|---|---|---|
| 1 | Operator name, address | «Пример Медтех» LLC (PLACEHOLDER), INN 0000000000, OGRN 0000000000000, `[FILL IN: registered address]` |
| 2 | Purposes | see below |
| 3 | Data categories | see below; special category: **health** |
| 4 | Data subjects | app users (18+); people in managed profiles (incl. minors); relatives with access |
| 5 | Legal basis | art. 6(1)(5) and (7), art. 10(2)(1) 152-FZ; art. 18.1; user agreement; `[FILL IN]` |
| 6 | Actions, method | collection, recording, systematisation, accumulation, storage, clarification, retrieval, use, transfer (provision, access), blocking, deletion, destruction; automated, over the Internet |
| 7 | Measures (art. 18.1, 19), encryption | TLS; Argon2id and token hashing; AES-256-GCM for exports and provider tokens; access control; logs without medical data; `[FILL IN: certified crypto tools, protection level, threat model]` |
| 7.1 | Person responsible | `[FILL IN: name, phone, e-mail, address]` |
| 8 | Start date | `[FILL IN: RU launch date]` |
| 9 | End term or condition | liquidation or service shutdown; per subject: account deletion (destruction within 30 days) |
| 10 | Cross-border transfer | `[FILL IN: counsel's conclusion on the flows: Google FCM and Apple APNs (token, opaque ids, event type incl. a missed dose), Firebase SDK on the device (installation id, IP), Google ML Kit (scanner metrics from the device), App Store (purchase, appAccountToken); countries (US?) and a separate art. 12 notice]` |
| 10.1 | Database location (art. 18(5)) | `[FILL IN: provider, Russian city]`, data centre address `[FILL IN]` |
| 11 | Security per Government requirements (Resolution 1119) | `[FILL IN: protection level, threat type]` |

## Purposes, categories and bases

| Purpose | Data | Subjects | Basis |
|---|---|---|---|
| Registration, sign-in, account | e-mail, password hash, region, language, VK ID / Yandex ID subject | users | art. 6(1)(5) |
| Profiles and medication data, sync | profile name, time zone; **health data**: medications, schedules, marks, notes | users, managed persons | art. 10(2)(1) (written consent) |
| Relatives' access, missed-dose alerts | grants, invites, private notes about relatives, push tokens, last sync hour; health data at the chosen level | users, managed persons, relatives | art. 10(2)(1); art. 6(1)(5) |
| Consent records | kind, version, accepted/withdrawn time | users | art. 6(1)(5) |
| Purchases and rights | store, product, purchase id, dates, promo codes | users | art. 6(1)(5) |
| Security and operations | install id, sessions, logs, IP hash in counters, error reports | users | art. 6(1)(5) (sessions), (7) (logs, security) |
