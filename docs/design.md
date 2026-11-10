# PillPal design system: «Забота» (B2)

Chosen direction: **B «Забота»** (owner, 2026-11-10; it replaced «Абрикос»). The token spec is
[`docs/design/b2/README.md`](design/b2/README.md); the boards in [`docs/design/b2/`](design/b2/) show every screen.
The plan and milestones are in [`docs/redesign-plan.md`](redesign-plan.md). This file is what the code must match;
`app/test/theme_test.dart` and `app/test/theme_contrast_test.dart` pin it.

## Principles
1. One saturated block per screen: the pine «Сейчас» card, or the primary button. Everything else is neutral.
2. People first: profile chips under the title; the main user manages several people.
3. Status = icon + word, always. **Missed is calm iris, never red.** Red (`danger`) is only for destructive actions
   and blocking errors.
4. Pill-shaped controls, 20 px cards, 28 px sheets. Soft shadows in light; in dark, lighter surfaces instead of shadows.
5. Dark is green-grey (`#202A28`), not black; elevated surfaces step up in lightness.
6. Reminder, dose and mark-taken screens never carry ads or medical context for third parties (`rules/privacy.md`).

## Accessibility floors
| | Normal | Senior mode |
|---|---|---|
| Text contrast | >= 4.5:1 | >= 7:1 |
| Touch target | >= 44 px | >= 64 px |
| UI boundary (field, switch, checkbox) | >= 3:1 | >= 3:1 |
| Text scale | system scale | system scale x 1.3 (`PillPalSizes.seniorTextScale`) |

There are no exceptions: `theme_contrast_test.dart` checks every pair below in all four palettes.

## Semantic colours (`PillPalPalette`)
Four palettes: light, dark, light senior, dark senior. `taken` is the same pine as `action`, on purpose.

| Token | Role | Light | Dark | Light senior | Dark senior |
|---|---|---|---|---|---|
| `background` | screen | `F2F6F5` | `202A28` | `F2F6F5` | `202A28` |
| `surface` | cards, groups, fields, sheets, dialogs | `FFFFFF` | `2A3734` | `FFFFFF` | `2A3734` |
| `raised` | chips off, neutral banner, segmented track, avatar | `E6EEEC` | `354441` | `E6EEEC` | `354441` |
| `border` | dividers, card hairlines, secondary button | `D3DEDB` | `455754` | `AFC2BD` | `566B67` |
| `outline` | field / checkbox / switch boundary | `6B7D79` | `8A9C98` | `4D5F5B` | `A9BAB6` |
| `ink` | primary text, icons | `10201D` | `EAF2F0` | `10201D` | `F3F8F7` |
| `inkMuted` | secondary text, inactive nav | `4D5F5B` | `A9BAB6` | `384845` | `D3DFDB` |
| `action` / `onAction` | primary button, links, focus | `0C6B5D` / `FFFFFF` | `5BCDB6` / `05261F` | `08574B` / `FFFFFF` | `7FDCC8` / `05261F` |
| `actionSoft` / `onActionSoft` | tonal button, selected chip, soft banner, nav indicator | `DCF0EB` / `074A40` | `1F4A41` / `BDEDE2` | `DCF0EB` / `053F36` | `1F4A41` / `CDF3EA` |
| `taken` / `onTaken` | dose taken | `0C6B5D` / `FFFFFF` | `5BCDB6` / `05261F` | `08574B` / `FFFFFF` | `7FDCC8` / `05261F` |
| `takenSoft` / `onTakenSoft` | taken pill, partial calendar day | `C8E8DF` / `074A40` | `285047` / `C6F0E6` | `C8E8DF` / `053F36` | `285047` / `D3F5EC` |
| `missed` / `onMissed` | dose missed | `4652A6` / `FFFFFF` | `A3ADF5` / `161C4A` | `36418F` / `FFFFFF` | `BCC4FA` / `161C4A` |
| `missedSoft` / `onMissedSoft` | missed pill | `E4E7F8` / `2E3880` | `323A5E` / `D5DAFF` | `E4E7F8` / `252E70` | `323A5E` / `E0E4FF` |
| `danger` / `onDanger` | destructive, blocking errors only | `BD2A2A` / `FFFFFF` | `FF8F86` / `3A0A0A` | `981F1F` / `FFFFFF` | `FFB6B0` / `3A0A0A` |
| `dangerSoft` / `onDangerSoft` | danger banner, destructive icon tile | `FBE4E2` / `871D1D` | `4C2C2C` / `FFD3CE` | `FBE4E2` / `751818` | `4C2C2C` / `FFDCD8` |
| `scrim` | modal scrim, used at 48 % | `10201D` | `0B1110` | `10201D` | `0B1110` |
| `hero` / `onHero` | «Сейчас» card | `0C6B5D` / `FFFFFF` | `1F4A41` / `EAF2F0` | `08574B` / `FFFFFF` | `1F4A41` / `F3F8F7` |
| `heroAction` / `onHeroAction` | «Принял» inside the card | `FFFFFF` / `0C6B5D` | `5BCDB6` / `05261F` | `FFFFFF` / `08574B` | `7FDCC8` / `05261F` |

The Material `ColorScheme` is a view of these tokens: `primary` = `action`, `secondaryContainer` = `actionSoft`,
`error` = `danger`, `surface` = `surface`, `surfaceContainerHighest` = `raised`, `outline` = `outline`,
`outlineVariant` = `border`, `scrim` = `scrim`. Screens read `context.palette`, never `Colors.*` or `Color(0x..)`
(`check_ui_tokens.py` fails the build).

## Contrast (WCAG 2.x, :1)
Columns: light, dark, light senior, dark senior. Text pairs must reach 4.5 (7 in senior); UI pairs 3.

| Pair | Ratios |
|---|---|
| ink / background, surface, raised | 15.47 12.97 15.47 13.76 / 16.85 10.89 16.85 11.56 / 14.29 8.98 14.29 9.53 |
| inkMuted / background, surface, raised | 6.21 7.30 8.84 10.78 / 6.77 6.13 9.63 9.06 / 5.74 5.06 8.16 7.47 |
| action / background, surface | 5.88 7.63 7.79 9.12 / 6.41 6.40 8.48 7.66 |
| onAction / action | 6.41 8.33 8.48 9.95 |
| onActionSoft / actionSoft, raised | 8.58 7.75 10.00 8.33 / 8.63 7.97 10.06 8.57 |
| taken / background, surface | same as action |
| onTaken / taken | 6.41 8.33 8.48 9.95 |
| onTakenSoft / takenSoft | 7.79 7.30 9.07 7.75 |
| ink / takenSoft | 12.89 7.93 12.89 8.41 |
| missed / background, surface | 6.39 6.92 8.35 8.72 / 6.96 5.81 9.09 7.33 |
| onMissed / missed | 6.96 7.58 9.09 9.56 |
| onMissedSoft / missedSoft | 8.57 8.04 10.03 8.78 |
| danger / background, surface | 5.46 6.69 7.56 8.83 / 5.95 5.62 8.23 7.42 |
| onDanger / danger | 5.95 7.76 8.23 10.24 |
| onDangerSoft / dangerSoft | 7.78 9.07 9.10 9.67 |
| onHero / hero | 6.41 8.73 8.48 9.26 |
| onHeroAction / heroAction | 6.41 8.33 8.48 9.95 |
| ink, inkMuted / actionSoft | 14.21 8.73 14.21 9.26 / 5.71 4.91 8.12 7.26 |
| **UI** outline / surface, background | 4.34 4.30 6.77 6.13 / 3.99 5.12 6.21 7.30 |
| **UI** action / surface | 6.41 6.40 8.48 7.66 |
| **UI** taken / takenSoft | 4.90 4.66 6.49 5.57 |

## Component tokens
Implemented in `app/lib/src/theme/component_themes.dart` (Material themes) and, from R2, in `features/common/`.

| Component | Spec |
|---|---|
| Primary button | `action` / `onAction`, height 52 (senior 64), stadium, `labelLarge` |
| Secondary button | `surface` / `ink`, 1.5 px `border` ring, stadium |
| Tonal button | `actionSoft` / `onActionSoft`, stadium (scan entry, «Применить») |
| Text button | `action`, min 44 x 44 (senior 64 x 64) |
| Danger button | `danger` / `onDanger`, stadium; only in destructive dialogs and the delete row |
| Disabled button | `raised` / `inkMuted` |
| «Сейчас» card | `hero` / `onHero`; «Принял» `heroAction` / `onHeroAction`, 76 high in senior; snooze outline `onHero` at 55 %; radius 28; padding 20 |
| Card | `surface`, radius 20, level 1 shadow in light, padding 16 |
| List row | min height 60 (senior 76), padding 10/16, 1 px `border` divider, 40 disc `raised` |
| Chip | height 36 (profile chip 44), stadium; off `surface` + 1 px `border`; on `actionSoft` / `onActionSoft` + check icon |
| Profile chips | at most 4 visible plus a pinned «Все N» chip; horizontal scroll with a 32 px fade to `background` |
| Status pill / disc | pill height 28, icon 16 + word; disc 40 (senior 52); taken `takenSoft`, missed `missedSoft`, pending 1.5 px `border` + `inkMuted`, skipped `raised`, due `actionSoft`; solid `taken` / `missed` discs in senior |
| Round check | 48 circle, 2 px `outline`; pressed `action` / `onAction` |
| Banner | radius 20, padding 14/16, icon 20; soft `actionSoft`, info `raised` / `ink`, danger `dangerSoft` |
| Input | radius 16, `surface`, 1.5 px `outline`; focus 2 px `action`; error 2 px `danger` + icon + text below |
| Segmented | track `raised` stadium, padding 4, segment min 44; selected `surface` + level 1 + 700 weight; radio-list fallback when a label would wrap to 3 lines |
| Switch | 52 x 32; on: track `action`, thumb `onAction`; off: `raised` track, 2 px `outline` ring, `outline` thumb |
| Checkbox | radius 7, 2 px `outline`; on: `action` + check `onAction` |
| Navigation bar | `surface`, height 88 (senior 104); indicator `actionSoft`, radius 16, around icon and label; active label 700 |
| FAB | extended, height 56, stadium, `action` / `onAction`, elevation 2 |
| Sheet | `surface`, top radius 28, drag handle 36 x 4 (`outline` at 60 %), padding 8/20/28, scrim 48 % |
| Dialog | `surface`, radius 28, padding 24; destructive: 48 `dangerSoft` icon disc, buttons stacked full width, destructive first |

## Typography
Manrope (display) and Golos Text (body), both SIL OFL 1.1, both with Cyrillic. Sizes are at system scale 1.0; senior mode
multiplies them by 1.3 through the text scaler. Letter-spacing is 0 except screen titles (-0.6).

| Role | Slot | Family, weight | Size / line |
|---|---|---|---|
| Screen title | `displaySmall` (and `headlineLarge` until every screen moves) | Manrope 800 | 32 / 38 |
| «Сейчас» medication name | `headlineMedium` | Manrope 800 | 26 / 30 |
| Dialog and empty-state title | `headlineSmall` | Manrope 800 | 24 / 30 |
| App bar title | `titleLarge` | Manrope 700 | 20 / 24 |
| Section header | `titleMedium` | Manrope 700 | 18 / 22 |
| Group label | `titleSmall` | Golos Text 600 | 15 / 20 |
| Times, counters | `textTheme.numeral` (`PillPalText`) | Manrope 800, tabular figures | 22 / 26 |
| Body, list row title | `bodyLarge` | Golos Text 400 (500-600 for titles) | 17 / 22 |
| Secondary text | `bodyMedium` | Golos Text 400 | 15 / 20 |
| Help, captions | `bodySmall` (`inkMuted`) | Golos Text 400 | 14 / 19, never below 13 |
| Buttons | `labelLarge` | Golos Text 700 | 17 / 20 |
| Chips, pills | `labelMedium` | Golos Text 600 | 14 / 17 |
| Nav labels | `labelSmall` | Golos Text 500, active 700 | 13 / 16 |

## Radius, spacing, elevation, sizes
- **Radius** (`PillPalRadius`): `sm` 12, `md` 16, `lg` 20, `xl` 28, `pill` = `StadiumBorder`; `navIndicator` 16, `checkbox` 7.
- **Spacing** (`PillPalSpacing`, multiples of 4): `xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 20, `xxl` 24, `xxxl` 32, `huge` 40.
  Tab screens have side padding 16, pushed screens and forms 20, sheets `fromLTRB(20, 8, 20, 28)`. Section header: top 24,
  bottom `md` (the board draws 10, which is off the scale; the plan rounds it to 12).
- **Elevation** (`PillPalShadows`, light only; dark has no shadows): level 1 for cards and the selected segment, level 2
  for FAB, sheets, dialogs and the QR card (two `BoxShadow`s each), `nav` for the top edge of the bar (dark: 1 px
  `border` line). `Card(elevation: 0)` plus a `DecoratedBox`, because Material elevation tints do not match.
- **Sizes** (`PillPalSizes`): button 52 / 64, senior «Принял» 76, round check 48, profile chip 44, nav 88 / 104, FAB 56,
  progress ring 56, status disc 40 / 52, empty-state disc 96 with a 44 icon, QR 220, avatars 40 / 48 / 64.

## Narrow screens and large text (board `B2-Narrow`)
Verified by `ui_matrix.dart` at 320 x 568 and 360 x 800, RU, text x 2.0.
1. Text scales fully (x 2.0); paddings, icons and control heights do not; controls grow with their content.
2. The screen title is clamped at x 1.5 and the «Сейчас» name at x 1.6; the last resort is a break inside the word.
3. At x 1.6 and above the header actions move to their own right-aligned line under the title.
4. At x 1.6 and above the progress ring is hidden; a «Принято 2 из 5» line says the same in text.
5. Profile chips never wrap: horizontal scroll with a fade; the selected chip is always first.
6. Paired buttons always stack, full width; the label wraps, min height 56.
7. At x 1.6 and above a list row hides its tile and chevron (the whole row is tappable); meta data stacks.
8. The round check and the status pill stick to the top of a multi-line row, not the centre.
9. Tab labels are clamped at x 1.15 (full label as tooltip); the FAB label at x 1.3.
10. The bottom padding of a list is the FAB height plus 16.

Clamps use `MediaQuery.textScalerOf(context).clamp(maxScaleFactor: ...)` on the specific `Text`; breakpoints use
`textScaler.scale(1) >= PillPalSizes.compactRowScale`.

## Fonts
Bundled static TTFs in `app/assets/fonts/`, no runtime download (offline-first; no request to a third party from RU or EU
users): `Manrope-700/800.ttf` and `GolosText-400/500/600/700.ttf`, with `Manrope-OFL.txt` and `GolosText-OFL.txt`. The
licence texts ship with the fonts and are added to the licence page by `registerFontLicenses()`
(`lib/src/theme/font_licenses.dart`, called from `main.dart`). Rubik and Nunito are removed.
The files are the `[wght]` variable fonts of `google/fonts` (`ofl/manrope`, `ofl/golostext`) cut with
`fonttools varLib.instancer <font>[wght].ttf wght=<weight> -o <name>-<weight>.ttf`; every file was checked for the full
Cyrillic range (А-я, Ёё), digits and the `tnum` feature. `test/fonts_test.dart` pins the families, weights and licences.
The PDF report (`report_pdf.dart`) embeds `GolosText-400/700`.

## Rules for code
- Use the tokens (`PillPalPalette`, `PillPalRadius`, `PillPalSpacing`, `PillPalSizes`, `textTheme`, `PillPalShadows`);
  a missing token is reported, not invented. `.github/scripts/check_ui_tokens.py` counts raw literals and the
  aliases being retired (`PillPalSizes.statusSquare`, `InfoNote(`, `TodaySummaryCard(`) against
  `app/tool/ui_literals_baseline.json`, which only goes down; R8 empties it.
- Every screen has a `pumpUiMatrix` test: {light, dark} x {normal, senior} x {ru, en} x {1.0, 2.0} x {360 x 800, 320 x 568}.
- Keys used by `integration_test`, `test_driver` and `test_e2e` stay (`docs/redesign-plan.md`, "Keys and types that must
  survive").

## Boards
Chosen: `B2-*.dc.html` and the `B-*.dc.html` references in [`docs/design/b2/`](design/b2/). `B2-Components` (light and dark) and
`B2-Narrow` apply to every screen. Screens: Welcome, SignIn, Register, Consent, Notification, Alarm, AddMedication,
ScanCamera, ScanManual, Schedule, Settings, SettingsData, RelativeDetail, InviteCreate, InviteReady, InviteAccept,
HistoryDay, ReportSheet, EmptyMedications, EmptyFamily, DangerDialog, TodaySeniorDark. The boards load Google Fonts from
a CDN for rendering only; the app never does.
