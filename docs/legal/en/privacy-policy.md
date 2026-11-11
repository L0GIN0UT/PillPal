# PillPal Personal Data Processing Policy (RU region)

> **Courtesy translation** of `docs/legal/ru/privacy-policy.md`; the Russian text prevails.
> **DRAFT, not legal advice**; must be reviewed by a qualified lawyer. Operator details are
> placeholders; open values are marked `[FILL IN: …]`. Version `[FILL IN]` · effective `[FILL IN]`.

## 1. General

1.1. This Policy describes how the operator processes and protects the personal data of users of
the PillPal app and its server in the RU data region, under art. 18.1(2) of Federal Law No. 152-FZ
of 27.07.2006 "On Personal Data" (152-FZ). Published at `[FILL IN]`.

1.2. PillPal reminds you and your relatives to take medications. Reminders are created and fire on
the device without the server. The server synchronises devices, gives relatives access, detects
missed doses and sends alerts about them.

1.3. This Policy covers RU accounts. The EU region has its own notice. No data moves between
regions, and users of different regions cannot be linked.

## 2. Operator

**«Пример Медтех» LLC (PLACEHOLDER)** `[FILL IN: full name]`; INN 0000000000, OGRN 0000000000000
`[FILL IN]`; address `[FILL IN: registered address]`; privacy contact privacy@example.invalid
`[FILL IN]`; person responsible for processing (art. 22.1) `[FILL IN]`; RKN registry number
`[FILL IN]`.

## 3. Terms

**Account** — registered by e-mail (or, once enabled, VK ID or Yandex ID). **Profile** — one
person's medications and schedules; every account has its own; a **managed profile** belongs to
someone who does not use the app (a child, an older relative) or a pet and is kept by a guardian.
**Relative** — another user of the same region given access by invite. **Health data** —
medications, schedules, dose marks, stock and misses; a special category (art. 10 152-FZ).

## 4. Data and purposes

Built from the server's table registry (`backend/app/services/personal_data.py`).

| # | Purpose | Data | Basis |
|---|---|---|---|
| 1 | Account, sign-in, recovery | e-mail; password hash (Argon2id); region; language; verification time; created and password-change times; one-time codes (hashed, 15 min); with VK ID / Yandex ID: provider subject id and e-mail at linking | art. 6(1)(5) contract and consent (art. 6(1)(1)) |
| 2 | Profiles | profile name, time zone, kind, missed-alert settings | same |
| 3 | Health data storage, sync, missed-dose detection | medications (name, form, strength, notes, stock, time-zone mode, privacy level, catalogue link, GTIN, manual composition); schedules (rule, times, doses); dose marks (taken, skipped, snoozed, undo), times and notes; sync journal; missed-dose records (72 h) | **separate written consent** (art. 10(2)(1), art. 9(4)) |
| 4 | Relatives and guardians | grants (role, missed alerts on/off, disclosure version), invites (hash only), owner's last sync time to the hour | health consent and agreement |
| 5 | Alerts to relatives | push token and provider (FCM, APNs, RuStore); push queue (opaque ids and event type) | same |
| 6 | Session and device security | install id, first and last seen; sessions (device, times, expiry, revocation; token hash only) | art. 6(1)(5) and consent |
| 7 | Consent records | kind, version, source, accepted and withdrawn times | art. 6(1)(2) (art. 9(3) burden of proof) |
| 8 | Purchases and ad removal | store, product, store purchase id, environment, dates; "no ads" / "no limits" rights, source and validity; redeemed promo code ids (never the code); operator audit rows | art. 6(1)(5) |
| 9 | Data export on request | request metadata and the encrypted archive (up to 24 h) | art. 14 |
| 10 | Operations and security | logs: request id, route template, status, latency, opaque ids, error codes; rate-limit counters keyed by a hash of IP and account (short TTL); error reports (exception type and stack) | art. 6(1)(5) and consent |

We do **not** collect full names (other than how you name a profile), ID documents, phone
numbers, location, contacts or photos. Camera images for scanning stay on the device; only the
GTIN is used, serial, batch and expiry are discarded. **Health data never goes into** logs, error
reports, analytics, push texts, e-mail subjects or bodies, or URLs.

**On the device:** a local copy of the account data; sign-in tokens in the system keystore; Android
backup disabled; local data wiped on sign-out and account deletion; PDF reports made on the device.

**Medicine catalogue:** searches and barcode lookups go to the catalogue service without any link to
the account (no sign-in token, no account device id; a separate random install id rotated at
sign-out, deletion and every 30 days), in request bodies, not URLs; the catalogue logs no IPs or
queries; requests only on user action. Anonymous "barcode — product" confirmation counts are
shared only with a per-medication opt-in and are **switched off** in the current version.

## 5. Health data

Processed only with the separate consent (`consent-health-data.md`), given by its own tick at
registration and recorded with version and time. Withdrawal is an **account deletion** (section 9).
If the text changes, the app asks again; until the new version is accepted, the app does not sync
medications, schedules or marks; local reminders keep working.

## 6. Relatives and privacy levels

Access is by link or QR and starts only after the invitee confirms; the app first shows what the
relative will see, and that disclosure version is stored with the grant. Roles: **viewer**,
**editor** (edits *shared* medications only; cannot mark doses or delete), **guardian** (full
access to a managed profile). Enforced on the server on every path (sync, alerts, relative's
report data):

| Level | What viewers and editors see |
|---|---|
| shared | name, form, strength, schedule and doses, dose marks — without mark notes or device id |
| anonymous | times, course dates and marks only |
| hidden | nothing |

Guardians see all medications of a managed profile. Relatives also see the profile name and time
zone and, for the owner's own profile, the last sync hour. With missed alerts on, the server
checks whether a dose was marked and, after the set delay (30 min by default), sends a push with
opaque ids only; for *anonymous* medications the text is generic, for *hidden* none is sent. The
owner can revoke and the relative can leave at any time; the relative's device then drops the data.

## 7. Managed profiles

**By creating a managed profile for a person, the user confirms the right to enter their data,
including health data:** as their legal representative or with their consent, and is responsible
for that basis and for accuracy. `[FILL IN: how the consent is obtained — open question]`. When the
owner deletes the account, the profile passes to the earliest active co-guardian as a read-only
archive for up to 365 days, or is erased with the owner if there is none; notes stay with
co-guardians.

## 8. Location and transfers

**Localisation (art. 18(5)).** Recording, systematisation, accumulation, storage, clarification
and retrieval use databases in the Russian Federation: `[FILL IN: provider, Russian city]`. Error
reports go to a self-hosted Sentry in Russia; sentry.io is refused at startup.

**Cross-border.** The operator does not transfer stored personal or health data outside Russia.
`[FILL IN after legal review: FCM, APNs and ML Kit receive device tokens, opaque ids and usage
metrics (no medical data); if this is a cross-border transfer (art. 12), list countries here.]`
Processors: `processors.md`. Data is never sold or used for advertising.

## 9. Retention and destruction

| Data | Period |
|---|---|
| Account and all its data | while it exists; after a deletion request up to 30 days blocked, then destroyed |
| Managed profile passed to a co-guardian | archive up to 365 days |
| E-mail codes | valid 15 min |
| Sessions | up to 30 days |
| Invites | valid 7 days; record deleted 30 days later |
| Missed-dose records | 72 h |
| Push queue | sent 24 h, any at most 7 days |
| Push tokens without delivery | 270 days |
| Export archive | 24 h or first download; metadata 7 days |
| Operator audit | 365 days; user reference removed on erasure |
| Logs / Sentry / backups | `[FILL IN]` / `[FILL IN]` / `[FILL IN]` (staging: max 14 days) |

**Deletion**: Settings → Delete account, confirmed with the password (or provider sign-in). At
once: sessions end, relatives lose access, detection and push stop, invites are revoked, exports
are deleted, the requesting device wipes its data. Within the period shown (max 30 days) the
account can be restored with the password and a mailed code; then it is destroyed automatically,
with no proof of consent kept.

## 10. Your rights

Information and access (art. 14); clarification, blocking or destruction; withdrawal of consent;
complaint to Roskomnadzor or a court (art. 17). Edit data in the app; **export** in the app (JSON,
password, once per hour, one download within 24 h) — *available after the app update*, until then
by e-mail; deletion in the app; requests to privacy@example.invalid `[FILL IN]` from the account
address, answered within 10 working days (+5 with notice, art. 20).

## 11. Cookies, analytics, ads

No web version, no cookies. No analytics in the current version `[FILL IN if AppMetrica is
added]`. No ads in the current version; if enabled, `[FILL IN: ad network, Yandex Ads by default]`
banners appear **only on Settings and About**, never on reminder, dose, medication, relatives,
report, scan, consent or export screens, with no medical data; removable by a purchase or promo
code. `[FILL IN: ad SDK data and consent]`

## 12. Security

TLS; password and token hashes; AES-256-GCM for export archives and provider tokens; per-query
access control; rate limits; no medical data in logs; separate databases and keys per region.
`[FILL IN: disk encryption, protection level, threat model, crypto tools, incident response and
RKN notice (art. 21(3.1))]`

## 13. Age

Self-registration from 18. Children's data only through a managed profile kept by a legal
representative. `[FILL IN: age check — none in the current version]`

## 14. Changes

A change means a new version, which the app asks you to review. Current version: `[FILL IN]`.
