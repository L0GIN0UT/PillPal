# GTIN / GS1 test vectors

Shared, language-neutral test cases for the GTIN and GS1 contract specified in
[`docs/spec/gtin.md`](../../docs/spec/gtin.md): normalization, classification
(`shareable | restricted`), GS1 element-string parsing (GTIN of AI 01, expiry of
AI 17) and two helpers. The **same files** are executed by every implementation:

| Implementation | Test that runs the vectors |
|---|---|
| Python reference (`catalog/catalog/domain/gtin.py`, `gs1.py`) | `catalog/tests/domain/test_gtin_vectors.py`, `test_gs1_vectors.py` |
| Python subset (`backend/app/domain/gtin.py`: normalize, classify, `ndc_to_gtin14`) | `backend/tests/domain/test_gtin_vectors.py` (skips `gtin14_to_gtin13`) |
| Dart (`packages/pillpal_core`) | `packages/pillpal_core/test/catalog/gtin_vectors_test.dart` |

CI additionally runs `python spec/validate_vectors.py` (stdlib only, from the
repository root), which checks the structure and consistency of the files: shape
per [`schema.json`](schema.json), unique names, valid check digits of every
expected GTIN, zero padding and `source_length` against the input, the error code
against the input, valid AI 17 dates, and that **no expected result contains a
`serial` or `lot` key** (any depth). At least 40 cases.

## Files

| File | Covers |
|---|---|
| `normalize.json` | `op: normalize` — lengths 8/12/13/14, separators, every error code and their order, Unicode digits, prefix boundaries (019/020/029/030, 039/040/049/050, 199/200/299/300), UPC-A forms, RCN-8, indicator digit 9, `0000000`; `op: gtin14_to_gtin13`; `op: ndc_to_gtin14` |
| `gs1.json` | symbology identifiers, leading GS, AI 17 (day 00, leap year, invalid dates), predefined and variable AIs, lot/serial discarded, partial results, unsupported formats (URL, Digital Link, PPN, parenthesized, plain EAN), Chestny ZNAK pharma DataMatrix with and without GS |

## Case format

```json
{
  "name": "gtin13_plain",
  "description": "optional, explains the hand derivation",
  "op": "normalize",
  "input": "4607012345677",
  "expected": { "gtin14": "04607012345677", "source_length": 13, "classification": "shareable" }
}
```

`normalize.json` cases have an `op` and one of these expected shapes:

| `op` | success | failure |
|---|---|---|
| `normalize` | `{gtin14, source_length, classification}` | `{error}` |
| `gtin14_to_gtin13` | `{gtin13}` (a string or `null`) | `{error}` |
| `ndc_to_gtin14` | `{gtin14}` | `{error}` |

`gs1.json` cases have no `op`; `input` is the scanned text (control characters
as JSON escapes: `\u001d` is GS) and `expected` is
`{gtin14, classification, expiry, partial}` (`expiry` is `YYYY-MM-DD` or `null`;
the GTIN of AI 01 has `source_length` 14) or `{error}` (`unsupported_format` or a
GTIN error code). Error codes: `invalid_length`, `invalid_characters`,
`invalid_check_digit`, `unsupported_format`.

A runner MUST feed `input` to the operation of the contract and compare the whole
`expected` object. A runner that does not implement an `op` (the backend subset
has no `gtin14_to_gtin13`) MUST skip exactly that `op` and say so.

## Rules for adding vectors

1. Derive `expected` **by hand** from the spec; never paste implementation
   output as the expected value. Only valid check digits of *example* numbers may
   be computed with a helper.
2. Names are unique across both files (`^[a-z0-9_]+$`).
3. Numbers are synthetic (no real pack, lot or serial); the Chestny ZNAK example
   uses invented values.
4. **No `serial` / `lot` anywhere in an expected result**, ever (spec section 5).
5. Any change in semantics changes `docs/spec/gtin.md`, these vectors and every
   implementation in the same pull request.
