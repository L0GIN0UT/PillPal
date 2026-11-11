# PillPal Privacy Notice (EU region)

> **Шаблон: запуск в ЕС позже.** TEMPLATE — EU launch later. DRAFT, not legal advice; must be
> reviewed by a qualified lawyer. Version: `[FILL IN: privacy version for REGION=eu]` · effective:
> `[FILL IN: date]`. Information under GDPR Art. 13.

## 1. Controller and contacts

| | |
|---|---|
| Controller | `[FILL IN: legal name, address, registration number]` |
| Privacy contact | `[FILL IN: e-mail]` |
| Data Protection Officer (Art. 37) | `[FILL IN: DPO name and contact, or the reason none is designated]` |
| EU representative (Art. 27) | `[FILL IN: if the controller is established outside the EU]` |

## 2. What PillPal is

A medication reminder for you and your relatives. Reminders are created and fire on your device
without the server. The server synchronises your devices, gives relatives the access you grant and
detects missed doses to notify them. EU accounts are stored only in the EU deployment; there are no
links or data flows to the RU deployment.

## 3. Data, purposes and legal bases

| Purpose | Data | Legal basis |
|---|---|---|
| Account, sign-in, recovery | e-mail, password hash (Argon2id), region, language, verification time, one-time codes (hashed, 15 min); with Apple or Google sign-in (once enabled): provider subject id, e-mail at linking, Apple refresh token (encrypted, used only to revoke it) | Art. 6(1)(b) contract |
| Profiles | profile name, time zone, alert settings | Art. 6(1)(b) |
| Health data: storage, sync, missed-dose detection | medications (name, form, strength, notes, stock, privacy level, catalogue link, GTIN, manual composition), schedules, dose marks and notes, missed-dose records (72 h), sync journal | **Art. 9(2)(a) explicit consent** (`consent-health-data.md`) and Art. 6(1)(a) |
| Relatives and missed-dose alerts | grants, invites (hash only), owner's last sync hour, push tokens, push queue (ids only) | Art. 9(2)(a); Art. 6(1)(b) |
| Consent records | kind, version, source, accepted and withdrawn times | Art. 6(1)(c) with Art. 7(1) |
| Purchases and ad removal | store, product, purchase id, dates, entitlements, redeemed promo code ids | Art. 6(1)(b); `[FILL IN: Art. 6(1)(c) for accounting records?]` |
| Your data export | request metadata and the encrypted archive (24 h) | Art. 6(1)(c), Art. 15 and 20 |
| Security and operations | request id, route template, status, latency, opaque ids, error codes; rate-limit counters keyed by a hash of IP and account; error reports (exception type and stack frames) | Art. 6(1)(f) legitimate interest in a secure service |

Health data never goes into logs, error reports, analytics, push texts, e-mails or URLs. Camera
images for barcode scanning stay on the device; serial, batch and expiry are discarded.
Catalogue searches are sent without any link to your account.

**Relatives** see each medication at the level you choose: *shared* (name, dose, schedule, marks
without notes), *anonymous* (times, course dates and marks only), *hidden* (nothing). Guardians of
a managed profile see everything in it.

**Managed profiles.** If you create a profile for another person (a child, an older relative), you
confirm that you are their legal representative or have their consent. `[FILL IN: legal basis,
Art. 8 and Art. 9 for third persons]`

Self-registration is for persons aged 18 and over.

## 4. Recipients

Hosting `[FILL IN: hosting provider, EU city]`; self-hosted Sentry in the EU; SMTP `[FILL IN]`;
Google FCM and Apple APNs (push token and opaque ids only); Apple and Google sign-in (once
enabled); App Store and Google Play (purchases, once enabled); Google ML Kit (usage metrics of the
on-device scanner); ad network `[FILL IN]` (settings and about screens only, no medical data;
not used in the current version). Full list: `docs/legal/en/processors.md`, EU section.

## 5. Transfers outside the EEA

We store no personal data outside the EEA and do not transfer it to the RU deployment.
`[FILL IN: assessment of Apple and Google (push, sign-in, purchases, ML Kit) as US recipients —
EU-US DPF or SCC; "none" only if counsel confirms]`

## 6. Retention

While the account exists. After a deletion request the account is blocked for up to 30 days so you
can restore it, then erased by an hourly job within that period. A managed profile passed to a
co-guardian is kept as a read-only archive for up to 365 days. Codes 15 min; sessions up to 30 days;
invites 7 days (+30 days record); missed-dose records 72 h; push queue at most 7 days; unused push
tokens 270 days; export archive 24 h or one download (metadata 7 days); operator audit rows 365 days
without your id after erasure. Logs `[FILL IN]`; error reports `[FILL IN]`; backups `[FILL IN]`.

## 7. Your rights

Access (Art. 15), rectification (16), erasure (17), restriction (18), portability (20), objection
to processing based on legitimate interest (21), withdrawal of consent at any time (7(3)) and a
complaint to a supervisory authority (77), `[FILL IN: lead authority]`.

- Edit or delete data in the app.
- **Export**: in the app, a JSON archive (re-authentication, once per hour, one download within
  24 h). *Available after the app update*; until then, by e-mail.
- **Erasure / withdrawal of health-data consent**: Settings → Delete account. Withdrawing the
  health-data consent is an account deletion, because the service cannot work without it.
- E-mail `[FILL IN]`; we answer within one month (Art. 12(3)).

No automated decisions with legal or similarly significant effects (Art. 22) are made.

## 8. Cookies, analytics, ads

No website, no cookies. No analytics SDK in the current version. Ads, if enabled, appear only on
the Settings and About screens, never with medical context, and can be removed by a purchase or
promo code. `[FILL IN: ad SDK identifiers and the consent needed for them (ePrivacy)]`
