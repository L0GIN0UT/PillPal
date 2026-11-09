# GTIN and GS1 element strings — formal specification (v1)

Status: normative. Source requirements: `docs/TZ.md` (global medicine catalog,
barcode lookup; Phase 4). This document is the contract for **how a scanned or
typed number becomes a catalog key**: normalization of GTINs, classification
(may the number be shared between accounts?), parsing of GS1 element strings
from 2D codes, and two helpers (`gtin14_to_gtin13`, `ndc_to_gtin14`).

It is implemented three times:

| Implementation | Location | Scope |
|---|---|---|
| Python (reference) | `catalog/catalog/domain/gtin.py`, `gs1.py` | everything in this document |
| Python (subset) | `backend/app/domain/gtin.py` | normalize, classify, `ndc_to_gtin14` |
| Dart | `packages/pillpal_core/lib/src/catalog/gtin.dart`, `gs1.dart` | everything in this document |

All implementations MUST produce identical results. This is enforced by the
shared vectors in `spec/gtin-vectors/` (see its `README.md`), which the test
suites execute. Any change to this document requires matching changes to the
vectors and to the implementations in the same pull request (same rule as
`docs/spec/schedule.md` and `docs/spec/dose-state.md`).

The key words MUST, MUST NOT, SHOULD are used as in RFC 2119.

External references (all checked on 2026-11-09):

- **GS1 General Specifications, Release 26.0, ratified Jan 2026** (GS1 AISBL),
  `https://ref.gs1.org/standards/genspecs/` — cited as "GS1 GS" with section and
  table numbers below.
- Government of the Russian Federation, Resolution No. 1556 of 14 December 2018
  (pilot, then mandatory marking of medicines) and the Chestny ZNAK
  documentation — see section 5.4 for what could and could not be verified.

## 1. Normalization

### 1.1 Input and output

Input: a string typed by a user, read from a EAN/UPC barcode, or taken from
AI 01 of an element string. Output: a `Gtin` value with

| Field | Meaning |
|---|---|
| `gtin14` | The number left-padded with `0` to 14 ASCII digits. This is the catalog key. |
| `source_length` | 8, 12, 13 or 14: the number of digits **before** padding (needed by the classification, section 3). |
| `classification` | Derived from the two fields above (section 3). |

### 1.2 Steps

1. **Strip** every U+0020 SPACE and U+002D HYPHEN-MINUS. Nothing else is
   stripped: tabs, newlines, NO-BREAK SPACE and all other characters stay and
   are rejected in step 2.
2. **Characters.** Every remaining character MUST be an ASCII digit `0`–`9`.
   Unicode digits (Arabic-Indic, fullwidth, ...) are NOT digits of this
   contract. Otherwise: error `invalid_characters`.
3. **Length.** The remaining length MUST be 8, 12, 13 or 14. Otherwise: error
   `invalid_length` (this includes the empty string).
4. **Check digit.** The last digit MUST equal the mod-10 check digit of the
   digits before it (section 2). Otherwise: error `invalid_check_digit`.
5. **Pad** on the left with `0` to 14 digits.

The order of steps 2 and 3 is part of the contract: `"ABC"` is
`invalid_characters`, `"123"` is `invalid_length`, `"12ab"` is
`invalid_characters`.

### 1.3 Error codes

`invalid_length`, `invalid_characters`, `invalid_check_digit` (normalization) and
`unsupported_format` (element strings, section 4). They are stable wire codes.
An error carries nothing but the code: the input MUST NOT be echoed into a
message, a log line or an exception text (it may be a barcode of a medicine).

## 2. Check digit

For the digits `d1 … dn` before the check digit, number them from the right
(`dn` is position 1). Sum `3 × d` over odd positions and `1 × d` over even
positions; the check digit is `(10 − sum mod 10) mod 10` (GS1 GS section 7.9.1).
The check digit of a number is the same whatever its zero padding, so a GTIN-13
and its GTIN-14 form (indicator `0`) share it.

## 3. Classification: `shareable | restricted`

The catalog stores one record per `gtin14`. A number that is not globally
unique MUST NOT be a shared key, because two unrelated products (or two
accounts' private items) would collide. Such numbers are `restricted`; every
other number is `shareable`.

A number is `restricted` iff **any** of these holds:

1. `source_length = 8` and the first digit of the GTIN-8 is `0` or `2`
   (RCN-8: GS1-8 prefixes 000–099 and 200–299, GS1 GS Table 1-5).
2. `source_length ≠ 8` and the **indicator digit** (`gtin14[0]`) is `9`
   (variable measure trade item, GS1 GS sections 2.1.7.2 and 2.1.10).
3. `source_length ≠ 8` and the GTIN-13 form `gtin14[1:]` starts with
   - `02` — GS1 prefixes 020–029, restricted distribution within a region
     (GS1 GS Table 1-4; for a GTIN-12 this is a UPC-A starting with `2`),
   - `04` — GS1 prefixes 040–049, restricted distribution within a company
     (Table 1-4; a UPC-A starting with `4`),
   - `2` — GS1 prefixes 200–299, restricted distribution within a region
     (Table 1-4),
   - `0000000` — seven zeros, restricted within a company (Tables 1-4 and 1-6).

Notes:

- The classification of a GTIN-14 looks through the indicator digit to the base
  number it was built from: `1` + a `02…` base is `restricted`.
- A GTIN-13 starting with `9` is **not** an indicator-9 case: the indicator
  digit exists only in a GTIN-14, and a GTIN-13 is padded with indicator `0`.
- `source_length` is needed because a padded GTIN-8 looks like a GTIN-13 with
  five leading zeros; RCN-8 is decided on the original 8 digits only. A GTIN
  read from AI 01 has `source_length = 14` (GS1 forbids RCNs in AIs, GS1 GS
  section 1.2.2.2.1).
- Prefixes `980`–`983` and `99` (refund receipts, coupons) are Member
  Organisation defined but not Restricted Circulation Numbers; they are NOT
  classified `restricted` here. They never occur on medicines.

### 3.1 Deviations from the owner's list and from GS1

The owner's decision was: `020–029`, `200–299` (from the TZ) plus `040–049`,
RCN-8 and indicator digit 9. Verified against GS1 GS Release 26.0 (Jan 2026):
all five are confirmed by Tables 1-4, 1-5, 1-6 and sections 2.1.7.2 / 2.1.10.
GS1 states one more restricted range that the list did not name: the
GS1 prefix `0000000` (U.P.C. `000000`), "Restricted Circulation Numbers within
a company" (Tables 1-4 and 1-6). It is **added** (rule 3, `0000000`) so that the
contract follows GS1; it has its own vectors.

## 4. GS1 element strings

An element string is a sequence of `AI + data` elements as transmitted by a
scanner (GS1 GS section 7.8). `parse_gs1` extracts the GTIN of AI 01 and the
expiry of AI 17 and ignores the rest.

### 4.1 Prefixes

1. If the data starts with `]`, a symbology identifier is stripped. Exactly four
   are accepted (GS1 GS Table 5-2): `]d2` (GS1 DataMatrix), `]C1` (GS1-128),
   `]Q3` (GS1 QR Code), `]e0` (GS1 DataBar). Any other `]xx` (for example
   `]d1`, plain Data Matrix) is not stripped and the data fails as an unknown
   AI (`unsupported_format`).
2. Group separators (GS, U+001D, the transmitted form of FNC1) are skipped
   wherever an element is expected: at the start (leading FNC1), after a
   variable-length element, and — tolerated although GS1 says SHOULD NOT —
   after a predefined-length one. Anything else, including `%` (GS1 QR can use
   it as an alternative separator in the symbol, scanners transmit GS), is data.

### 4.2 Elements

Elements are read left to right.

- **Predefined length** (GS1 GS Table 7-6; the length is AI plus data and is
  determined by the first two digits): `00` → 20, `01`, `02`, `03` → 16, `04` → 18,
  `11`–`19` → 8, `20` → 4, `31`–`36` → 10, `41` → 16. All characters of the
  element MUST be ASCII digits. (This is GS1's table, a superset of the owner's
  list: `03`, `04`, `14`, `18`, `19` are in Table 7-6 as well.)
- **Variable length, ended by GS or by the end of the data**: `10`, `21`, `22`,
  `240`, `241`, `30`, `37`, `710`–`715`, `90`–`99`. The value runs to the next
  GS, or to the end. **Maximum lengths are not enforced** (Chestny ZNAK puts a
  44-character crypto code into AI 92, whose GS1 maximum is 30). An empty value
  is allowed. Without separators a variable-length element swallows everything
  after it: `01…21ABC17271231` has the serial `ABC17271231` and no expiry.
- **AI 01** — the data MUST be 14 characters without a GS, ASCII digits, with a
  valid check digit. A shorter or GS-interrupted value is `invalid_length`,
  non-digits are `invalid_characters`, a wrong check digit is
  `invalid_check_digit`. The first AI 01 wins; a second one is skipped as an
  ordinary predefined element. The result is a `Gtin` with `source_length = 14`.
- **AI 17** (expiry, `YYMMDD`) after AI 01 — see 4.3.
- Any other predefined element is consumed without interpretation (the SSCC
  check digit, dates other than AI 17, weights and so on are not verified).

An unknown AI, a non-AI character, or a malformed predefined element
(truncated, non-digit) **after** a valid AI 01 stops the parse: the result is
returned with `partial: true` and what was collected so far. The same
situation **before** AI 01 cannot be skipped and is `unsupported_format`.

If the end of the data is reached without AI 01, the error is
`unsupported_format`. This covers URLs in QR codes, GS1 Digital Link, IFA PPN
(`[)>…`), parenthesized human-readable AIs (`(01)…`), plain EAN digits (which
`normalize` handles) and the empty string.

### 4.3 Expiry (AI 17)

`YYMMDD`, all digits. The year is **2000 + YY**. Month 01–12. Day 00 means the
last day of the month (GS1 GS section 3.4.7, including leap years). A date
that does not exist (month 13, February 30) is not an error: the expiry is
absent and parsing continues. The expiry is a **date only**: the result has no
time and no zone; Dart returns UTC midnight, compared with `isAtSameMomentAs`.
An AI 17 before AI 01 is consumed and ignored.

Deviation from GS1: GS1 GS section 7.12 chooses the century in a sliding window
(49 years back to 50 years ahead of today). That needs a clock; a medicine pack
does not expire before 2000, and the fixed rule keeps the function pure.
Revisit in the 2070s.

### 4.4 Result

`Gs1Result { gtin, expiry, partial }`. Errors are `GtinError` (Python) /
`GtinException` (Dart) carrying only the code.

## 5. Privacy: lot and serial number are never kept

### 5.1 Why

A serial number (AI 21) identifies one physical pack, and with the lot (AI 10)
and the pharmacy's records it links a person to a purchase. Both are personal
data adjacent to medical data. The catalog is public-data-only and the backend
never needs them (`.claude/rules/privacy.md`, rules 1 and 2).

### 5.2 Rule

The parser **consumes and discards** AI 10, AI 21 and every other element it
does not return. The result type has **no field** for a lot or a serial number;
it cannot be added without changing this document and the vectors. Nothing
about the discarded values may reach a log, an exception text, a metric label
or a response.

### 5.3 Enforcement

- `spec/gtin-vectors/schema.json` makes the expected results closed objects and
  forbids the keys `serial`, `lot`, `serial_number`, `batch`;
  `spec/validate_vectors.py` additionally scans every expected result at any
  depth for them.
- The Python and Dart tests assert that the result type has exactly the fields
  `gtin`, `expiry`, `partial` and that its text form does not contain the lot
  or serial of the input.

### 5.4 Chestny ZNAK pharma DataMatrix

A medicine pack code is a GS1 DataMatrix with the groups
`01` GTIN (14 digits), `21` serial number (13 characters), GS, `91` verification
key (4 characters), GS, `92` crypto code (44 characters, base64 text; the
older 88-character form was cut to 44).

Verified: the four groups and the AIs 01/21/91/92, the 4- and 44-character
lengths of the key and the crypto code (SAP Advanced Track and Trace for
Pharmaceuticals help, "crypto key (4 characters) and the actual crypto code
(44 characters) ... application identifiers 91 and 92"; World Pharma Today
overview of the Russian system: the crypto code was reduced from 88 to 44
characters; Resolution No. 1556: the 36×36-module DataMatrix with four data
groups). Not verifiable from this environment (the Chestny ZNAK documentation
host was unreachable): the 13-character serial length from the primary source.
**The parser does not depend on any of these lengths**: the GTIN is the first 16
characters, and a missing GS between groups makes the serial swallow the tail,
which is discarded anyway. Vectors cover the code with all separators, with none,
with one, with a trailing GS, with a symbology identifier and with a leading GS;
all yield the same GTIN.

## 6. Helpers

### 6.1 `gtin14_to_gtin13(raw) -> string | null`

Normalizes `raw` (any valid length, errors as in section 1), then returns
`gtin14[1:]` when the indicator digit `gtin14[0]` is `0`, otherwise `null` (a
GTIN-14 with indicator 1–9 has no GTIN-13 form). The common case is a
`00`-prefixed GTIN-14 (a GTIN-12): its GTIN-13 keeps one leading zero.
Implemented in the catalog reference and in Dart (not in the backend subset).

### 6.2 `ndc_to_gtin14(ndc) -> string`

Strips spaces and hyphens; the rest MUST be exactly 10 ASCII digits (errors
`invalid_characters` then `invalid_length`; the 11-digit billing form is not
accepted). Result: `"3" + ndc10` + its check digit (a GTIN-12, GS1 U.P.C.
prefix 3 is aligned with the FDA labeler code, GS1 GS Table 1-6), left-padded
with `00` to 14 digits. It does not check that the NDC is a registered one.

## 7. Implementation notes

- Digits are ASCII only; `str.isdigit()` and `RegExp(r'\d')` are wrong here.
- Lengths count Unicode scalar values (Python). Dart counts UTF-16 code
  units; the two can differ only for a truncated AI 01 whose last character is
  outside the Basic Multilingual Plane, and then both reject the input.
- No clock, no IO, no logging in any of the implementations.

## 8. Test vectors

`spec/gtin-vectors/normalize.json` (normalization, classification, helpers) and
`gs1.json` (element strings); format and rules in
`spec/gtin-vectors/README.md`. Together at least 40 cases, covering: each length,
separators, every error code and the order of the checks, Unicode digits, prefix
boundaries 019/020/029/030, 039/040/049/050, 199/200/299/300, RCN-8, indicator
digit 9, GTIN-12 forms, `0000000`, symbology identifiers, GS handling, AI 17
including day 00 and leap years, variable AIs, partial results, unsupported
formats and the Chestny ZNAK layout.
