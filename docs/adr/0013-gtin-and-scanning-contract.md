# ADR 0013 — GTIN and scanning contract (Phase 4)

- Status: accepted
- Date: 2026-10-21
- Scope: TZ §2.1 ("GTIN нормализуется к GTIN-14. Коды ограниченного обращения (префиксы 02,
  20–29) в общую базу не попадают"; scan of EAN-13 / UPC-A / DataMatrix «Честного знака»),
  §6 (no OCR); `docs/spec/gtin.md`, `spec/gtin-vectors/`, `catalog/catalog/domain/{gtin,gs1}.py`,
  `backend/app/domain/gtin.py`, `packages/pillpal_core/lib/src/catalog/{gtin,gs1}.dart`, app
  `features/catalog/{scan_sheet,scanner_adapter,manual_gtin_entry,scan_flow}.dart`,
  `AndroidManifest.xml`, `Info.plist`
- Related: owner decisions D3 and D7 (`docs/phase4-plan.md`), ADR 0011 §5 (three
  implementations, shared vectors), ADR 0014 (only shareable GTINs are counted), ADR 0015
  (what the app sends), `.claude/rules/privacy.md` rules 1, 2, 8

## Context

A package is identified by its GTIN, printed as EAN-13, UPC-A, EAN-8 or, on Russian and
EU pharma packs, inside a GS1 DataMatrix together with a serial number, batch and expiry.
The Russian marking (Честный знак, operator ЦРПТ) puts a unique serial and a cryptographic
signature into every pack's code; the EU FMD code carries serial, batch and expiry. A
**serial number identifies one physical pack and therefore one buyer**: it must never be
stored, logged or sent. Some printed numbers are not global GTINs at all (store-internal
"restricted circulation" numbers, variable-measure items) and must not enter a shared base.

The rule has to be identical in three places — the catalog (reference, lookup and the
database CHECK), the backend (filtering what the aggregator counts) and the Dart core
(parsing on the device, offline) — so it is a spec-plus-vectors contract like the schedule
engine and the dose state.

## Decision

### 1. Normalization (`normalize(input) -> Gtin | GtinError`)

1. Remove spaces and hyphens (manual entry).
2. Length must be 8, 12, 13 or 14 → otherwise `invalid_length`; any non-digit →
   `invalid_characters`.
3. The last digit must be the GS1 mod-10 check digit of the preceding digits → otherwise
   `invalid_check_digit`.
4. Left-pad with zeros to 14 digits. The canonical form everywhere (API bodies, database,
   sync payloads, cache keys) is the 14-digit string.
5. Classify `shareable | restricted` (§2). Both are valid GTINs for the user's own
   medication; only `shareable` ones may be looked up, contributed or stored in the catalog.

The original length is kept in the result (`source_length`) for display only.

### 2. Restricted numbers (D3)

A normalized GTIN is **restricted** when any of the following holds (digits counted on the
14-digit form; the "GS1 prefix" is the first three digits of the GTIN-13 part, i.e. digits
2–4 of the GTIN-14):

| Rule | Range | Why | Source |
|---|---|---|---|
| R1 | GS1 prefix 020–029 | "Used to issue Restricted Circulation Numbers within a geographic region (MO defined)" | GS1 prefix list, `https://www.gs1.org/prefixes` (read 2026-10-21); TZ §2.1 |
| R2 | GS1 prefix 200–299 | same wording as R1 | same |
| R3 | GS1 prefix 040–049 | "Used to issue GS1 Restricted Circulation Numbers within a company" | same |
| R4 | GTIN-8 (8-digit input) whose first digit is 0 or 2 (RCN-8) | GS1 prefix list: `0000000` is "Used to issue Restricted Circulation Numbers within a company"; the biip reference, which implements GS1 General Specifications §2.1.11–2.1.12, classifies RCN-8 as prefix 0 or 2, company-scoped | `https://www.gs1.org/prefixes`; `https://biip.readthedocs.io/latest/reference/rcn/` |
| R5 | GTIN-14 (14-digit input) with indicator digit 9 | variable measure trade items: "starting with an indicator digit of 9 (reserved for identifying variable measure items)" | GS1 UK, `https://gs1uk.org/support-training/help-to-use-and-implement-gs1-standards/barcode-variable-measure-items` |

Notes:

- R1–R3 apply to 12-, 13- and 14-digit inputs alike after left-padding (a UPC-A `2…` or
  `4…` becomes prefix `02x`/`04x`). R4 applies only to 8-digit inputs, because a padded
  GTIN-8 would otherwise look like prefix `000`, which GS1 US owns. R5 applies only to
  14-digit inputs: a 13-digit code padded to 14 has indicator 0.
- Variable-measure retail numbers also start with 02/20–28 and are caught by R1/R2
  (GS1 UK: "All variable measure items crossing the retail point of sale begin with 20 and
  02"). The exact list of MO-defined 2x prefixes is irrelevant: the whole 200–299 block is
  restricted.
- The wording "within a company" and "within a geographic region" means the number has no
  global meaning, so a shared link on it would be wrong for other users. The app says
  "код магазина — не передаём в общий справочник" and keeps the GTIN privately (ADR 0015 §4).
- **To verify in 4.2:** the current GS1 General Specifications text of §2.1.11–2.1.12
  (RCN-8, variable measure) and the predefined-length AI table (§7.8.5) could not be
  fetched for this ADR (`ref.gs1.org` and the GenSpecs PDF were not reachable from the
  sandbox); the vectors of 4.2 pin the rules above and cite the section numbers once read.
- The database CHECK `catalog.gtin_is_shareable(gtin)` implements R1–R5 in SQL, so a
  restricted number cannot enter `gtins` or `gtin_link_candidates` even by a bug.

### 3. GS1 element string parsing (`parse_gs1(raw) -> ScanResult`)

Input is the raw decoded string of a DataMatrix, QR, GS1-128 or DataBar symbol.

1. Strip a leading symbology identifier (`]d2`, `]Q3`, `]C1`, `]e0`) and a leading FNC1
   represented as GS (`\x1d`), `\xe8` or the literal `(01)` bracket form used by some
   scanners (brackets are accepted only in the human-readable form, never mixed).
2. Walk application identifiers: AIs with a **predefined length** (00, 01, 02, 03, 04,
   11–20, 31xx–36xx, 41x) are read without a separator; all others end at the next GS or at
   the end of the string. Known variable AIs: 10, 21, 22, 240, 241, 30, 37, 710–715, 90–99.
3. AI 01 → GTIN, then §1 normalization applies. AI 02 (GTIN of contained items) is not
   used as the package GTIN.
4. **AI 10 (batch/lot) and AI 21 (serial) are consumed and discarded.** `ScanResult` has
   no field for them; the JSON schema of the vectors forbids the keys `serial` and `lot`.
5. AI 17 (expiry, `YYMMDD`, `DD=00` meaning the last day of the month) is parsed and
   validated (`expiry_valid: true|false`) and **not stored** (D7): the result carries a
   `has_expiry` boolean only. A future feature storing expiry needs a new ADR.
6. AIs 710–715 (national healthcare reimbursement numbers) are recognized and skipped.
7. An unknown AI after a valid 01 ends parsing with `partial: true` and the GTIN kept.
8. No AI 01 (plain URL, GS1 Digital Link `https://…/01/…`, securPharm PPN `[)>…`, free
   text) → `unsupported_format`. Digital Link and PPN are future work.
9. A 1D symbol (EAN/UPC) is not parsed as GS1: its decoded digits go straight to §1.

#### Честный знак (pharma) layout

Verified against the operator's documentation (markirovka.ru, "Формирование кода
маркировки … DataMatrix для ЛП", read 2026-10-21): the medicine code is **85 characters**:

| Group | Content | Length incl. AI | Separator after |
|---|---|---|---|
| `01` | GTIN-14 | 16 | none (predefined length) |
| `21` | serial, 13 characters | 16 | FNC1/GS |
| `91` | verification key, 4 characters | 7 | FNC1/GS |
| `92` | verification code (cryptographic signature), 44 characters | 46 | none (end) |

Lot (10) and expiry (17) are not part of the ЧЗ pharma code. Because `01` comes first with a
fixed length, the GTIN is recovered even when a scanner drops the GS characters; the vectors
cover both forms. The 13-character serial and the 44-character signature are discarded by
rule 4; the app never calls the Честный знак API.

The EU FMD code (`01` GTIN, `17` expiry, `10` batch, `21` serial, optional `710`–`715`) is
covered by the same walk.

### 4. What may leave the device

| Data | Stored on device | Sent to catalog | Sent to backend (sync) | Logged |
|---|---|---|---|---|
| GTIN-14 (shareable) | yes, on the medication | yes, in a POST body (`/v1/gtins/lookup`) | yes (`gtin` field) | never |
| GTIN-14 (restricted) | yes, on the medication | **no** | yes (`gtin` field, private) | never |
| serial (21), lot (10) | **no** | **no** | **no** | never |
| expiry (17) | **no** (D7) | no | no | never |
| raw symbol string, camera frames | no | no | no | never |

### 5. Scanner package: `mobile_scanner`

- `mobile_scanner`, BSD-3-Clause (repository `github.com/juliansteenbakker/mobile_scanner`,
  read 2026-10-21). Latest stable at the time of writing: **7.4.2, published 2026-09-14**
  (pub.dev versions page), older than two weeks; 4.11 pins the then-latest stable that is
  at least two weeks old, as an exact version.
- Android: CameraX + Google ML Kit barcode scanning. The plugin's README states it "uses
  by default the bundled version of MLKit Barcode-scanning for Android" (model inside the
  APK, +3–10 MB); the unbundled variant (`dev.steenbakker.mobile_scanner.useUnbundled=true`
  in `gradle.properties`) downloads the model through Google Play Services. **PillPal keeps
  the bundled default** so devices without GMS (RuStore users, Huawei) scan offline; a CI
  check in 4.11 fails the build if the property is set or a Play Services barcode artifact
  is merged.
- iOS: AVFoundation + Apple Vision, on-device.
- Formats enabled: EAN-8, EAN-13, UPC-A, DataMatrix only (QR and others off). Torch on;
  no image capture, no gallery import, no frames kept.
- Camera permission: Android `CAMERA` with `<uses-feature android:name="android.hardware.camera"
  android:required="false"/>`; iOS `NSCameraUsageDescription` (EN + RU
  `InfoPlist.strings`). Requested on first scan with a rationale; a denial leads to manual
  GTIN entry (digits keyboard, live check-digit validation). The app stays installable and
  usable on devices without a camera.
- The plugin returns the raw string only; all GS1 parsing is `pillpal_core` (§3). The widget
  layer talks to a `ScannerAdapter` interface so tests use a fake.

### 6. ML Kit metrics: a third party

Google's ML Kit terms state that "processing of the input data (e.g. images, video, text)
fully happens on-device" and that "ML Kit does not send that data to Google servers", but
also that "the ML Kit APIs may contact Google servers from time to time in order to receive
things like bug fixes, updated models" and "also send metrics about the performance and
utilization of the APIs in your app to Google" (ML Kit Terms of Service, text as mirrored at
`https://scancode-licensedb.aboutcode.org/google-ml-kit-tos-2022.html`, read 2026-10-21; the
original `developers.google.com/ml-kit/terms` was not reachable from the sandbox — **to
verify in 4.11**). The terms do not enumerate what the metrics contain. Consequences:

- ML Kit is listed as a third party for Android in both regions (privacy rule 8) with the
  wording "usage and performance metrics; no images or barcode contents"; legal item 4 of
  the plan covers the privacy policy and the RKN cross-border notification for RU.
- The metrics are sent from the device by Google's library, not by PillPal, and carry no
  PillPal identifier; the app adds nothing to them.
- **Fallback recorded:** `flutter_zxing` (MIT; pub.dev documentation shows 3.1.0, "powered
  by zxing-cpp v3.1.1"; zxing-cpp is Apache-2.0 — **to verify in 4.11**), fully on-device
  through Dart FFI, no Google component, supports DataMatrix, EAN-13 and UPC-A. If counsel
  objects to the ML Kit metrics, 4.11 switches the `ScannerAdapter` implementation to it;
  the rest of the flow is unchanged.

### 7. Vectors and implementations

- `spec/gtin-vectors/normalize.json` (validity, padding, restricted rules R1–R5, NDC-derived
  GTINs) and `spec/gtin-vectors/gs1.json` (symbology ids, GS present/absent, AI order,
  ЧЗ and FMD layouts, expiry day 00, partial, unsupported), ≥ 40 cases, shape-checked by
  `spec/validate_vectors.py`; the schema forbids `serial` and `lot` in any expected result.
- Reference: `catalog/catalog/domain/gtin.py` and `gs1.py` (all vectors), SQL functions
  `catalog.gtin_check_digit_ok`, `catalog.gtin_is_shareable` (tested against the same
  vectors); backend `app/domain/gtin.py` (normalize and shareable only); Dart
  `packages/pillpal_core/lib/src/catalog/gtin.dart` and `gs1.dart` (all vectors).
- Any change to the rules updates `docs/spec/gtin.md`, the vectors and all three
  implementations in one PR (`schedule-engine-guardian` discipline).

## Consequences

- A fourth shared contract (`gtin-vectors`) next to schedule and dose-state vectors.
- Some legitimate numbers are refused for sharing: GTIN-8 codes from the 0/2 blocks,
  in-store codes, variable-measure packs. They still work privately on the user's
  medication (local match offline, ADR 0015 §4).
- Expiry is thrown away (D7); users who want it must wait for a future feature.
- Android APK grows by the bundled ML Kit model (≈3–10 MB).
- ML Kit becomes a disclosed third party; a switch to `flutter_zxing` stays cheap.
- No OCR of the package text (TZ §6).

## Alternatives considered

- **TZ ranges only (02, 20–29):** would admit company-internal numbers (04x) and variable
  measure GTIN-14s into the shared base; the owner chose the stricter set (D3).
- **Store expiry from AI 17** for stock reminders: useful, but a medical datum on every
  scan with no feature behind it yet; deferred (D7).
- **Keep the serial hashed** for duplicate-pack detection: a stable per-pack identifier is
  exactly what must not exist; rejected.
- **Unbundled ML Kit** (smaller APK): fails without Google Play Services; rejected for the
  RuStore audience.
- **`flutter_zxing` first:** avoids Google entirely, but has a smaller maintainer base and
  no Apple Vision path; kept as the fallback.
- **Server-side parsing** of the raw code: would send serials over the network; rejected.
