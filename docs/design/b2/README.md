# «Забота» (B2) — final design system for PillPal

Chosen direction: **B «Забота»** (2026-11-10). This file is the token spec for the Flutter implementation; the boards
in this folder show every screen. Existing `B-*` boards are kept unchanged for reference. Nothing in the repository was
changed. All hex values and ratios come from one source (`../redesign-src/palettes.py` + `b2tokens.py`), so boards,
tables and tests agree.

## Boards
- `B2-Components.dc.html` — component sheet, light and dark (1280×900).
- `B2-Narrow.dc.html` — Today and Medications at 320 px with RU text at scale 2.0, plus the wrap/stack rules.
- `B2-Welcome.dc.html` — Добро пожаловать, выбор региона
- `B2-SignIn.dc.html` — Вход с ошибкой
- `B2-Register.dc.html` — Регистрация
- `B2-Consent.dc.html` — Согласия: отдельно данные о здоровье
- `B2-Notification.dc.html` — Напоминание: уведомление
- `B2-Alarm.dc.html` — Напоминание-будильник на весь экран
- `B2-AddMedication.dc.html` — Добавить лекарство: справочник и скан
- `B2-ScanCamera.dc.html` — Скан: камера
- `B2-ScanManual.dc.html` — Скан: ввод номера
- `B2-Schedule.dc.html` — Редактор расписания
- `B2-Settings.dc.html` — Настройки
- `B2-SettingsData.dc.html` — Приватность и данные
- `B2-RelativeDetail.dc.html` — Близкий: уровни приватности
- `B2-InviteCreate.dc.html` — Приглашение: создать
- `B2-InviteReady.dc.html` — Приглашение: QR и ссылка
- `B2-InviteAccept.dc.html` — Приглашение: принять
- `B2-HistoryDay.dc.html` — История: день
- `B2-ReportSheet.dc.html` — Отчёт PDF: лист
- `B2-EmptyMedications.dc.html` — Пусто: лекарства
- `B2-EmptyFamily.dc.html` — Пусто: близкие
- `B2-DangerDialog.dc.html` — Диалог удаления аккаунта
- `B2-TodaySeniorDark.dc.html` — Сегодня: старший режим, тёмная

## Principles
1. One saturated block per screen: the pine «Сейчас» card (or the primary button). Everything else is neutral.
2. People first: profile chips under the title of Today (the Family tab lists everyone itself, so it has none); the main user manages several people.
3. Status = icon + word, always. Missed is calm iris, never red; red is only for destructive actions and blocking errors.
4. Pill-shaped controls, 20 px cards, 28 px sheets; soft shadows in light, lighter surfaces instead of shadows in dark.
5. Dark is green-grey (`#202A28`), not black; elevated surfaces step up in lightness.

## 1. Primitive tokens
Names are `family-tone`, tone = CIELAB L* (0 black … 100 white), the same idea as Material 3 tones. `fog` = green-grey neutrals, `pine` = evergreen/mint, `iris` = missed indigo, `brick` = danger red. A trailing `b` marks a second colour with the same tone.

| Family | Primitives (tone → hex) |
|---|---|
| **fog** | `fog-100` #FFFFFF, `fog-97` #F2F6F5, `fog-97b` #F3F8F7, `fog-95` #EAF2F0, `fog-93` #E6EEEC, `fog-88` #D3DEDB, `fog-88b` #D3DFDB, `fog-77` #AFC2BD, `fog-74` #A9BAB6, `fog-63` #8A9C98, `fog-51` #6B7D79, `fog-43` #566B67, `fog-39` #4D5F5B, `fog-35` #455754, `fog-29` #384845, `fog-27` #354441, `fog-22` #2A3734, `fog-16` #202A28, `fog-11` #10201D, `fog-5` #0B1110 |
| **pine** | `pine-94` #D3F5EC, `pine-93` #DCF0EB, `pine-93b` #CDF3EA, `pine-92` #C6F0E6, `pine-90` #C8E8DF, `pine-90b` #BDEDE2, `pine-82` #7FDCC8, `pine-76` #5BCDB6, `pine-40` #0C6B5D, `pine-33` #08574B, `pine-31` #285047, `pine-28` #074A40, `pine-28b` #1F4A41, `pine-23` #053F36, `pine-13` #05261F |
| **iris** | `iris-92` #E4E7F8, `iris-91` #E0E4FF, `iris-88` #D5DAFF, `iris-80` #BCC4FA, `iris-72` #A3ADF5, `iris-38` #4652A6, `iris-31` #36418F, `iris-27` #2E3880, `iris-25` #323A5E, `iris-22` #252E70, `iris-13` #161C4A |
| **brick** | `brick-92` #FBE4E2, `brick-91` #FFDCD8, `brick-88` #FFD3CE, `brick-81` #FFB6B0, `brick-71` #FF8F86, `brick-42` #BD2A2A, `brick-33` #981F1F, `brick-30` #871D1D, `brick-25` #751818, `brick-22` #4C2C2C, `brick-10` #3A0A0A |

## 2. Semantic tokens
| Token | Role | Light | Dark | Light senior | Dark senior |
|---|---|---|---|---|---|
| `bg` | screen background (`background`) | `#F2F6F5` fog-97 | `#202A28` fog-16 | `#F2F6F5` fog-97 | `#202A28` fog-16 |
| `surface` | cards, groups, fields, sheets, dialogs | `#FFFFFF` fog-100 | `#2A3734` fog-22 | `#FFFFFF` fog-100 | `#2A3734` fog-22 |
| `raised` | chips off, neutral banner, segmented track, avatar | `#E6EEEC` fog-93 | `#354441` fog-27 | `#E6EEEC` fog-93 | `#354441` fog-27 |
| `border` | dividers, card hairlines, secondary button | `#D3DEDB` fog-88 | `#455754` fog-35 | `#AFC2BD` fog-77 | `#566B67` fog-43 |
| `outline` | field / checkbox / switch boundary (≥ 3:1) | `#6B7D79` fog-51 | `#8A9C98` fog-63 | `#4D5F5B` fog-39 | `#A9BAB6` fog-74 |
| `ink` | primary text, icons | `#10201D` fog-11 | `#EAF2F0` fog-95 | `#10201D` fog-11 | `#F3F8F7` fog-97b |
| `inkMuted` | secondary text, inactive nav | `#4D5F5B` fog-39 | `#A9BAB6` fog-74 | `#384845` fog-29 | `#D3DFDB` fog-88b |
| `action` | primary button, links, focus, active switch | `#0C6B5D` pine-40 | `#5BCDB6` pine-76 | `#08574B` pine-33 | `#7FDCC8` pine-82 |
| `onAction` | content on action | `#FFFFFF` fog-100 | `#05261F` pine-13 | `#FFFFFF` fog-100 | `#05261F` pine-13 |
| `actionSoft` | tonal button, selected chip, soft banner, nav indicator | `#DCF0EB` pine-93 | `#1F4A41` pine-28b | `#DCF0EB` pine-93 | `#1F4A41` pine-28b |
| `onActionSoft` | content on actionSoft | `#074A40` pine-28 | `#BDEDE2` pine-90b | `#053F36` pine-23 | `#CDF3EA` pine-93b |
| `taken` | dose taken (same pine as action, on purpose) | `#0C6B5D` pine-40 | `#5BCDB6` pine-76 | `#08574B` pine-33 | `#7FDCC8` pine-82 |
| `onTaken` | content on taken | `#FFFFFF` fog-100 | `#05261F` pine-13 | `#FFFFFF` fog-100 | `#05261F` pine-13 |
| `takenSoft` | taken pill, partial calendar day | `#C8E8DF` pine-90 | `#285047` pine-31 | `#C8E8DF` pine-90 | `#285047` pine-31 |
| `onTakenSoft` | text on takenSoft | `#074A40` pine-28 | `#C6F0E6` pine-92 | `#053F36` pine-23 | `#D3F5EC` pine-94 |
| `missed` | dose missed (calm iris, never red) | `#4652A6` iris-38 | `#A3ADF5` iris-72 | `#36418F` iris-31 | `#BCC4FA` iris-80 |
| `onMissed` | content on missed | `#FFFFFF` fog-100 | `#161C4A` iris-13 | `#FFFFFF` fog-100 | `#161C4A` iris-13 |
| `missedSoft` | missed pill | `#E4E7F8` iris-92 | `#323A5E` iris-25 | `#E4E7F8` iris-92 | `#323A5E` iris-25 |
| `onMissedSoft` | text on missedSoft | `#2E3880` iris-27 | `#D5DAFF` iris-88 | `#252E70` iris-22 | `#E0E4FF` iris-91 |
| `danger` | destructive actions, blocking errors only | `#BD2A2A` brick-42 | `#FF8F86` brick-71 | `#981F1F` brick-33 | `#FFB6B0` brick-81 |
| `onDanger` | content on danger | `#FFFFFF` fog-100 | `#3A0A0A` brick-10 | `#FFFFFF` fog-100 | `#3A0A0A` brick-10 |
| `dangerSoft` | danger banner, destructive icon tile | `#FBE4E2` brick-92 | `#4C2C2C` brick-22 | `#FBE4E2` brick-92 | `#4C2C2C` brick-22 |
| `onDangerSoft` | text on dangerSoft | `#871D1D` brick-30 | `#FFD3CE` brick-88 | `#751818` brick-25 | `#FFDCD8` brick-91 |
| `scrim` | modal scrim colour, used at 48 % opacity | `#10201D` fog-11 | `#0B1110` fog-5 | `#10201D` fog-11 | `#0B1110` fog-5 |

Every cell is the exact value for that theme (no inheritance shorthand), followed by its primitive.

## 3. Component tokens
Theme-dependent component colours:

| Token | Role | Light | Dark | Light senior | Dark senior |
|---|---|---|---|---|---|
| `hero` | «Сейчас» card background | `#0C6B5D` pine-40 | `#1F4A41` pine-28b | `#08574B` pine-33 | `#1F4A41` pine-28b |
| `onHero` | text on hero | `#FFFFFF` fog-100 | `#EAF2F0` fog-95 | `#FFFFFF` fog-100 | `#F3F8F7` fog-97b |
| `heroAction` | «Принял» inside hero | `#FFFFFF` fog-100 | `#5BCDB6` pine-76 | `#FFFFFF` fog-100 | `#7FDCC8` pine-82 |
| `onHeroAction` | label of heroAction | `#0C6B5D` pine-40 | `#05261F` pine-13 | `#08574B` pine-33 | `#05261F` pine-13 |

| Component token | Value (semantic token or number) |
|---|---|
| `button.primary` | bg `action`, fg `onAction`, height 52 (senior 64), shape stadium, label `labelLarge` |
| `button.secondary` | bg `surface`, fg `ink`, 1.5 px `border` inside, stadium |
| `button.tonal` | bg `actionSoft`, fg `onActionSoft`, stadium (scan entry, «Применить») |
| `button.text` | fg `action`, min 44×44 |
| `button.danger` | bg `danger`, fg `onDanger`, stadium; only in destructive dialogs and the delete row |
| `button.disabled` | bg `raised`, fg `inkMuted` (5.7:1, still readable) |
| `hero` («Сейчас») | bg `hero`, fg `onHero`, «Принял» bg `heroAction` fg `onHeroAction`, snooze outline `onHero` at 55 %, radius 28, padding 20 |
| `card` | bg `surface`, radius 20, elevation 1 (light), padding 16 |
| `listRow` | min height 60 (senior 76), padding 10/16, divider 1 px `border` between rows, leading 40 disc `raised` |
| `chip` | height 36 (profile 44), stadium; off: `surface` + 1 px `border`; on: `actionSoft` / `onActionSoft` + check icon |
| `profileChips` | max 4 visible + pinned «Все N» chip when > 4; row scrolls horizontally with a 32 px fade to `bg` |
| `statusPill` | height 28, stadium, icon 16 + word; taken `takenSoft/onTakenSoft`, missed `missedSoft/onMissedSoft`, pending 1.5 px `border` + `inkMuted`, skipped `raised/inkMuted`, due `actionSoft/onActionSoft` |
| `statusDisc` | 40 (senior 52) circle, same pairs as statusPill; solid `taken`/`missed` in senior |
| `roundCheck` | 48 circle, 2 px `outline`, icon `inkMuted`; pressed: bg `action`, icon `onAction` |
| `banner` | radius 20, padding 14/16, icon 20; soft `actionSoft/onActionSoft`, info `raised/ink`, danger `dangerSoft/onDangerSoft` |
| `input` | height 52, radius 16, bg `surface`, 1.5 px `outline`; focus 2 px `action`; error 2 px `danger` + icon + text below |
| `segmented` | track `raised` stadium, padding 4, segment min 44; selected `surface` + elevation 1 + 700 weight; falls back to a radio list when a label would wrap to 3 lines |
| `switch` | 52×32; on: track `action`, thumb `onAction` 24; off: track `raised`, 2 px `outline`, thumb `outline` 16 |
| `checkbox` | 24, radius 7, 2 px `outline`; on: `action` + check `onAction` |
| `navBar` | bg `surface`, top radius 24, height 88 (senior 104); indicator = `actionSoft` rounded 16 around icon **and** label; active label 700 |
| `fab` | extended, height 56, stadium, bg `action`, fg `onAction`, elevation 2, icon 24 + «Сканировать» |
| `sheet` | bg `surface`, top radius 28, drag handle 36×4 `outline` 60 %, padding 8/20/28, scrim `scrim` 48 % |
| `dialog` | bg `surface`, radius 28, padding 24, icon disc 48 `dangerSoft` for destructive; buttons stacked full width, destructive first |

## 4. Contrast (WCAG 2.x, :1)
Normal text ≥ 4.5, senior text ≥ 7, UI boundaries ≥ 3 (WCAG 1.4.11).

| Pair | Kind | Light | Dark | Light senior | Dark senior |
|---|---|---|---|---|---|
| ink / bg | text | 15.47 | 12.97 | 15.47 | 13.76 |
| ink / surface | text | 16.85 | 10.89 | 16.85 | 11.56 |
| ink / raised | text | 14.29 | 8.98 | 14.29 | 9.53 |
| inkMuted / bg | text | 6.21 | 7.30 | 8.84 | 10.78 |
| inkMuted / surface | text | 6.77 | 6.13 | 9.63 | 9.06 |
| inkMuted / raised | text | 5.74 | 5.06 | 8.16 | 7.47 |
| action / bg | text | 5.88 | 7.63 | 7.79 | 9.12 |
| action / surface | text | 6.41 | 6.40 | 8.48 | 7.66 |
| onAction / action | text | 6.41 | 8.33 | 8.48 | 9.95 |
| onActionSoft / actionSoft | text | 8.58 | 7.75 | 10.00 | 8.33 |
| taken / bg | text | 5.88 | 7.63 | 7.79 | 9.12 |
| taken / surface | text | 6.41 | 6.40 | 8.48 | 7.66 |
| onTaken / taken | text | 6.41 | 8.33 | 8.48 | 9.95 |
| onTakenSoft / takenSoft | text | 7.79 | 7.30 | 9.07 | 7.75 |
| ink / takenSoft | text | 12.89 | 7.93 | 12.89 | 8.41 |
| missed / bg | text | 6.39 | 6.92 | 8.35 | 8.72 |
| missed / surface | text | 6.96 | 5.81 | 9.09 | 7.33 |
| onMissed / missed | text | 6.96 | 7.58 | 9.09 | 9.56 |
| onMissedSoft / missedSoft | text | 8.57 | 8.04 | 10.03 | 8.78 |
| danger / bg | text | 5.46 | 6.69 | 7.56 | 8.83 |
| danger / surface | text | 5.95 | 5.62 | 8.23 | 7.42 |
| onDanger / danger | text | 5.95 | 7.76 | 8.23 | 10.24 |
| onDangerSoft / dangerSoft | text | 7.78 | 9.07 | 9.10 | 9.67 |
| onHero / hero | text | 6.41 | 8.73 | 8.48 | 9.26 |
| onHeroAction / heroAction | text | 6.41 | 8.33 | 8.48 | 9.95 |
| ink / actionSoft | text | 14.21 | 8.73 | 14.21 | 9.26 |
| inkMuted / actionSoft | text | 5.71 | 4.91 | 8.12 | 7.26 |
| onActionSoft / raised | text | 8.63 | 7.97 | 10.06 | 8.57 |
| outline / surface | UI ≥ 3 | 4.34 | 4.30 | 6.77 | 6.13 |
| outline / bg | UI ≥ 3 | 3.99 | 5.12 | 6.21 | 7.30 |
| action / surface | UI ≥ 3 | 6.41 | 6.40 | 8.48 | 7.66 |
| taken / takenSoft | UI ≥ 3 | 4.90 | 4.66 | 6.49 | 5.57 |

Text minimum per theme: light 5.46 (≥ 4.5); dark 4.91 (≥ 4.5); lightSenior 7.56 (≥ 7); darkSenior 7.26 (≥ 7).

## 5. Typography
| Role | Flutter slot | Family | Weight | Normal size / line | Senior (×1.3) | Notes |
|---|---|---|---|---|---|---|
| Screen title | `displaySmall` | Manrope | 800 | 32 / 38, tracking −0.6 | 42 / 48 | clamp ×1.5 at large system scale |
| «Сейчас» medication name | `headlineMedium` | Manrope | 800 | 26 / 30 | 34 / 39 | clamp ×1.6 |
| Dialog / empty-state title | `headlineSmall` | Manrope | 800 | 24 / 30 | 31 / 39 | |
| App bar title | `titleLarge` | Manrope | 700 | 20 / 24 | 26 / 31 | |
| Section header | `titleMedium` | Manrope | 700 | 18 / 22 | 23 / 29 | `SectionHeader` |
| Times, counters | `PillPalText.numeral` (extension) | Manrope | 800, tabular figures | 22 / 26 (alarm 80) | 29 / 34 | `FontFeature.tabularFigures()` |
| Body, list row title | `bodyLarge` | Golos Text | 400 (500–600 for titles) | 17 / 22 | 22 / 29 | |
| Secondary text | `bodyMedium` | Golos Text | 400 | 15 / 20 | 20 / 26 | `inkMuted` |
| Help, captions | `bodySmall` | Golos Text | 400 | 14 / 19 | 18 / 25 | never below 13 |
| Buttons | `labelLarge` | Golos Text | 700 | 17 / 20 (hero «Принял» 18) | 22 / 26 (senior «Принял» 26) | |
| Chips, pills | `labelMedium` | Golos Text | 600 | 13–15 / 16–18 | 17–20 | |
| Nav labels | `labelSmall` | Golos Text | 500, active 700 | 13 / 16 | 16 / 20 | clamp ×1.15 |

Senior mode keeps today's mechanism: `PillPalSizes.seniorTextScale = 1.3` multiplies the system scale; the senior
column shows the effective size at system scale 1.0. Letter-spacing 0 everywhere except screen titles.

## 6. Radius, spacing, elevation, sizes
**Radius** (`PillPalRadius`): `sm` 12 (calendar cells, small tiles, keypad keys), `md` 16 (fields, tonal tiles),
`lg` **20** (cards, banners), `xl` **28** (sheets, dialogs, «Сейчас» card), `pill` 999 = `StadiumBorder` (every button, chip,
pill, segmented control, FAB, nav indicator inner shape uses 16).

**Spacing** (`PillPalSpacing`, multiples of 4, unchanged values): `xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 20, `xxl` 24,
`xxxl` 32, **new `huge` 40**. Screen side padding 16 on tabs (was 20; cards carry their own 16 padding), 20 on pushed
screens and forms. Card padding 16 (rows 12–16 vertical). Gap between cards `listGap` 12. Section header: top 24, bottom 10. Board values of 10 and 14 (pill and chip padding, row gaps) are drawn at the 4-scale in code (8, 12, 16).

**Elevation** (light; dark has **no shadows**, levels are lighter surfaces `bg` → `surface` → `raised`):

| Level | Used by | Light shadow |
|---|---|---|
| 0 | page, list rows inside a card, chips | none |
| 1 | cards, selected segment | `0 1 2 rgba(16,40,36,.06)`, `0 6 16 rgba(16,40,36,.06)` |
| 2 | FAB, sheets, dialogs, raised QR card | `0 2 4 rgba(16,40,36,.08)`, `0 12 28 rgba(16,40,36,.14)` |
| nav | bottom bar (top edge) | `0 -6 24 rgba(16,40,36,.08)`; dark: 1 px `border` top line |

In Flutter: `BoxShadow(offset: Offset(0, 1), blurRadius: 2, color: Color(0x0F102824))` (alpha .06 = 0x0F) etc. — two `BoxShadow`s per level
in a `PillPalShadows` const class; `Card(elevation: 0)` + `DecoratedBox`, because Material elevation tints do not match.

**Sizes** (`PillPalSizes`): button 52 (unchanged), senior button 64 (unchanged), senior «Принял» 76 (unchanged),
touch target 44 (normal) / 64 (senior), **round check 48**, profile chip height 44, nav bar 88 / senior 104 (was 76 / 88),
FAB 56, progress ring **56** (was 60), status disc 40 (normal) / 52 (senior; replaces `statusSquare` 64), avatar 40 / 48 / 64,
empty-state disc 96 with icon 44, QR 220 (was 240) inside a 20 px white frame.

## 7. Mapping to the current code
### `theme/palette.dart` (`PillPalPalette`)
| Field | Change |
|---|---|
| `background`, `surface`, `border`, `ink`, `inkMuted`, `action`, `onAction`, `actionSoft`, `onActionSoft`, `taken`, `onTaken`, `takenSoft`, `missed`, `onMissed`, `danger`, `onDanger` | **kept, new values** (table above; `background` = `bg`) |
| `raised`, `outline`, `onTakenSoft`, `missedSoft`, `onMissedSoft`, `dangerSoft`, `onDangerSoft`, `scrim` | **added** |
| `hero`, `onHero`, `heroAction`, `onHeroAction` | **added** (component tokens; light = action family, dark = soft tint + mint button) |
| `info` | **removed**: the info banner becomes neutral (`raised` / `ink`). 2 call sites (`pillpal_banner.dart`, `InfoNote`) |
| static palettes `light`, `lightSenior`, `dark`, `darkSenior` | kept; values per table; `copyWith`/`lerp` grow by 12 fields |

The theme test (`test/theme_test.dart`) keeps its rule (normal ≥ 4.5, senior ≥ 7) and gains the new pairs from the
contrast table plus the UI pairs ≥ 3 (`outline` on `surface`/`bg`).

### `theme/radius.dart` (`PillPalRadius`)
`sm` 12 (same), `md` 16 (same), **`lg` 18 → 20**, **`xl` 24 → 28**; `hero`/`dialog`/`sheetTop` follow `xl`; **add**
`pill = StadiumBorder()` helper. The UI-1 test that pins `{12, 16, 18, 24}` changes to `{12, 16, 20, 28}`.

### `theme/spacing.dart` (`PillPalSpacing`)
Values unchanged; **add** `huge = 40`; `screen`/`tabHeader` side padding `xl` (20) → `lg` (16) on tab screens;
`sheet` becomes `fromLTRB(xl, sm, xl, xxxl - 4)`.

### `theme/app_theme.dart`
- `PillPalFonts.display` `'Rubik'` → `'Manrope'`, `PillPalFonts.body` `'Nunito'` → `'GolosText'`; `textTheme` per the type table.
- `filledButtonTheme`/`elevatedButtonTheme`/`outlinedButtonTheme`/`textButtonTheme`: `StadiumBorder`, heights unchanged.
- `cardTheme`: elevation 0, radius 20; shadows drawn by a `PillPalCard` decoration in light only.
- `navigationBarTheme`: height 88 / 104, `indicatorShape` rounded 16 wide enough for the label (custom `NavigationDestination`
  label inside the indicator via `NavigationBarThemeData.indicatorColor` + a wrapper; the widget type `NavigationBar` stays
  for the emulator journeys).
- `inputDecorationTheme`: filled `surface`, `outline` 1.5, focus `action` 2, error `danger` 2, radius 16.
- `switchTheme`, `checkboxTheme`, `segmentedButtonTheme`, `chipTheme`, `floatingActionButtonTheme` (stadium, elevation 2),
  `bottomSheetTheme` (radius 28, `showDragHandle: true`), `dialogTheme` (radius 28): all read the palette.
- `colorScheme`: `primary` = `action`, `secondaryContainer` = `actionSoft`, `error` = `danger`, `surface` = `surface`,
  `surfaceContainerHighest` = `raised`, `outline` = `outline`, `outlineVariant` = `border`, `scrim` = `scrim`.

### `PillPalSizes`
Changed: `progressRing` 60 → 56, `qrCode` 240 → 220, `statusSquare` 64 → **removed**, replaced by `statusDisc` 40 /
`statusDiscSenior` 52. Added: `roundCheck` 48, `profileChip` 44, `navHeight` 88 / `navHeightSenior` 104, `heroPadding` 20,
`emptyDisc` 96, `fab` 56. Unchanged: `buttonHeight` 52, `seniorButtonHeight` 64, `touchTarget` 44, `seniorTextScale` 1.3,
`seniorTakeHeight` 76, `iconInline` 20, `iconSenior` 28, `iconEmpty` (56 → **44** inside the 96 disc).
Text-scale clamps (new consts): `titleMaxScale` 1.5, `heroNameMaxScale` 1.6, `navLabelMaxScale` 1.15, `fabLabelMaxScale` 1.3,
`compactRowScale` 1.6 (row tile and chevron hide above it).

### `features/common/`
| Widget | Change |
|---|---|
| `PillPalBanner` / `BannerTone` | tones `soft` (`actionSoft`), `info` (**`raised`/`ink`**, was blue), `danger` (`dangerSoft`); radius 20, no border |
| `InfoNote` | becomes `PillPalBanner(tone: info)` without a title (alias, then removed) |
| `ChoiceButton` / `ChoiceGroup` | stadium chip; selected = `actionSoft` + check icon (not colour alone); API and keys unchanged |
| `SectionHeader`, `GroupLabel` | Manrope 700 18 / Golos 600 15; spacing 24 / 10 |
| `SheetScaffold`, `ActionSheet` | radius 28, drag handle, padding per `sheet` |
| `confirm_dialog.dart`, `removal_dialog.dart` | radius 28, icon disc, stacked full-width buttons (destructive first, `button.danger`) |
| `PillPalIconButton` | 48 circle; secondary variant with `border` ring |
| `StatusMessage`, `IconLabel`, `Gap`, `ErrorSnackBar` | colours only |
| **new** `StatusPill`, `StatusDisc` | the status component (icon + word), used by Today, History, Family |
| **new** `ProfileChips` | Today header switcher (the Family tab lists all profiles and has no switcher) with the «Все N» overflow chip; `profile_switcher.dart` is a `ChoiceGroup`, not a sheet, so «Все N» opens a new `ActionSheet`; `ProfileSwitcher` is replaced by `ProfileChips` in R3, not kept alongside |
| **new** `RoundCheckButton` | upcoming dose quick-take; forwards the `dose-take-<occurrence>` key (`dose-taken-*` belongs to the taken status) |
| **new** `PillPalSegmented` | wraps `SegmentedButton` with the radio-list fallback |
| `shell/empty_state.dart` (`EmptyState`) | 96 disc, headline, body, primary + secondary actions |

## 8. Per-screen layout changes vs today's implementation
| Screen | Today's implementation | «Забота» |
|---|---|---|
| Welcome | brand, tagline, region chips, two buttons | headline-first layout, region as two radio cards, primary + secondary pinned to the bottom |
| Sign-in / Register | form, `AuthErrorBanner`, `AuthNotice` | step indicator («Шаг 1 из 3»), fields with leading icons, danger banner above the form, primary pinned bottom |
| Consent (new UI; backend 5.2a exists) | — | three separate checkboxes; health data in its own card with explanation, version and full-text link; button disabled until all checked |
| Today | header + `TodaySummaryCard` ring, `DoseTile` list | ring 56 in the header, `ProfileChips`, pine «Сейчас» hero with full-width «Принял», «Дальше» cards with `RoundCheckButton`, «Уже было» with `StatusDisc` |
| Today senior | own top card + time groups | same hero at senior sizes (76 / 64), time groups as rows with 52 discs; dark: soft hero + mint «Принял» |
| Reminder | system notification, alarm screen | content unchanged (title, dose, «Принял / Отложить на 15 мин / Пропустить»); accent `#0C6B5D`; full-screen alarm on solid pine with 80 px time and stacked 76/64 buttons |
| Medications | cards, «+» in app bar, scan FAB (UI-7) | cards radius 20 with pill tile, privacy + stock meta row, low stock as soft pill; «+» round button and profile in header; FAB stadium |
| Add medication | catalog section, manual form | two tiles at top («Сканировать упаковку» tonal, «Ввести вручную»), search field, results card |
| Scan sheet | `ScanSheet` camera + manual | sheet radius 28, 300 px viewfinder with corner marks and torch, privacy text, «Ввести номер вручную»; manual: one field, helper, error with icon, «Камера / Продолжить» |
| Schedule editor | chips, time rows, course fields, level picker | chips stadium with check, time rows in a card with big tabular time, course as two date fields, reminder level as segmented, sticky «Сохранить» |
| Settings | flat list with `_Choices`, dividers | account card, grouped cards («Вид», «Напоминания», «Приватность и данные», «Аккаунт»), theme as segmented; data page: consents with dates, export, promo code field + tonal «Применить», delete as a danger row |
| Relative detail | role, medications, notify toggle | 64 avatar header, soft explainer banner, per-medication segmented «Близким / Без названия / Только мне» (owner side), notify toggle, «Закрыть доступ» as danger text button |
| Invite create / ready / accept | role choice, QR, preview | radio-card roles with hints, validity segmented; QR in a white raised frame + validity pill; accept: 72 avatar, what-you-will-see list, stacked «Принять / Не сейчас» |
| History | calendar + legend (D6) | calendar in a card, round day cells with glyphs, centred legend; day detail grouped by time of day with pills and «Принято в …»; report as a sheet with period chips and a privacy banner |
| Family | sections, banners | section headers 18/700, rows in cards with 48 avatars, «Пригласить» primary in header; status pills only for real statuses (paused link, archive: `inactive`), per-person dose pills deferred until a per-profile summary provider exists |
| Empty states | `EmptyState` icon + text | 96 soft disc, headline, body, primary + secondary actions (scan / manual; invite / add ward) |
| Danger dialog | `AlertDialog` | radius 28, danger icon disc, consequences as a list, destructive button first, full width |

## 9. Narrow screens and large text (board `B2-Narrow`)
1. Текст масштабируется полностью (×2.0); отступы, иконки и высоты контролов — нет, контролы растут по содержимому.
2. Заголовок экрана ограничен ×1.5, название в карточке «Сейчас» — ×1.6 (длинное слово «Эналаприл» не должно ломаться); всё остальное — без ограничений; последняя страховка — перенос внутри слова.
3. Действия шапки при ×1.6+ уходят в отдельную строку под заголовок, выравнивание вправо.
4. Кольцо прогресса при ×1.6+ скрыто, вместо него строка «Принято 2 из 5» — тот же смысл текстом.
5. Чипы профилей не переносятся: горизонтальная прокрутка с затуханием у края; выбранный чип всегда первый.
6. Кнопки в паре всегда друг под другом на всю ширину; подпись кнопки переносится, высота растёт (min 56).
7. В строке списка значок-плитка и шеврон скрыты при ×1.6+ (вся строка нажимается); мета-данные — столбиком.
8. Круглая кнопка отметки и статус-пилюля прижаты к верху строки, а не по центру, когда текст в несколько строк.
9. Подписи вкладок ограничены ×1.15 (как в iOS: панель не масштабируется, полная подпись в долгом нажатии); FAB — ×1.3.
10. Нижний отступ списка = высота FAB + 16, чтобы последняя карточка не пряталась.

Flutter: clamps through `MediaQuery.textScalerOf(context).clamp(maxScaleFactor: …)` on the specific `Text` widgets
(titles, hero name, nav labels, FAB); breakpoints from `textScaler.scale(1) >= PillPalSizes.compactRowScale`. Verified by
`ui_matrix.dart` (320×568 and 360×800 at 2.0, RU).

## 10. Font asset plan
**Families.** Manrope (display: titles, numbers) and Golos Text (body, controls). Both are on Google Fonts with
Cyrillic + Cyrillic-ext, both licensed **SIL Open Font License 1.1** (OFL: free to bundle in a commercial app; the licence
text must ship with the font; the reserved font name is not reused).

**Bundled files** (no runtime `google_fonts` download: offline-first, and no request to a third party from RU/EU users):

| File | Weight | Source |
|---|---|---|
| `app/assets/fonts/Manrope-700.ttf` | 700 | Google Fonts download of Manrope (`static/Manrope-Bold.ttf`) |
| `app/assets/fonts/Manrope-800.ttf` | 800 | `static/Manrope-ExtraBold.ttf` |
| `app/assets/fonts/GolosText-400.ttf` | 400 | Google Fonts download of Golos Text (`static/GolosText-Regular.ttf`) |
| `app/assets/fonts/GolosText-500.ttf` | 500 | `static/GolosText-Medium.ttf` |
| `app/assets/fonts/GolosText-600.ttf` | 600 | `static/GolosText-SemiBold.ttf` |
| `app/assets/fonts/GolosText-700.ttf` | 700 | `static/GolosText-Bold.ttf` |
| `app/assets/fonts/Manrope-OFL.txt`, `GolosText-OFL.txt` | — | `OFL.txt` from each family |

If a download ships only the variable `[wght]` file, cut static instances once with
`fonttools varLib.instancer <font>[wght].ttf wght=700 -o Manrope-700.ttf` and note the command in the commit body
(static files keep Flutter weight matching simple and the APK smaller than two variable fonts with all axes).
`pubspec.yaml` gets two `fonts:` families (`Manrope`, `GolosText`) with the weights above; **Rubik and Nunito files and
their OFL texts are removed** in the same PR. Register both OFL texts with `LicenseRegistry.addLicense` so they appear on
the licences page (the app does not do this for Rubik/Nunito today). Expected size: ~6 static TTFs of roughly
60–120 KB each with Latin + Cyrillic (subset further only if the APK budget requires it).

## 11. Open questions for the owner
- Health-data consent: is it required to use the app at all, or only for server sync (local-only mode)? The consent
  board shows it as required for account creation; the backend (5.2a) stores the record either way.
- Copy proposals not yet in the ARB files: «Забыли пароль?» (no reset flow exists), consent texts, «Шаг N из 3»,
  promo-code and export rows (Phase 5 code-only slice), «Все N» profile chip, «Дальше» / «Уже было» headers.
- Reminder level as a 3-way segmented control drops «Будильник» from the editor (kept in Settings → default level):
  confirm, or keep the 4-option chip group.
- Owner-side per-medication privacy on the relative screen changes the privacy for **all** relatives (it is a medication
  property): the board says so in the banner; confirm the wording.
