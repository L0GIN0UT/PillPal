# Processors and third parties per region

> **Courtesy translation** of `docs/legal/ru/processors.md`; the Russian text prevails.
> **DRAFT, not legal advice.** Sources: ADR 0008 §8, ADR 0017 §11, ADR 0018 §6 and §8, ADR
> 0013/0015, `backend/README.md`. The EU region is a template: EU launch later.

No party below receives medical data except the region's hosting provider (storage). Each region
has its own accounts, keys and settings with every service; no store is shared across regions.

## RU region

| Party | Purpose | Data | Where | Role |
|---|---|---|---|---|
| `[FILL IN: provider, Russian city]` | server, PostgreSQL, Redis, backups | all RU account data incl. health data | Russia | processor (art. 6(3)) |
| Self-hosted Sentry | error reports | exception type, stack frames; no messages, bodies, IPs, medical data | Russia, `[FILL IN]` | operator's own |
| `[FILL IN]` (SMTP) | service e-mails | e-mail, language, mail text; no medical data | `[FILL IN]` | processor |
| Google (FCM) | Android push | device token, opaque ids, event type | `[FILL IN: US? cross-border question]` | recipient |
| Apple (APNs) | iOS push | device token, opaque ids, text key | `[FILL IN: US? cross-border question]` | recipient |
| VK (RuStore Push) | Android push without Google services | token, opaque ids | Russia | recipient |
| Google ML Kit (in the app, Android) | on-device barcode recognition | usage metrics; no images or codes | `[FILL IN]` | recipient (legal question) |
| VK ID, Yandex ID | sign-in (Android), **once enabled** | provider id, e-mail if any, exchange tokens | Russia | recipient / source |
| App Store (Apple), RuStore | ad-removal purchase, **once payments are enabled** | payment data stays with the store; operator gets product, purchase id, dates; Apple gets the account pseudonym `appAccountToken` | `[FILL IN]` | independent |
| `[FILL IN: ad network, Yandex Ads by default]` | banners on Settings and About, **not used in the current version** | `[FILL IN]`; no medical data | `[FILL IN]` | `[FILL IN]` |
| PillPal medicine catalogue (operator's service) | search, cards, barcode lookup | query or GTIN with no account link; IP not logged | `[FILL IN]` | operator's own |
| Analytics (AppMetrica) | **not used**; this list is updated if added | — | — | — |

Not used: sentry.io or any cloud error service (startup refused); Apple and Google sign-in in RU
(startup refused); Google Play Billing in RU.

## EU region (template: EU launch later)

| Party | Purpose | Data | Where |
|---|---|---|---|
| `[FILL IN: hosting provider, EU city]` | hosting | all EU account data | EU |
| Self-hosted Sentry | errors | as RU | EU |
| `[FILL IN]` (SMTP) | e-mails | as RU | `[FILL IN]` |
| Google (FCM), Apple (APNs) | push | as RU | `[FILL IN: SCC / DPF]` |
| Apple (Sign in with Apple, iOS), Google Sign-In (Android, iOS) | sign-in, once enabled | provider id, e-mail (Apple may relay); Apple refresh token stored encrypted to revoke it on deletion | `[FILL IN]` |
| App Store, Google Play | purchases, once enabled | as RU | `[FILL IN]` |
| Google ML Kit | as RU | as RU | `[FILL IN]` |

Not used in EU: RuStore Push, RuStore Pay, VK ID, Yandex ID (startup refused).
