# UI consistency pass — delivery plan

Owner request 2026-11-09 (CLAUDE.md "Current phase"). Goal: every screen under `app/lib/src/features/**` uses
the «Абрикос» tokens and shared widgets (`docs/design.md`, design canvas "Дизайн-система PillPal"), in light/dark,
normal/senior, RU/EN. Also in scope: scan entry on the Medications screen (deferred from 4.11,
`docs/phase4-plan.md` §4.11). Out of scope: new screens, copy rewrites, the Phase 5 ad placement,
schedule/sync/dose-state semantics (none change).

## Requirements
- One scale for spacing (multiples of 4), radii (12/16/18/24), colours (palette only) and type (`textTheme` only).
- One shared widget per concept: section header, bottom sheet, banner/notice, choice group, empty state, dialog.
- Senior mode (×1.3 text, targets ≥ 64, text contrast ≥ 7:1), dark theme and both locales render without overflow.
- A CI guard that stops new raw literals under `features/`.
- Medications screen gets a scan entry that opens the existing `ScanSheet` flow.
- No behaviour change. Every `Key` and widget type used by tests and emulator journeys stays.

## Decisions (owner, 2026-11-10)
- **D1 Radii.** The design canvas states "Радиусы 12 / 16 / 18 / 24". Mapping: card 20 → **18**; buttons and fields
  **16**; chips, calendar cells, badges and small icon tiles 14/12/10 → **12**; dialogs, sheets and senior cards
  22/24/28 → **24**. Pills (`999`, `StadiumBorder`) stay as the choice-chip shape from the canvas.
- **D2 Senior contrast ≥ 7:1.** Separate senior palettes `PillPalPalette.lightSenior` / `darkSenior`, selected by
  `buildPillPalTheme(senior: true)`. Normal palettes do not change. Light senior uses darker shades of the same hues
  (e.g. `inkMuted` #574A44, `action` #8F3A12, the canvas's deep apricot), chosen so every text/background and
  on*/state pair is ≥ 7:1; the dark palette already passes for most pairs and only the failing ones get a senior
  shade. The theme test enforces the ratios, not the hex values.
  Final values (UI-1, awaiting owner approval): light senior `inkMuted` #574A44 (8.0:1 on `bg`), `action` #8F3A12
  (7.6:1 with white, 7.1:1 on `bg`), `taken` #2F5C45 (7.7:1 with white), `missed` #285280 (8.1:1 with white), `danger`
  unchanged #9E2B25 (7.0:1 on `bg`); dark senior = dark with `taken` #8CC2A5 (7.6:1 on `surface`, `onTaken` #1C1715
  8.8:1) and `danger` #F5A08F (7.6:1 on `surface`). The test also checks the state colours as text on `bg`/`surface`
  and `inkMuted` on `actionSoft`; the only normal-mode exception is light `action` on `bg` (4.35:1, ≥ 4.3 asserted).
- **D3 Danger colour tuned to «Абрикос»** (owner asked for values to approve; proposed):
  - light `danger` **#9E2B25** (brick red: 7.0:1 on `bg`, 7.4:1 on `surface`; darker than `action` #C2531E, so the two
    differ in lightness, not only hue), `onDanger` #FFFFFF (7.4:1);
  - dark `danger` **#F28B7D** (7.4:1 on `bg`, 6.5:1 on `surface`; darker than dark `action` #F4A57A), `onDanger`
    #1C1715.
  - `colorScheme.error`/`onError` read from them. "Missed" stays blue (`missed`), never danger: danger is for
    destructive actions and blocking problems only, always with an icon and a label.
- **D4 Scan entry.** `FloatingActionButton.extended` «Сканировать» on Medications (own and editable profiles,
  catalog flag on); «+» stays in the AppBar.
- **D5** UI-9 may add the radius, spacing, danger and component rows to `docs/design.md`.
- **D6 History calendar (owner, 2026-11-10: variant A).** One sage scale: all taken `taken`, partial a light sage
  `takenSoft` #B9D3C3 with `ink` text (9.6:1), days with misses `missed`; the legend is centred and uses round
  markers. The peach partial colour goes. `takenSoft` is added to the palettes in UI-8 (dark and senior shades
  chosen there by the same contrast rules).
- **Approval.** The owner approved the D2 senior values and the D3 danger values on 2026-11-10 (design canvas,
  boards "Палитра для старших и цвет ошибки", "Сегодня — режим для старших, светлая тема", "Цвет ошибки").
- Values that are not multiples of 4 (2, 6, 10, 14, 18, 22) round to the nearest token. Shifts of ±2 px are
  accepted; the reviewer compares neighbouring screens, not pixels.

## Inventory (main @ 4a9fc6e, `app/lib/src/features/**`)
E = `EdgeInsets.*` with a numeric literal; S = `SizedBox(height|width: N)`; R = `Radius/BorderRadius.circular(N)`;
W = Wrap `spacing`/`runSpacing`, `Divider(height:)`, icon `size:`; C/T = `Colors.*` / `Color(0x` / `TextStyle(`.
Totals: E 69 · S 134 · R 20 · W 31+ · C/T 3 (`report_pdf.dart` excluded: it renders a PDF, not Flutter UI).
Token-clean already: `catalog/**`, `medications/medication_{form_view,sections}.dart`,
`common/{gap,info_note,icon_label,status_message,pillpal_icon_button}.dart`.

| Feature | E | S | R | W | C/T | Ad-hoc components |
|---|---|---|---|---|---|---|
| today | 15 | 23 | 11 | 4 + 3 icon sizes | 1 | `_Header`; `LowStockBanner` (`TextStyle(color:)`); two ListTile action sheets (dose_tile, today_senior); 8 BoxDecorations; radii 14/16/20/22/24/28 |
| family | 23 | 45 | 0 | 9 | 1 (QR white, allowed) | `FamilySectionHeader`; three banner looks (archived_profile, new_relative, push_unavailable); two screen paddings |
| auth | 6 | 16 | 3 | – | 1 | `AuthErrorBanner`, `AuthNotice` (Container + BoxDecoration); welcome feature rows (radius 18) |
| schedule | 7 | 11 | 0 | 8 | – | `colorScheme.error`; chip wraps with 6/4 spacing |
| history | 7 | 10 | 3 | 4 | 1 | calendar cells radius 12/4; legend spacing 14/6 |
| settings | 2 | 9 | 0 | 5 | – | `_Choices`; `Divider(height: 32)` ×3; group labels; `colorScheme.error` ×2; ad-hoc `AlertDialog` |
| reminders | 1 | 7 | 0 | 3 | – | `colorScheme.error`; permission card is a fourth banner look |
| medications | 4 | 5 | 1 | – | – | card radius 20; empty-state `SizedBox(height: 360)`; list gap 10 |
| report (sheet) | 1 | 5 | 0 | 2 | – | copy of `PillPalSpacing.sheet` |
| stock | 1 | 1 | 0 | – | – | ad-hoc `AlertDialog` |
| shell | 1 | 2 | 0 | 1 | – | `EmptyState` icon 56, padding 32 |
| common | 1 | 0 | 2 | – | – | `ChoiceButton` radius 14 |

The chip-group pattern (Wrap 8/8 + `ChoiceButton`s) is repeated in settings_screen, today_screen,
profile_switcher, invite_create_screen, reminder_level_picker, report_sheet, relative_detail_screen and
schedule_widgets.

## Token and widget additions
Tokens (`app/lib/src/theme/`):
- `radius.dart`: `PillPalRadius { sm = 12; md = 16; lg = 18; xl = 24; }` plus `BorderRadius` constants `card`,
  `control`, `chip`, `sheetTop`. `PillPalSizes.cardRadius`/`controlRadius`/`sheetRadius` delegate to it as deprecated
  aliases until UI-9. `cardTheme` → lg; `dialogTheme` and `bottomSheetTheme` → xl.
- `spacing.dart`: `PillPalSpacing.screen = fromLTRB(xl, sm, xl, xxl)` (list tabs), `tabHeader = fromLTRB(xl, xxl, xl,
  xxl)` (Today/Family header), `chips = sm`.
- `PillPalSizes`: `iconInline = 20`, `iconSenior = 28`, `iconHero = 40`, `iconEmpty = 56`, `qrCode = 240`,
  `emptyStateMinHeight = 360`.
- `palette.dart`: `danger`/`onDanger` (D3); senior palettes (D2).

Shared widgets (`app/lib/src/features/common/`, one public class per file):
- `section_header.dart`: `SectionHeader(String title, {Widget? trailing, bool first = false})` (titleLarge, top
  `xxl` or 0 when `first`, bottom `sm`); `GroupLabel(String text)` in `group_label.dart` (titleSmall +
  `Gap.v(sm)`, a plain label, not a semantic header). Replaces `FamilySectionHeader` (alias until UI-6a).
- `sheet_scaffold.dart`: `showPillPalSheet<T>(context, builder)`; `SheetScaffold({title, children, primaryAction,
  titleKey})`; `ActionSheet({title, subtitle, items})` in `action_sheet.dart` for the dose/senior menus
  (`ActionSheetItem` is data: its `key` goes to the tile). Sheets use `useSafeArea`; titles are semantic headers.
- `pillpal_banner.dart`: `PillPalBanner({icon, title, body, tone, actions, bodyKey, liveRegion})`, `BannerTone`
  (`banner_tone.dart`) `soft` / `info` (palette `info`) / `danger`. The icon is decorative, so the text must name the
  problem; the banner has no outer spacing. `InfoNote` stays for neutral notes. (Superseded by the «Забота» redesign: `InfoNote` was removed in R8; use `PillPalBanner(tone: info)`.)
- `choice_group.dart`: `ChoiceGroup<T>({options, selected, onSelected, keyOf})` and `ChoiceGroup.multi`
  (`selectedValues`, `itemWidth` as a minimum width); keeps per-option keys (`level-*`, `slot-*`, ...).
  `PillPalSizes.outline = 2` and `PillPalPalette.info` are added with them.

## Milestones (PRs ≤ ~600 changed lines; branch `feat/ui-pass-<n>-<slug>`)
Shared test helper (UI-2): `app/test/support/ui_matrix.dart` — `pumpUiMatrix` runs a widget over
{light, dark} × {normal, senior} × {ru, en} at text scale 1.0 and 2.0 on 360×800 and 320×568 screens and asserts
no exception/overflow (not vertical overflow inside scrollables); `expectTouchTargets: true` also checks every
tappable against the touch target of the mode. Every
screen PR adds one matrix test per screen it touches. No goldens.

- **UI-1 Tokens, palette, guard (ratchet).** `theme/{radius,spacing,palette,app_theme}.dart`, `test/theme_test.dart`,
  `.github/scripts/check_ui_tokens.py` (+ self-test), `app/tool/ui_literals_baseline.json`, one step in `app.yml`.
  Tests: spacing multiples of 4; radii ∈ {12,16,18,24}; theme shapes use `PillPalRadius`;
  `colorScheme.error == palette.danger`; contrast ≥ 4.5:1 (normal) and ≥ 7:1 (senior) for text/bg and on*/state
  pairs in both themes. Guard: scans `features/**/*.dart` (minus `report_pdf.dart`) and
  counts one literal per occurrence of: a non-zero number in `EdgeInsets.*(`/`EdgeInsetsDirectional.*(`; the own
  top-level `height|width` of `SizedBox`, `SizedBox.square(dimension:)`, `Divider`/`VerticalDivider`
  `height|width|thickness|indent|endIndent`; `Radius.circular(N)`; `Icon(size:)`, `IconButton(iconSize:)`,
  `CircleAvatar(radius:)`; Wrap `spacing/runSpacing: N`; `Color(0x`, `Color.fromARGB|fromRGBO`, `Colors.` (except
  `transparent`), `.withOpacity(N)`, `.withValues(alpha: N)`; `TextStyle(fontSize:)`, `copyWith(fontSize:)`,
  `FontWeight.wNNN`; the deprecated `PillPalSizes.*Radius` aliases. A number that is an operand of arithmetic on a
  token (`PillPalSpacing.md * 2`) does not count; strings are ignored. Inline escape `// ui-literal-ok: <reason>` in
  a real comment on the literal's own line; per-file ratchet baseline that may only go down (stale baseline fails;
  `--update` lowers it, never raises). Call sites of the aliases are migrated; the aliases stay until UI-9.
- **UI-2 Shared widgets** + `ui_matrix.dart`; no feature file changes.
- **UI-3 Settings, reminders, common dialogs** (`_Choices` → `ChoiceGroup`, `GroupLabel`, danger, permission card →
  `PillPalBanner` with the tone picked per state (blocking permission: danger; hints: soft), dialogs follow
  `confirmAction`, `ChoiceButton` radius sm; `reminder_level_picker` moves from `ChoiceChip` to `ChoiceButton`, an
  accepted drift).
- **UI-4 Auth and shell** (`AuthErrorBanner`/`AuthNotice` → `PillPalBanner`, keeps `Key('auth-error')`;
  `AuthErrorBanner` becomes the danger (outlined) look, `AuthNotice` the info look; `EmptyState`).
- **UI-5a Today (normal)** and **UI-5b Today (senior)**.
  UI-5a: `DoseTile` picks its layout by width (status beside the text while it fits next to a minimum summary width
  that grows with the text scale, else under it, end-aligned). UI-5b: senior Today should use the same stacked
  arrangement (time above the name, action below) instead of its own.
- **UI-6a Family list, banners, switcher** and **UI-6b Family invites and detail screens** (QR keeps white with
  `ui-literal-ok`). UI-6a: banner keys move from the inner `Card` to the `PillPalBanner` itself; grep tests for
  `archive-banner`, `new-relative-banner`, `push-unavailable-hint` before migrating.
  UI-6b: the invite disclosure block becomes a soft `Card` per the canvas. `PillPalSpacing.listGap` (= md, 12) is the gap
  between list cards (added in UI-6a); UI-7 moves the Medications list from its 10 px gap to `listGap`.
- **UI-7 Medications, schedule, scan entry** (D4: `Key('medications-scan')`, pushes `addRoute?scan=1`,
  `CatalogSection(autoScan: true)` calls the existing scan once after the first frame; list bottom padding for the
  FAB; closes the 4.11 deferral).
- **UI-8 History and report sheet** (the report sheet's "custom" period needs the caller to branch in
  `onSelected`; D6: sage scale with `takenSoft`, centred legend with round markers).
- **UI-9 Lock-in and docs** (superseded 2026-11-10 by the «Забота» redesign, `docs/redesign-plan.md`): empty baseline, strict guard, remove aliases, `docs/design.md` rows (D5),
  the header date is 14/600 (`bodySmall`) while the canvas shows 15/600: decide one theme style for the Today,
  Family and Medications headers;
  `ui-consistency-reviewer` mentions the guard; `docs/design.md` also gets a banner row (soft / info / danger);
  one full polish review with no blocker.

## Risks
- Emulator journeys and tests depend on keys and types. Keep: `welcome-register`, `auth-*`, `today-add`,
  `med-name`, `med-save`, `slot-time-*`, `schedule-save`, `dose-taken-*`, `sign-out`, `confirm-sign-out`,
  `catalog-*`, `scan-*`, `invite-preview-title`, `accept-confirm`, `invite-accepted`, `accepted-done`, `link-*`,
  and the types `DoseTile`, `NavigationBar`, `TimePickerDialog`. Shared widgets forward `key` to the element the old
  code keyed.
- CI time: every `app/lib/**` PR runs the ~30 min emulator job; one push per PR.
- Senior overflow after padding changes: the matrix at scale 2.0 catches it (RU strings are longest).
- Visual drift without goldens: the reviewer compares neighbouring screens.
- Palette changes land in UI-1 alone, so a contrast regression is bisectable.
- Privacy: none. The scan FAB reuses `ScanFlow`; no analytics; no ads on scan screens.

## Reviewers per PR
`ui-consistency-reviewer` + `code-reviewer`. UI-1 adds one CI step without permissions: no `security-reviewer`.

## Done when
Closed by the «Забота» redesign (`docs/redesign-plan.md`, R8, 2026-11-11); the palette named «Абрикос» above was
replaced by «Забота» before it shipped.
- [x] `app.yml` (analyze, test, format, guard) and `app-emulator.yml` green on every PR
- [x] guard strict with an empty baseline (UI-9, done in R8: `ui_literals_baseline.json` is `{}`, the retired aliases are
  deleted and fail the build)
- [x] D2 and D3 values approved by the owner (2026-11-10)
- [x] `docs/design.md` updated (D5; final pass in R8)
