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
| Relatives and missed-dose alerts | grants, invites (hash only), owner's last sync hour, push tokens, push queue (opaque ids and event type; a missed-dose event is medical metadata) | Art. 9(2)(a); Art. 6(1)(b) |
| Consent records | kind, version, source, accepted and withdrawn times | Art. 6(1)(c) with Art. 7(1) |
| Purchases and ad removal | store, product, purchase id, dates, entitlements, redeemed promo code ids | Art. 6(1)(b); `[FILL IN: Art. 6(1)(c) for accounting records?]` |
| Your data export | request metadata and the encrypted archive (24 h) | Art. 6(1)(c), Art. 15 and 20 |
| Security and operations | request id, route template, status, latency, opaque ids, error codes; rate-limit counters keyed by a hash of IP and account; error reports (exception type, stack frames, request path without query, user-agent, x-request-id) | Art. 6(1)(f) legitimate interest in a secure service |

Medication names, doses and intake times never go into logs, error reports, analytics, push
messages, e-mails or URLs; a missed-dose push itself tells the delivery service that an event
exists for a profile (section 5). Camera images for barcode scanning stay on the device; serial,
batch and expiry are discarded. Catalogue searches are sent without any link to your account.

**On the device.** Android backup of app data is disabled. **On iOS the local database is
currently not excluded from iCloud/Finder backups**, so a copy can be included in your Apple
backup; excluding it is a planned fix.

**Doctor's PDF reports** are made on the device and never sent to the server. A finished report is
kept in the app's private storage (up to 20 reports, up to 90 days) and listed under "My reports";
you can open, save or share it, after which that copy is outside the app's control. A relative's
report is deleted from the device when access ends. All kept reports are deleted on sign-out,
account switch and account deletion. On iOS they are included in backups like the local database.

**Missed-dose alerts** go to relatives who turned them on, to guardians of a managed profile and to
the owner of a managed profile that has co-guardians; never to the owner of their own profile.

**Relatives** see each medication at the level you choose: *shared* (name, dose, schedule, marks
without notes), *anonymous* (times, course dates and marks only), *hidden* (nothing). Guardians of
a managed profile see everything in it. The profile name and time zone are visible to the owner,
to relatives and to anyone holding an invite link (preview).

**Managed profiles.** If you create a profile for another person (a child, an older relative), you
confirm that you are their legal representative or have their consent. `[FILL IN: legal basis,
Art. 8 and Art. 9 for third persons]` While the owner's account is pending deletion, its managed
profiles are archived and co-guardians have read-only access; after a restore, the consents must be
accepted again.

Self-registration is for persons aged 18 and over.

## 4. Recipients

Hosting `[FILL IN: hosting provider, EU city]`; self-hosted Sentry in the EU; SMTP `[FILL IN]`;
Google FCM and Apple APNs (device token, opaque ids and the event type, e.g. that a profile has a
missed-dose notice; no medication names, doses or times); the Firebase SDK on the device
(installation id, device IP); Apple and Google sign-in (once enabled); App Store and Google Play
(purchases, once enabled); Google ML Kit (scanner usage metrics sent directly from the device, no
images or codes); ad network `[FILL IN]` (settings and about screens only, no medical data;
not used in the current version). Full list: `docs/legal/en/processors.md`, EU section.

## 5. Transfers outside the EEA

Stored data (database, Redis, backups, Sentry) stays in the EEA and is never transferred to the
RU deployment. While the app runs, these flows reach Apple and Google: push delivery (token, opaque
ids, event type), Firebase SDK traffic (installation id, device IP), ML Kit scanner metrics, sign-in
and App Store / Google Play purchases. `[FILL IN: assessment of these US recipients — EU-US DPF or
SCC]`

## 6. Retention

While the account exists. After a deletion request the account is blocked for up to 30 days so you
can restore it, then erased by an hourly job within that period. A managed profile passed to a
co-guardian is kept as a read-only archive for up to 365 days. Codes 15 min; session records while the account
exists (each token valid up to 30 days); relative invites 7 days, guardian invites 24 h (+30 days
record); missed-dose records 72 h; push queue at most 7 days; unused push
tokens 270 days; export archive 24 h or one download (metadata 7 days); operator audit rows 365 days
without your id after erasure. Logs `[FILL IN]`; error reports `[FILL IN]`; backups `[FILL IN]`.

## 7. Your rights

Access (Art. 15), rectification (16), erasure (17), restriction (18), portability (20), objection
to processing based on legitimate interest (21), withdrawal of consent at any time (7(3)) and a
complaint to a supervisory authority (77), `[FILL IN: lead authority]`.

- Edit or delete data in the app.
- **Export**: in the app, a JSON archive (re-authentication; one download within 24 h; a new
  request waits an hour while the previous archive is not downloaded; at most 3 a day). Not
  included: the sync journal, the push queue and missed-dose records (derived or transient), e-mail
  codes and credentials (password and token hashes, push tokens, encrypted provider tokens).
  *Available after the app update*; until then, by e-mail.
- **Erasure / withdrawal of health-data consent**: Settings → Delete account. Withdrawing the
  health-data consent is an account deletion, because the service cannot work without it.
- E-mail `[FILL IN]`; we answer within one month (Art. 12(3)).

No automated decisions with legal or similarly significant effects (Art. 22) are made.

## 8. Cookies, analytics, ads

No website, no cookies. No analytics SDK in the current version. Ads, if enabled, appear only on
the Settings and About screens, never with medical context, and can be removed by a purchase or
promo code. `[FILL IN: ad SDK identifiers and the consent needed for them (ePrivacy); a dedicated
`ads` / `analytics` consent kind will be needed once an ad SDK or analytics is added]`
