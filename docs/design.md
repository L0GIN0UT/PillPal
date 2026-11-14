# PillPal design system: «Забота» (B2)

Chosen direction: **B «Забота»** (owner, 2026-11-10; it replaced «Абрикос»). The token spec is
[`docs/design/b2/README.md`](design/b2/README.md); the boards in [`docs/design/b2/`](design/b2/) show every screen.
The redesign (milestones R0-R9) is finished; its plan is [`docs/redesign-plan.md`](redesign-plan.md). This file describes
«Забота» as implemented and is what the code must match; `app/test/theme_test.dart` and `app/test/theme_contrast_test.dart`
pin it. Where the app differs from a board, the difference is listed under "Accepted deviations from the boards".

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
| `actionSoft` / `onActionSoft` | tonal button, soft banner, due pill (not selections) | `DCF0EB` / `074A40` | `1F4A41` / `BDEDE2` | `DCF0EB` / `053F36` | `1F4A41` / `CDF3EA` |
| `selected` / `onSelected` | every selected state: nav indicator with icon and label, selected profile chip, choice button, filter chip, dark segmented thumb, the «Я» avatar | `DCF0EB` / `074A40` (= soft pair) | `5BCDB6` / `05261F` (= action pair) | `DCF0EB` / `053F36` | `7FDCC8` / `05261F` |
| `taken` / `onTaken` | dose taken | `0C6B5D` / `FFFFFF` | `5BCDB6` / `05261F` | `08574B` / `FFFFFF` | `7FDCC8` / `05261F` |
| `takenSoft` / `onTakenSoft` | taken pill, partial calendar day | `C8E8DF` / `074A40` | `285047` / `C6F0E6` | `C8E8DF` / `053F36` | `285047` / `D3F5EC` |
| `missed` / `onMissed` | dose missed | `4652A6` / `FFFFFF` | `A3ADF5` / `161C4A` | `36418F` / `FFFFFF` | `BCC4FA` / `161C4A` |
| `missedSoft` / `onMissedSoft` | missed pill | `E4E7F8` / `2E3880` | `323A5E` / `D5DAFF` | `E4E7F8` / `252E70` | `323A5E` / `E0E4FF` |
| `danger` / `onDanger` | destructive, blocking errors only | `BD2A2A` / `FFFFFF` | `FF8F86` / `3A0A0A` | `981F1F` / `FFFFFF` | `FFB6B0` / `3A0A0A` |
| `dangerSoft` / `onDangerSoft` | danger banner, destructive icon tile | `FBE4E2` / `871D1D` | `4C2C2C` / `FFD3CE` | `FBE4E2` / `751818` | `4C2C2C` / `FFDCD8` |
| `scrim` | modal scrim, used at 48 % | `10201D` | `0B1110` | `10201D` | `0B1110` |
| `hero` / `onHero` | «Сейчас» card | `0C6B5D` / `FFFFFF` | `1F4A41` / `EAF2F0` | `08574B` / `FFFFFF` | `1F4A41` / `F3F8F7` |
| `heroAction` / `onHeroAction` | «Принял» inside the card | `FFFFFF` / `0C6B5D` | `5BCDB6` / `05261F` | `FFFFFF` / `08574B` | `7FDCC8` / `05261F` |

The Material `ColorScheme` is a view of these tokens: `primary` = `action`, `secondaryContainer` / `onSecondaryContainer` = `selected` / `onSelected`,
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

`selected` exists because `actionSoft` on `surface` is under 1.5:1 in the dark palettes, so a selection drawn with it
vanishes. In dark it is the solid `action` pair (selected vs `surface` >= 3:1, `onSelected` vs `selected` >= 4.5, >= 7 in
senior); in light it is the tonal pair, unchanged. A new selected state uses `selected`, never `actionSoft`.

**Accepted light deviation:** in the light palettes the selected chip or nav indicator is only about 1.1:1 against
`surface` (the tonal pair, kept by the owner). It is told apart by the check icon (chips), the 700 label weight and the
rounded shape, never by colour alone, and `theme_contrast_test.dart` applies the 3:1 floor to the dark palettes only.

**Text on soft fills uses only its own `on*Soft` token** (`onActionSoft`, `onTakenSoft`, `onMissedSoft`,
`onDangerSoft`); never `inkMuted`, `missed` or `danger`, which can fall under the floor on those fills. Such pairs are
decorative only (icons, fills). `theme_contrast_test.dart` checks the `on*Soft` pairs and lists the decorative ones.

## Component tokens
Implemented in `app/lib/src/theme/component_themes.dart` (Material themes) and in the shared widgets of `features/common/`
(`StatusPill`, `StatusDisc`, `RoundCheckButton`, `ProfileChips`, `PillPalSegmented`, `PillPalCard`, `PillPalListRow`,
`PillPalBanner`, `SheetScaffold`, `StackedButtons`, `EmptyState`, `ClampedText`). Screens use these and never rebuild them.

| Component | Spec |
|---|---|
| Primary button | `action` / `onAction`, height 52 (senior 64), stadium, `labelLarge` |
| Secondary button | `surface` / `ink`, 1.5 px `border` ring, stadium |
| Tonal button | `actionSoft` / `onActionSoft`, stadium (scan entry, «Применить») |
| Text button | `action`, min 44 x 44 (senior 64 x 64) |
| Danger button | `danger` / `onDanger`, stadium; only in destructive dialogs and the delete row |
| Disabled button | `raised` / `inkMuted` |
| «Сейчас» card | `hero` / `onHero`; «Принял» `heroAction` / `onHeroAction`, 76 high in senior; snooze outline `onHero` at 55 %; radius 28; padding 20 |
| Card (`PillPalCard`) | `surface`, radius 20, level 1 shadow in light (lighter surface in dark), padding 16; `PillPalCard.rows` for divided rows |
| List row | min height 60 (senior 76), padding 10/16, 1 px `border` divider, 40 disc `raised` |
| Chip | height 36 (profile chip 44), stadium; off `surface` + 1 px `border`; on `selected` / `onSelected` + check icon |
| Profile chips | at most 4 visible plus a pinned «Все N» chip; horizontal scroll with a 32 px fade to `background` |
| Status pill / disc | pill height 28, icon 16 + word; disc 40 (senior 52); taken `takenSoft`, missed `missedSoft`, pending 1.5 px `border` + `inkMuted`, skipped `raised`, due `actionSoft`; solid `taken` / `missed` discs in senior |
| Round check | 48 circle, 2 px `outline`; pressed `action` / `onAction` |
| Banner | radius 20, padding 14/16, icon 20; soft `actionSoft`, info `raised` / `ink`, danger `dangerSoft` |
| Input | radius 16, `surface`, 1.5 px `outline`; focus 2 px `action`; error 2 px `danger` + icon + text below |
| Segmented (`PillPalSegmented`) | track `raised` stadium, padding 4, segment min 44; selected `surface` + level 1 + 700 weight (dark: `selected` / `onSelected`, no shadow); radio-list fallback when a label would wrap to 3 lines |
| Switch | 52 x 32; on: track `action`, thumb `onAction`; off: `raised` track, 2 px `outline` ring, `outline` thumb |
| Checkbox | radius 7, 2 px `outline`; on: `action` + check `onAction` |
| Navigation bar | `surface`, top radius 24 (`PillPalRadius.navTop`), height 88 (senior 104); indicator `selected`, radius 16, around icon and label; active label 700 |
| FAB | extended, height 56 (senior 64), stadium, `action` / `onAction`, elevation 2 in light, none in dark |
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
| Times, counters | `textTheme.numeral` (`PillPalText`), `displayMedium` | Manrope 800, tabular figures | 22 / 26 |
| Alarm time (and the time picker font) | `displayLarge` | Manrope 800, tabular figures | 80 / 80 (the picker overrides the size) |
| Body, list row title | `bodyLarge` | Golos Text 400 (500-600 for titles) | 17 / 22 |
| Secondary text | `bodyMedium` | Golos Text 400 | 15 / 20 |
| Help, captions | `bodySmall` (`inkMuted`) | Golos Text 400 | 14 / 19, never below 13 |
| Buttons | `labelLarge` | Golos Text 700 | 17 / 20 |
| Chips, pills | `labelMedium` | Golos Text 600 | 14 / 17 |
| Nav labels | `labelSmall` | Golos Text 500, active 700 | 13 / 16 |

## Radius, spacing, elevation, sizes
- **Radius** (`PillPalRadius`): `sm` 12, `md` 16, `lg` 20, `xl` 28, `pill` = `StadiumBorder`; `navIndicator` 16, `checkbox` 7.
- **Spacing** (`PillPalSpacing`, multiples of 4): `xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 20, `xxl` 24, `xxxl` 32, `huge` 40.
  Inside cards: `card` 16 all round; `cardRow` 16 / 12 (a list row); `cardControl` L16 T12 R16 B16 (a block with a control,
  such as a segmented control, so the control never touches the card edge: `CardControlBlock`, the reminder-level block).
  Tab screens have side padding 16, pushed screens and forms 20, sheets `fromLTRB(20, 8, 20, 28)`. Section header: top 24,
  bottom `md` (the board draws 10, which is off the scale; the plan rounds it to 12).
- **Elevation** (`PillPalShadows`, light only; dark has no shadows): level 1 for cards and the selected segment, level 2
  for FAB, sheets, dialogs and the QR card (two `BoxShadow`s each), `nav` for the top edge of the bar (dark: 1 px
  `border` line). `Card(elevation: 0)` plus a `DecoratedBox`, because Material elevation tints do not match.
- **Sizes** (`PillPalSizes`): button 52 / 64, senior «Принял» 76, round check 48, profile chip 44, nav 88 / 104, FAB 56,
  progress ring 56, status disc 40 / 52, status pill 28, chip 36, list row min 60 / 76, banner padding 14 / 16, FAB 56 / 64,
  empty-state disc 96 with a 44 icon, QR 220, avatars 40 / 48 / 64 (`avatarSm`, `avatarMd`, `avatarLg`).

## Narrow screens and large text (board `B2-Narrow`)
Verified by `ui_matrix.dart` at 320 x 568 and 360 x 800, RU, text x 2.0, and by `narrow_layout_test.dart` on the
Galaxy Z Fold screens (280 x 653 and 344 x 882 cover, 673 x 841 and 884 x 1104 inner) in the real fonts: no overflow,
and no word broken inside to make room for a sibling (text x 1.0 everywhere, x 1.3 on the 344 cover and inner screens;
larger text on the 280 cover is reported only). `NARROW_SHOTS_DIR=<dir>` makes it write screenshots.
1. Text scales fully (x 2.0); paddings, icons and control heights do not; controls grow with their content.
2. The screen title is clamped at x 1.5 and the «Сейчас» name at x 1.6; the last resort is a break inside the word.
3. At x 1.6 and above, and wherever the title does not fit beside them on one line (`BesideOrBelow`), the header
   actions move to their own right-aligned line under the title.
4. At x 1.6 and above the progress ring is hidden; a «Принято 2 из 5» line says the same in text.
5. Profile chips never wrap: horizontal scroll with a fade; the selected chip is always first.
6. Paired buttons always stack, full width; the label wraps, min height 56.
7. At x 1.6 and above, and wherever a word of its text would break beside them (`rowIsCompact` in
   `common/text_fit.dart`), a list row hides its tile and chevron (the whole row is tappable); meta data stacks. Dose
   rows put the status disc and the round check (or the pill) together under the name; equal-width choices stack;
   the month label goes above its arrows. The rows of one card or list switch together (`CompactGroup` in
   `common/compact_rows.dart`; `PillPalCard.rows` and the medication list use it), so siblings look the same.
8. The round check and the status pill stick to the top of a multi-line row, not the centre.
9. Tab labels are clamped at x 1.15 (full label as tooltip); the FAB label at x 1.3.
10. The bottom padding of a list is the FAB height plus 16.

Clamps use `MediaQuery.textScalerOf(context).clamp(maxScaleFactor: ...)` on the specific `Text`; breakpoints use
`textScaler.scale(1) >= PillPalSizes.compactScale`.

## Pinned and inline actions (R6b)
- **Forms pin their one primary action** at the bottom, outside the scrolling list (`PillPalSpacing.sheet` padding): invite create, managed profile «Сохранить». It stays in reach however long the content or large the text.
- **Detail and result screens keep actions inline**, directly after the content: relative detail, invite ready, accept preview and accepted. Their buttons are `StackedButtons`.
- **Destructive starts are quiet.** «Отключить» (both directions on the relative card) and «Удалить профиль» are danger text buttons (`dangerTextButton`); the confirmation dialog (`confirmAction`) carries the weight with the solid `danger` button.

## History (R5; boards `B-History`, `B2-HistoryDay`, `B2-ReportSheet`, `B2-ReportReady`, `B2-MyReports`)
Where the app deliberately differs from the boards:
- **Calendar cells.** A day is a round disc as wide as its column (36-42 px on a phone), inside a tappable that keeps the
  full target height (44 / 64): the one exception to the width rule of touch targets, because seven columns share the
  screen. A partial day has a 1.5 px `taken` hairline so the pale disc stays visible. The glyph in a cell is dropped
  when the numeral and the glyph do not fit the disc at the current text scale; the legend and the semantics label
  carry the status.
- **Second numeral.** The board shows the number of missed doses; the app keeps the streak of days without misses.
  Numerals use the `numeral` token (22), not 28.
- **Day summary** counts scheduled doses only, like the monthly percentage; as-needed intakes are listed but not
  counted. The status pill sits under the entry text; "Taken at 08:04" is the pill's label.
- **Report presets** are 7 / 30 / 90 days and a custom range; there is no «Этот месяц».
- **Report button** is the header action (`history-pdf`); the day view is inline under the calendar and scrolls into
  view when a day is selected.
- **Report sheet is two states** (ADR 0019). «Создать» (`report-create`) makes and keeps the PDF, then the same sheet shows
  «Отчёт готов»: the period and "who · PDF · size", then three stacked buttons «Открыть» (primary, `report-open`),
  «Сохранить» (`report-save`), «Поделиться» (`report-share`), an info banner that a saved or sent file is outside the
  app's control, and the link «Мои отчёты (N)» (`report-history`) that closes the sheet and opens `/reports`.
  A modal sheet covers the screen's snack bars, so the result of an action is a live-region banner inside the sheet,
  above the buttons (`report-notice`; the title is a live region too, the active button shows a spinner): «Отчёт сохранён» (soft), «Нет приложения для просмотра PDF» with a «Сохранить» action, busy and
  failure (danger); a cancelled picker says nothing. Never a name, date or detail from the report in these messages.
- **«Мои отчёты»** (`/reports`, from Settings › Приватность и данные, key `settings-reports`): one card of rows,
  newest first. A row is the period, "who · when made · size", a ⋮ menu (Открыть, Сохранить, Поделиться, Удалить; items
  are as tall as the touch target of the mode via `pillPalPopupItem`; no confirm for one, a snack bar «Отчёт удалён»
  follows; the menu is its own semantics node, `PillPalListRow.trailingIsControl`) and opens the report on tap (`report-item-<id>`, `report-item-menu-<id>`). «Удалить все»
  (`reports-delete-all`, danger text button) sits in the app bar and asks first; from the compact text scale on it moves
  under the list (title and button do not fit). Empty: `reports-empty` with the retention note. The list is reconciled
  with the disk when the screen opens. Here the result is a snack bar (no sheet covers it).

## «Добавить близкого» (relatives redesign, ADR 0020)
- **One screen, one direction** (`/family/add`, from the Family header «Добавить» and the empty state). The data owner
  picks the role first: the box «Может менять мои лекарства» (`add-relative-editor`, off = observer, on = helper) sits
  above the disclosure, which is built for that role (`invite-disclosure`). «Показать мой код»
  (`add-relative-show-code`) confirms exactly that screen (`disclosure_version` 1) and shows the QR panel; whoever
  scans it sees the owner's medications. Changing the box while the code is shown hides it, revokes it even if it
  was shared and asks for the confirmation again. «Вам показали код?», «Сканировать код» and «Нет смартфона? Веду сам»
  are shown only before a code. No name fields.
- **QR panel** (`InviteCodePanel`, also used by the invite screen of a managed profile): the code in the white frame
  (scaled down, never cut, on a screen narrower than 260 px; spinner and icons in it use the light palette,
  `qrFramePalette`), a neutral pill «Код действует ещё N мин» (seconds only in the last minute, tabular figures,
  spoken as minutes and seconds in words, not a live region; `invite-countdown`, its own widget so the QR does not
  rebuild), counted from the server's `created_at` / `expires_at`. One stack of buttons: «Поделиться ссылкой»
  (`invite-share`; the link is rebuilt from the token and the region host, the message says the minutes left) or
  «Обновить код» (`invite-refresh` after expiry, `invite-retry` after a failure, the same button), then «Готово». The
  expiry pill is a live region. The state is polled every 3 s only while the screen is visible and the app in front;
  on return it asks at once. On `consumed` the panel gives way to «{name} теперь в ваших близких» (`relative-added`,
  a live region) with «Роль: …» and «Это не он? Отозвать» (`relative-added-revoke`, with confirmation), named only
  when exactly one new link appeared. A code never shared is revoked when it is replaced or the screen is left.
- **Scanner** (`InviteScanSheet`, `SheetHeader` shared with the pack scanner; «Сканировать код», `add-relative-scan`;
  also `accept-scan` on the paste form): the pack scanner's viewfinder with the square `scanFrameQr` and QR codes
  only. Anything but our invite link is «Это не код PillPal» (`invite-scan-notice-notPillPal`), the other region says
  so; the camera stops at the first valid code, which goes to the invite intake and the accept screen. Without a
  camera the sheet offers «Вставить ссылку».
- **Accept screen**: «{name} открывает вам свои лекарства», the masked e-mail on its own line «Аккаунт: x***@mail.ru»
  (`invite-preview-email`, never joined with the name, which is chosen freely), and an info banner «Принимайте,
  только если код показал знакомый вам человек» (`invite-preview-caution`).
- **Roles in copy**: viewer «Наблюдатель» / "Observer", editor «Помощник» / "Helper". Managed profiles are «Нет
  смартфона? Веду сам» on the add screen and in the empty Family tab, both opening the managed profile form.

## «Близкие» list and relative card (relatives redesign, ADR 0020 §4)
- **One list.** The Family tab has no sections any more: one row per person or managed profile (`buildRelatives` in
  `family/relatives_list.dart`, pure), whatever links tie the account to them. A person related both ways is one row.
  Order: managed profiles, then the people I see, then the people who only see me. Under the list: «Нет смартфона?
  Веду сам» (`add-ward`), «Принять приглашение» (`accept-invite`), the limit notice at the relatives limit and the
  privacy note. The new-relative banner and the push hint stay above the list.
- **Row** (`relative-<key>`; the key is the subject profile id: the person's self profile or the managed profile, the
  link id when the server names no profile): «{заметка} ({имя})» with a note, else the name; under it the roles, comma
  separated: «подопечный» (I see them as viewer), «подопечный · могу менять» (editor), «наблюдатель» / «помощник»
  (they see mine; «· {профиль}» when the link is on a managed profile of mine), «опекун · {профиль}», «веду сам» (my
  managed profile), «веду вместе с {владелец}» («веду вместе» when the owner is not named: I am a guardian of
  someone's managed profile). The day pill as before (only where I see data), «не активен» when every link is paused
  (an incoming one too: then no day, the tap opens the card), «архив» for an archive. Tapping opens their day when I
  see it, else the card; the pencil (`relative-edit-<key>`, tooltip «Открыть карточку: {имя}», the plain name) always
  opens the card. The row reads note, name, roles and status as one button.
- **Avatar letter is the person's.** The avatar of a row and of the card takes its letter from the person's or
  profile's name, never from the note («Сын (Иван)» shows И); a nameless person shows the person icon
  (`avatarName` of `PillPalPersonRow` and `RelativeDetailHeader`).
- **Card** (`/family/relative/<key>`, `relative-card`; the old `/family/link/<id>` opens the same card, also after a
  refresh re-keys the row): the 64 avatar header with the display name and the roles, then the private note while a
  link relates us: a field «Заметка» with the helper «Видна только вам. Например: Сын» (`relative-note-field`, the
  shared filter: 1-20 visible characters on one line), «Сохранить заметку» (`relative-note-save`, outlined, off
  while unchanged) and «Удалить заметку» (`relative-note-clear`, text) in `StackedButtons`. Saving is online only
  (`PUT`/`DELETE /v1/relative-notes/{id}`): offline the danger banner «Заметку можно изменить только онлайн»
  (`relative-note-error`, live region) and nothing changes on the device; success is a soft live-region banner
  (`relative-note-done`). Below, one block per link under a section header: «Вы видите их лекарства» (the banner
  «Ваша роль: …» says my role in the second person, alerts about missed doses, «Открыть», «Отключить» = leave),
  «Видит ваши лекарства» / «Видит профиль: …» (privacy per medication, role with the disclosure, «Отключить» =
  revoke), and for a managed profile «Этот профиль ведёте вы» with «Открыть» and «Изменить профиль»
  (`relative-managed-edit`).
- **One verb: «Отключить».** Both blocks end with the same danger text button (`disconnectButton`, link-off icon, in
  the block's `StackedButtons`), read with its direction («Отключить: вы видите их лекарства» / «Отключить: видит
  ваши лекарства»). The dialog is «Отключить {имя}?» with the confirm «Отключить». Ending one direction of a mutual
  relative keeps the card open; it closes when nothing relates us any more. A changed role keeps the card open too.
- **Privacy.** Notes are the author's free text and may carry health context: the cache (`relative_notes`, replaced
  with every refresh of the links, wiped with the account) is never logged, and a note never goes into a route,
  analytics or a push.

## Settings account card
- **No region line** (owner decision 2026-11-11, as on registration): the card shows the avatar and the e-mail only
  while the region cannot be chosen in the app. Where data is stored stays in the privacy policy.

## Platform visuals (R8)
- **Notification accent.** Android notifications carry `color` = the light `action` (`0C6B5D`, the constant `reminderAccent` in
  `reminders/reminder_accent.dart`, pinned to `PillPalPalette.light.action` by a test) on every level's channel. Payload, text, channel, importance and actions are
  unchanged; the shade is not themed by the app, so one accent serves light and dark.
- **Launch window.** `android/app/src/main/res/values/colors.xml` and `values-night/colors.xml` define
  `launch_background` = the palette `background` (`F2F6F5` light, `202A28` dark). Both `launch_background.xml`
  drawables and the `NormalTheme` window background use it, so there is no white flash before the first frame.
  `test/android_launch_colors_test.dart` keeps the XML equal to the palette.
- **Brand assets (owner logo, 2026-11-11).** The "P" monogram is `docs/design/brand/pillpal_monogram.svg` (one even-odd
  path, `#293F3C`, viewBox `80 75 350 350`). Android only for now; iOS icons are not set.
  - Launcher: adaptive icon (`mipmap-anydpi-v26/ic_launcher.xml`), foreground `drawable/ic_launcher_foreground.xml`
    (the path inside a group: glyph 50 dp tall in the 108 dp canvas, within the 66 dp safe zone), background colour
    `ic_launcher_background` = `F2F6F5` (the light `background`; the monogram on it has about 10:1 and white would vanish
    on light wallpapers; it is fixed and does not follow dark mode), `<monochrome>` layer for Android 13 themed icons. Legacy PNGs (API 24-25) are generated by
    `app/tool/gen_launcher_icons.dart` (pure Dart, see `app/README.md`).
  - Notification small icon: `drawable/ic_stat_pillpal.xml`, white monogram, 24 dp; listed in `res/raw/keep.xml`; the
    notification keeps `color` = `reminderAccent`. The native alerts plugin (relatives' alerts) uses the same drawable
    by name and the same accent, never the adaptive launcher icon (opaque background, it would show as a blob).
  - In the app: `PillPalMonogram` (`lib/src/theme/brand/pillpal_monogram.dart`, a painter built from the same path
    data; `test/theme/pillpal_monogram_test.dart` keeps it equal to the SVG and to the Android vectors). Only the
    Welcome brand tile uses it: 48 square, `control` radius (16; the board shows 14, accepted), no fill, 2 px `ink`
    border, monogram in `ink` in a 32 box (`PillPalSizes.brandGlyph`) centred in the tile, so the glyph is about 27 px,
    as on the board. Other
    places keep `Icons.medication_outlined`. The iOS `AppIcon` is still the old placeholder (the first release is
    Android only).
- The full-screen alarm board (B2-Alarm) is not built: it needs a full-screen-intent surface and a lock-screen
  privacy decision, so it is a separate notifications milestone.

## Motion
The tokens and the rule per change are the table in [`docs/design/b2/README.md`](design/b2/README.md) ("Motion"); this
section says where they live in code.
- **Tokens:** `PillPalMotion` (`app/lib/src/theme/motion.dart`): `fast` 150 ms, `base` 250 ms, `slow` 350 ms, `stagger` 40 ms,
  `standard`, `emphasizedDecelerate`. Under `features/`, `check_ui_tokens.py` fails a `Duration(...)` with `milliseconds:`
  or `microseconds:` in any argument, `Curves.*`, `Durations.*`, `Easing.*`, `kThemeAnimationDuration` and a `Cubic(` or
  `Interval(` that starts with a number; a sub-second `Duration` that is not an animation (a tap guard) carries
  `// ui-literal-ok: <why>` on the line of the literal.
- **Reduced motion:** `PillPalMotion.reduced(context)` reads `MediaQuery.disableAnimations`; it is the only reader.
  Screens and tabs fade only, state changes are instant, banners and menus fade. Senior mode has no motion rules of its own.
  On a device the same system flag also makes Flutter run every `AnimationController` with the default behaviour at 5 %
  of its length, so route, dialog and bottom sheet transitions are near-instant rather than a `fast` fade. This is
  accepted: the user asked for no motion. Only `TabPager` keeps a real `fast` fade (`AnimationBehavior.preserve`). Tests
  of route, dialog and pager motion set the flag the device way (`FakeAccessibilityFeatures(disableAnimations: true)`);
  tests of our own reduced-motion branches may set `MediaQuery.disableAnimations` on a subtree.
- **Screens:** `PillPalPageTransitionsBuilder` in the theme (slide from the right and opacity .6 to 1; back is the reverse
  with `standard`), on every platform but iOS (see the deviations below). The targets of redirects fade
  (`_fadePage` in the router: the loading screen, the consent gate, the tab shell, welcome and sign-in), in `base`, or
  `fast` with reduced motion.
- **Tabs:** `TabPager` (`features/shell/tab_pager.dart`), the `navigatorContainerBuilder` of the shell: a real page turn,
  both pages one full width in sync, no fade, scale or parallax; the navigation bar stays; every branch keeps its state.
  Only the selected page is in the semantics tree and focusable; the page being left takes no taps, the entering one
  takes them at once. Choosing the page being left mid-turn plays the turn backwards; a third tab starts a new turn from
  where the page being left is, the new page glued to it, and the first page of the old turn goes at once. The turn is
  not mirrored for right-to-left locales (the app ships RU and EN).
- **Sheets and dialogs:** `showPillPalSheet` (`PillPalMotion.sheet`) and `showPillPalDialog` (fade and scale from 0.96;
  the scrim of the dialog theme and closed-loop focus, like `showDialog`); call these, not `showModalBottomSheet` or
  `showDialog`. Menus: `popUpAnimationStyle: PillPalMotion.menu`.
- **In-screen states:** `PillPalAppear` (banners), `ExitingRows` (a removed row fades and collapses, out of the semantics
  tree and focus at once; rows removed together leave one `stagger` apart, capped so a whole clear ends within `slow`;
  with a `separator` the hairline goes with its row; the builder gets an empty list after the last one, which is where
  «Мои отчёты» shows its empty note), `ContentSwap` (the report sheet: the old content fades out alone in `fast`, then
  the sheet resizes while the new one fades in in `base`: 400 ms in all, longer than `slow`, because the two steps are
  the rule), `StatusDisc` and `RoundCheckButton` colours (the round button eases its fill and check itself).
- **Not built yet:** the snack bar keeps the Material entrance (the rule asks for 16 px up and a fade in `base`), and the
  dose row and the «Сейчас» card change to the taken colours at once (only the check disc and the round button ease).
  Filled, outlined and text buttons change their tint (pressed, enabled, disabled) at once: Material animates only their
  shape and elevation in `animationDuration`, and a custom button is not worth it. The overflow menu runs Material's own
  animation in the `PillPalMotion.menu` timing, not our curve shape. Checkboxes, switches and chips use Material's
  instant state changes. The system date and time pickers keep the Material dialog motion.

## Accepted deviations from the boards
- **Header actions on Today** keep `today-add` («+») and the settings gear that the boards omit: journeys tap them and
  Settings has no other entry; at text scale 1.6 and above they move to their own line (R3).
- **Reminder level is app-wide** (R4b, owner decision). One setting in Settings: a three-option segmented control
  (quiet / normal / persistent) plus a separate «Будильник» switch, mapped onto the unchanged `ReminderLevel`
  (switch on = `alarm`, shown as «persistent»). The per-medication picker is gone and old per-medication overrides are
  cleared once, with a quiet «level migrated» banner. In RU at x 2.0 on 320 px the segmented control falls back to a
  radio list, because a label would wrap to three lines.
- **No region choice on Welcome.** A build serves one region, so Welcome shows no region card and no other-region
  note until the region phase; the primary and secondary buttons are pinned to the bottom.
- **Today summary.** The line «Всё принято» (and «Всё на сегодня принято» in the card) replaces the ring text when
  every dose of the day is marked; at text scale 1.6 and above the ring is hidden and «Принято N из M» says the same.
- **Family day status (R9).** Each person row on the Family tab shows a status pill: «Всё принято» (taken or
  deliberately skipped), «N пропуск» (missed, iris) or a waiting state, plus «Следующий приём в HH:MM». The numbers come
  from the local database with the day view's privacy projection (`hidden` excluded, `anonymous` by time and status
  only); stale data shows «Обновлено N назад» instead of a wrong status; a day with no doses shows nothing.
- **Password reset** (D2) and the **privacy editor on the relative screen** (D4, applies to all relatives at once, the
  copy says so) are part of the redesign; consent at registration (D1), data export, promo and OAuth buttons are not
  drawn until their flows exist.
- **History, forms and sheets** differ as listed under History and Pinned and inline actions.
- **iOS screen transition.** iOS keeps `CupertinoPageTransitionsBuilder` instead of the app's slide and fade: it carries
  the edge swipe back, which iOS users expect and which the app's transition would lose.

## Fonts
Bundled static TTFs in `app/assets/fonts/`, no runtime download (offline-first; no request to a third party from RU or EU
users): `Manrope-700/800.ttf` and `GolosText-400/500/600/700.ttf`, with `Manrope-OFL.txt` and `GolosText-OFL.txt`. The
licence texts ship with the fonts and are added to the licence page by `registerFontLicenses()`
(`lib/src/theme/font_licenses.dart`, called from `main.dart`). Rubik and Nunito are removed.
The files are the `[wght]` variable fonts of `google/fonts` (`ofl/manrope`, `ofl/golostext`) cut with
`fonttools varLib.instancer <font>[wght].ttf wght=<weight> -o <name>-<weight>.ttf`; every file was checked for the full
Cyrillic range (А-я, Ёё), digits and the `tnum` feature. `test/fonts_test.dart` pins the families, weights and licences,
reads the `cmap` of every file (Cyrillic, digits, punctuation, № ₽ € × ° − and NBSP in Golos Text; digits in Manrope) and
checks that every face a theme slot uses is declared in `pubspec.yaml`.
The PDF report (`report_pdf.dart`) embeds `GolosText-400/700`.

## Rules for code
- Use the tokens (`PillPalPalette`, `PillPalRadius`, `PillPalSpacing`, `PillPalSizes`, `textTheme`, `PillPalShadows`);
  a missing token is reported, not invented. `.github/scripts/check_ui_tokens.py` counts raw literals under
  `app/lib/src/features/**` and is strict: any literal fails the build, a justified one needs
  `// ui-literal-ok: <reason>`, and `app/tool/ui_literals_baseline.json` must stay `{}` (a non-empty one fails `check`;
  self-tests in `check_ui_tokens_selftest.py`). The retired
  aliases (`PillPalSizes.cardRadius` / `controlRadius` / `sheetRadius` / `statusSquare`, `InfoNote(`,
  `TodaySummaryCard(`) are deleted; any use is a hard failure that no baseline or comment excuses.
- Every screen has a `pumpUiMatrix` test: {light, dark} x {normal, senior} x {ru, en} x {1.0, 2.0} x {360 x 800, 320 x 568}.
- Keys used by `integration_test`, `test_driver` and `test_e2e` stay (`docs/redesign-plan.md`, "Keys and types that must
  survive").

## Boards
Chosen: `B2-*.dc.html` and the `B-*.dc.html` references in [`docs/design/b2/`](design/b2/). `B2-Components` (light and dark) and
`B2-Narrow` apply to every screen. Screens: Welcome, SignIn, Register, Consent, Notification, Alarm, AddMedication,
ScanCamera, ScanManual, Schedule, Settings, SettingsData, RelativeDetail, InviteCreate, InviteReady, InviteAccept,
HistoryDay, ReportSheet, EmptyMedications, EmptyFamily, DangerDialog, TodaySeniorDark. The boards load Google Fonts from
a CDN for rendering only; the app never does.
