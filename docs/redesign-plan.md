# Plan: «Забота» (B2) app redesign

Owner request 2026-11-10: B2 «Забота» was chosen. This redesign replaces the cancelled UI-9 of `docs/ui-pass-plan.md` and becomes the "UI pass" that Phase 5 app milestones A1/A2 depend on (`docs/phase5-plan.md`). Source of truth: `docs/design/b2/README.md` (B2-README, copied in R0), the boards next to it, and `docs/design.md` (rewritten in R1).

## Requirements
- Replace «Абрикос» with «Забота» everywhere in `app/lib/src/**`, in light, dark, light senior and dark senior.
  - Tokens per B2-README §1–§6.
  - Fonts Manrope + Golos Text, bundled, with OFL licences registered.
- Add the new shared widgets (B2-README §7) and re-lay every screen per §8, following the narrow-screen rules (§9: 320 px, RU, text ×2.0).
- Accessibility floors:
  - normal mode: text ≥ 4.5:1, touch targets ≥ 44;
  - senior mode: text ≥ 7:1, touch targets ≥ 64;
  - UI boundaries ≥ 3:1;
  - «missed» is never red; danger only for destructive or blocking cases.
- No behaviour change except the decided ones (D2 password reset, D3 level control, D4 relative-screen privacy editor). Every key and widget type used by `app/integration_test`, `app/test_driver` and `app/test_e2e` stays.
- No medical data in logs or analytics. No runtime font download. No new pub dependency.
- Milestones of about 600 changed lines or fewer, through `/orchestrate`. Binary font files and copied board files do not count toward the cap.

## Decisions (owner, 2026-11-10, answers to B2-README §11)
- **D1 Health-data consent is required to create an account** (as on the B2-Consent board). It is built in Phase 5 **A1** together with the re-consent gate and the medical-sync pause (ADR 0016 §5), using the R2 widgets, right after this redesign. 5.11 then turns the requirement on for staging. The redesign ships no placeholder consent UI.
- **D2 «Забыли пароль?» and the password-reset flow are part of the redesign** (R7b). The backend already has `POST /v1/auth/password-reset/request` (202 whether or not the account exists) and `POST /v1/auth/password-reset/confirm` (`email`, `code`, `new_password` → 204).
- **D3 Reminder level is a 3-option segmented control (тихо / обычно / настойчиво) plus a separate «Будильник» switch.** This is a UI-only mapping onto the unchanged `ReminderLevel` enum (`packages/pillpal_core/lib/src/reminders/reminder_source.dart`; `alarm` already means "like persistent, through the alarm channel"):
  - switch on → `level = alarm`, and the segment shows «настойчиво»;
  - switch off → `persistent`;
  - picking тихо or обычно while the switch is on → that level, and the switch turns off;
  - N and M (repeat interval and count) stay visible for persistent and alarm.
  
  No change to the reminder spec, planner, channels or drift columns. Keys: segments `reminder-level-{quiet|normal|persistent}`, switch `reminder-level-alarm`.
- **D4 Per-medication privacy edited on the relative screen applies to all relatives at once** (privacy is a medication property; current model). The relative screen gets the segmented control «Близким / Без названия / Только мне». It writes through the same repository call the medication form uses, so sync semantics do not change. The copy says plainly that the choice applies to all relatives.

## Assumptions / open questions (each with the proposed default)
- **Q1 Today header actions.** The B-Today and B2-Narrow boards show no «+» and no settings gear. **Default: keep both**:
  - `today-add` is tapped by the onboarding and catalog journeys;
  - Settings has no other entry point;
  - at text scale ×1.6 and above they move to their own right-aligned line below the title (§9.3).
- **Q2 Where the reminder level lives (owner, 2026-11-10): one level for the whole app.** The reminder level (D3 control) is set once in Settings and applies to every medication. The per-medication picker (`MedicationReminderSection` in the medication form) is removed in R4b; the scheduler reads only the app-wide setting. Existing device-local per-medication overrides (`MedicationReminderSettings`) are ignored and cleared on upgrade (no server data, no sync change). `notifications-specialist` reviews R4b.
- **Q3 Consent, export, promo screens** (backend 5.2a/5.5/5.4 exists). **Default: build them in A1/A2 (real flows), not as visual placeholders here.** A1/A2 carry the sync pause, step-up re-auth and privacy review, and the redesign must not ship dead buttons. The Settings «Приватность и данные» group in R7c shows only the rows that work today; A1/A2 add theirs.
- **Q4 OAuth buttons.** Not rendered until client ids exist (later Phase 5 app PR).
- **Q5 Region choice on Welcome (owner, 2026-11-10): hidden.** A build serves one region; Welcome shows no region card, no choice and no other-region note until A4. The `region-build` / `region-other-later` elements are removed from Welcome (their widget tests are updated; journeys do not use them).
- **Q6 Round-check ring colour.** The board draws 2 px `border`; the spec says 2 px `outline` (≥ 3:1 UI boundary). **Default: `outline`.**
- **Q7 Step indicator.** Today registration has 2 steps (credentials → code); with consent (A1) it has 3. **Default:** «Шаг N из M» with M taken from the flow. A1 raises it to 3.
- **Q8 Full-screen alarm board (B2-Alarm).** Needs a new full-screen-intent surface (Android 14 `USE_FULL_SCREEN_INTENT` policy, lock-screen privacy). **Default: deferred** to a separate notifications milestone after the redesign. R8 only sets the notification accent colour.
- **Q9 `docs/design.md` language.** It is Russian today; repo docs are English (CLAUDE.md). **Default: rewrite in English.**
- **Q10 Copy not yet in the ARB files** (RU / EN proposals, added in R2a):
  - «Дальше» / Next; «Уже было» / Earlier today;
  - «Все {n}» / All {n}; «Принято {done} из {total}» / Taken {done} of {total};
  - «Шаг {n} из {m}» / Step {n} of {m};
  - «Забыли пароль?» / Forgot password?;
  - «Если такой адрес зарегистрирован, мы отправили на него код.» / If this address is registered, we sent a code to it.;
  - «Новый пароль» / New password;
  - «Будильник» switch hint;
  - «Это касается всех близких» / This applies to all your relatives;
  - «Напомнить через 15 минут» (already present for senior: reuse).
- **Q11 Boards and screenshots.** The boards exist only in a session scratchpad. **Default:** R0 copies `B2-README.md`, `B-*.dc.html`, `B2-*.dc.html` and `support.js` to `docs/design/b2/`. If a headless browser is available to the orchestrator, it renders one PNG per board into `docs/design/b2/png/` for side-by-side comparison. Without PNGs, implementers compare against the HTML layout values.
- **Q12 `.claude/agents/ui-consistency-reviewer.md`** names «Абрикос». R8 proposes the one-line change; it needs owner approval because it is agent configuration.

## Impact
- `app/` only: `lib/src/theme/**`, `lib/src/features/**`, `lib/src/data/api/auth_*.dart` and `lib/src/routing/**` (R7b), `lib/src/reminders/flutter_notification_scheduler.dart` (R8 accent colour), `lib/l10n/*.arb`, `assets/fonts/**`, `pubspec.yaml`, `android/app/src/main/res/{values,values-night}/colors.xml` (Today widget mirror), `test/**`.
- `.github/scripts/check_ui_tokens.py` and `app/tool/ui_literals_baseline.json`.
- `docs/design.md`, `docs/design/b2/**`, `docs/ui-pass-plan.md` (UI-9 marked superseded), `docs/redesign-plan.md`.
- Not touched: `backend/`, `catalog/`, `packages/pillpal_core`, `spec/**`, `docs/spec/**`, sync protocol, drift schema, schedule, dose-state and GTIN semantics.
- No migrations. No new dependency, so no `pubspec.lock` regeneration (font assets are not packages).

## Keys and types that must survive (from `app/integration_test`; `test_driver` and `test_e2e` use no widget keys)
- **Keys:**
  - auth: `welcome-register`, `auth-email`, `auth-password`, `auth-submit`, `auth-code`;
  - Today and medications: `today-add`, `med-name`, `med-save`, `slot-time-<HH:MM>`, `schedule-save`;
  - doses: `dose-taken-<occurrenceKey>`, and the prefix `dose-take-` on every take button (the viewer check asserts it is absent);
  - settings: `sign-out`, `confirm-sign-out`;
  - catalog: `catalog-linked`, `catalog-scan`, `catalog-search-text`, `catalog-search-go`, `catalog-consent`;
  - scan: `scan-manual`, `scan-manual-field`, `scan-manual-submit`, `scan-unknown`, `scan-unknown-search`;
  - relatives: `invite-preview-title`, `accept-confirm`, `invite-accepted`, `accepted-done`, `link-<id>`.
- **Types and structure:**
  - `NavigationBar` (`home_shell.dart`);
  - `DoseTile` keyed `ValueKey(occurrence.key)`, value starting with `<scheduleId>/`, exactly one per dose of the day (the relatives phase counts 2);
  - `TimePickerDialog` with its input-mode tooltip and OK button;
  - `PillPalApp`.
- **Text:**
  - the medication name rendered as a plain `Text` with the exact name (`find.text(name)`);
  - an anonymous entry shows no dose text (no "tablet").
- **Widget-test keys to keep where the element still exists:** `today-summary`, `today-title`, `today-list`, `day-*`, `senior-*`, `dose-status-*`, `dose-skipped-*`, `dose-missed-*`, `dose-sheet-*`, `low-stock-*`, `as-needed-*`, `session-ended`, `welcome-login`, `detail-*`, `notify-missed`, `link-inactive`, `relative-gone`, `privacy-*`, `reminder-level-*`, `reminder-interval-*`, `reminder-repeats-*`, `medications-scan`.

## Steps (milestones; branch `feat/redesign-<id>-<slug>`)

Shared testing rules for every screen milestone:
- **UI matrix:** one `pumpUiMatrix` test per screen touched, with `expectTouchTargets: true` and the R2a `expectContrast: true`. The matrix runs {light, dark} × {normal, senior} × {ru, en} × {1.0, 2.0} × {360×800, 320×568}.
- **Key test:** the R2a static journey-key test must stay green.
- **Required tests per milestone:**
  - a failing widget test first for every layout rule it implements (§9 items);
  - a status test: «missed» renders `missedSoft` / `onMissedSoft` (or `missed` in senior), never `danger`;
  - a semantics test: status = icon + word.
- **No goldens.**

### R0 Docs only: plan and boards (no app workflow runs)
- **Files:** `docs/redesign-plan.md`, `docs/design/b2/README.md` (B2-README verbatim), `docs/design/b2/*.dc.html` + `support.js`, optional `docs/design/b2/png/*.png`, and `docs/ui-pass-plan.md` (one line: UI-9 superseded by this plan).
- **Test first:** none (docs). `repo.yml` checks only.
- **Risk:** low. The board HTML loads Google Fonts from the CDN. That is fine for docs and never reaches the app.
- **Parallel:** before everything; must merge first so worktrees see the boards.

### R1 Tokens, palette, type, fonts, theme, design.md
- **Files:**
  - `app/lib/src/theme/palette.dart` — add `raised`, `outline`, `onTakenSoft`, `missedSoft`, `onMissedSoft`, `dangerSoft`, `onDangerSoft`, `scrim`, `hero`, `onHero`, `heroAction`, `onHeroAction`; new values for all fields in 4 palettes; `copyWith`/`lerp`. Remove `info` (2 call sites switch now: `common/pillpal_banner.dart` info tone → `raised`/`ink`, `common/info_note.dart`). Move the four `static const` palettes to `palette_values.dart` if the file passes 400 lines.
  - `theme/radius.dart` — `lg` 20, `xl` 28, `pill = StadiumBorder()`, `navIndicator` (16).
  - `theme/spacing.dart` — `huge` 40; `screen`/`tabHeader` side `lg`; `sheet` = `fromLTRB(xl, sm, xl, xxxl - 4)`; `sectionTop` 24 / `sectionBottom` 10 as named consts per §6. 10 is not a multiple of 4: name it `sectionGap` = `md - 2`, or round to `md`. Default: round to `md` (12); the reviewer accepts ±2.
  - Split `theme/app_theme.dart` (310 lines, would pass 400):
    - `app_theme.dart` — `buildPillPalTheme`, `colorScheme` per §7; re-exports the files below so existing imports keep working;
    - `sizes.dart` — `PillPalSizes`, `PillPalMetrics`. New: `statusDisc` 40 / `statusDiscSenior` 52, `roundCheck` 48, `profileChip` 44, `navHeight` 88 / `navHeightSenior` 104, `heroPadding` 20, `emptyDisc` 96, `fab` 56, `progressRing` 56, `qrCode` 220, `iconEmpty` 44, and the clamps `titleMaxScale` 1.5, `heroNameMaxScale` 1.6, `navLabelMaxScale` 1.15, `fabLabelMaxScale` 1.3, `compactRowScale` 1.6. `statusSquare` stays as a `@Deprecated` alias until R3b;
    - `text_theme.dart` — `PillPalFonts.display = 'Manrope'`, `body = 'GolosText'`, the §5 type table, `PillPalText.numeral` extension (Manrope 800, `FontFeature.tabularFigures()`), letter-spacing 0 except `displaySmall` (−0.6);
    - `component_themes.dart` — filled/outlined/text/elevated buttons (stadium; heights 52 / 64 unchanged), `cardTheme` (elevation 0, radius 20, no border; shadow drawn by `PillPalCard` in R2a), input (filled `surface`, `outline` 1.5, focus `action` 2, error `danger` 2, radius 16), `navigationBarTheme` (88 / 104, indicator `actionSoft` with radius 16, active label 700), switch, checkbox, segmentedButton, chip, FAB (stadium, elevation 2), bottomSheet (`surface`, radius 28, drag handle), dialog (radius 28);
    - `shadows.dart` — `PillPalShadows.level1/level2/nav` as two `BoxShadow`s each (light only; dark returns none).
  - Fonts: delete `assets/fonts/{Rubik,Nunito}-*.ttf` and their OFL files. Add `Manrope-700/800.ttf`, `GolosText-400/500/600/700.ttf`, `Manrope-OFL.txt`, `GolosText-OFL.txt`. Get them from the Google Fonts static files, or the `google/fonts` repo `[wght]` files cut with `uv tool run --from fonttools fonttools varLib.instancer` and the command recorded in the commit body. Put downloads in their own empty folder; check Cyrillic coverage with fontTools before committing.
  - `app/pubspec.yaml` — two font families; `assets:` lists both OFL texts.
  - `app/lib/src/theme/font_licenses.dart` — `registerFontLicenses()` using `LicenseRegistry.addLicense`; called from `app/lib/main.dart`.
  - `app/android/app/src/main/res/{values,values-night}/colors.xml` — Today widget mirror (`surface`, `ink`, `inkMuted`, `action`, `taken`).
  - `docs/design.md` — rewritten from B2-README (English, Q9): principles, tokens, component tokens, contrast table, type, radius/spacing/elevation/sizes, the §9 narrow-screen rules, font plan, links to the boards.
  - `.github/scripts/check_ui_tokens.py` — add alias patterns `PillPalSizes.statusSquare`, `InfoNote(`, `TodaySummaryCard(`, plus self-tests. `app/tool/ui_literals_baseline.json` is seeded by hand with today's alias counts per file: an intentional one-time raise, stated in the PR body. Each screen milestone must lower them; R8 empties the file.
- **Tests first:**
  - `test/theme_test.dart`: radii `{12, 16, 20, 28}`; spacing multiples of 4 plus `huge`; the button shape is `StadiumBorder`; nav heights 88 / 104; input borders; `colorScheme` mapping (`primary` = `action`, `secondaryContainer` = `actionSoft`, `error` = `danger`, `surfaceContainerHighest` = `raised`, `outline` = `outline`, `outlineVariant` = `border`, `scrim` = `scrim`); text theme families, sizes and weights per §5; `numeral` uses tabular figures.
  - New `test/theme_contrast_test.dart`, split from `theme_test.dart` (288 lines):
    - every §4 pair per palette, normal ≥ 4.5, senior ≥ 7, with **no exceptions** (the old `action/background 4.3` exception goes away);
    - UI pairs ≥ 3 (`outline` on `surface`/`bg`, `action` on `surface`, `taken` on `takenSoft`);
    - `missed`/`missedSoft` differ from `danger`/`dangerSoft`;
    - hero pairs.
  - New `test/fonts_test.dart`: the pubspec families equal `PillPalFonts`; every declared file exists; no `Rubik|Nunito` anywhere under `app/lib` or `app/assets`; after `registerFontLicenses()`, `LicenseRegistry.licenses` contains entries for `Manrope` and `GolosText`.
  - The existing danger hex test is updated to the new values.
- **Implement:** as listed. Screens keep their old layouts and pick up the new colours, fonts and shapes through the theme. main stays releasable.
- **Size:** about 520 code lines plus about 180 for `docs/design.md`. If over budget, `docs/design.md` may land in R0 (docs-only, no app CI).
- **Risk:** medium.
  - Global visual change.
  - Senior overflow from new metrics. The existing matrix tests catch it, since all current screens already have matrix tests.
  - Font coverage.
  - The palette lands alone, so a contrast regression can be bisected.
- **Parallel:** none (the base for everything).

### R2a New shared widgets, matrix contrast, key test, copy
- **Files:**
  - in `app/lib/src/features/common/` (new):
    - `status_pill.dart` — `StatusPill` with a `DoseStatus → (tone, icon, word)` mapping, height 28, forwards `key`;
    - `status_disc.dart` — `StatusDisc` 40 / 52, solid `taken`/`missed` in senior;
    - `round_check_button.dart` — 48 circle, 2 px `outline` (Q6), pressed `action`/`onAction`; `key` forwarded, the caller passes `dose-take-<occurrence>`; semantics label;
    - `profile_chips.dart` — `ProfileChips`: max 4 visible plus a pinned «Все N» chip that opens the existing `profile_switcher` sheet; the selected chip first; horizontal scroll with a 32 px fade to `bg`; chip height 44; check icon on the selected chip;
    - `pillpal_segmented.dart` — `PillPalSegmented<T>` wrapping `SegmentedButton`; falls back to a radio list when a label would wrap to 3 lines (measured with `TextPainter` at the current scaler); per-option `keyOf`;
    - `pillpal_card.dart` — `PillPalCard` (surface, radius 20, `PillPalShadows.level1` in light, none in dark, padding 16);
    - `list_row.dart` — `PillPalListRow`: min 60 / 76; leading 40 disc; hides the tile and chevron at `compactRowScale` and above; trailing aligned to the top when wrapped (§9.7–9.8);
    - `clamped_text.dart` — `ClampedText` / `TextScaleClamp` extension using `MediaQuery.textScalerOf(context).clamp(maxScaleFactor:)`;
    - `stacked_buttons.dart` — `StackedButtons`: always full width and stacked; min height 56 at large scale; the label wraps (§9.6);
  - `app/lib/l10n/app_{en,ru}.arb` — all Q10 strings at once, so later milestones do not conflict;
  - `app/test/support/ui_matrix.dart` — `expectContrast` option. It runs `meetsGuideline(textContrastGuideline)` in normal cells and `CustomMinimumContrastGuideline(finder: find.byType(Text), minimumRatio: 7)` in senior cells, only at scale 1.0 and 360×800 (8 cells), to keep run time sane.
- **Tests first:**
  - `test/features/common/status_pill_test.dart`: each status → colours, icon and word; missed never uses `danger`; the key is forwarded.
  - `round_check_button_test.dart`: 48 / 64 target, key, semantics.
  - `profile_chips_test.dart`: ≤ 4 plus «Все N»; selected chip first; opens the sheet; fade present; matrix at 320 px ×2.0 RU.
  - `pillpal_segmented_test.dart`: fallback to a radio list in RU ×2.0 at 320 px; keys.
  - `list_row_test.dart`: tile and chevron hidden at ≥ 1.6; trailing top-aligned.
  - `clamped_text_test.dart`.
  - `test/journey_keys_test.dart` (static, `dart:io`): parse every `Key('…')` / `ValueKey('prefix-$…')` literal under `integration_test/` and assert each literal or prefix occurs in `lib/`; assert the classes `DoseTile`, `PillPalApp` and the use of `NavigationBar` and `showTimePicker` exist in `lib/`. This protects every later milestone.
- **Size:** about 600.
- **Risk:** low–medium. The contrast guideline's run time and flakiness are the risk. If it proves flaky, keep it only in the widget tests of R2a and R3a and say so.
- **Parallel:** with R2b (disjoint files; R2a owns the ARB and `ui_matrix.dart`).

### R2b Existing shared widgets restyled
- **Files:**
  - in `features/common/`:
    - `pillpal_banner.dart` + `banner_tone.dart` — `soft`/`info`/`danger` per §3; radius 20; no border; padding 14/16; icon 20;
    - `info_note.dart` — a `@Deprecated` thin alias of `PillPalBanner(tone: info)`;
    - `choice_button.dart` / `choice_group.dart` — stadium chip, selected = `actionSoft` plus check icon; API and keys unchanged;
    - `section_header.dart` (`titleMedium`, top 24 / bottom 12) and `group_label.dart`;
    - `sheet_scaffold.dart` + `action_sheet.dart` — radius 28, drag handle, `PillPalSpacing.sheet`, scrim 48 %;
    - `confirm_dialog.dart`, `removal_dialog.dart` — radius 28; 48 `dangerSoft` icon disc for destructive dialogs; consequences list slot; `StackedButtons` with the destructive button first;
    - `pillpal_icon_button.dart` — 48 circle plus a secondary variant with a `border` ring;
    - `status_message.dart`, `icon_label.dart`, `error_snack_bar.dart` — colours only;
  - `features/shell/empty_state.dart` — 96 `actionSoft` disc, 44 icon, headline, body, primary and optional secondary actions (new optional parameters; the old ones are kept).
- **Tests first:** the existing common widget tests are updated to the new looks.
  - Danger dialog: the destructive button is first, full width, `danger` colour; `confirm-sign-out` is still forwarded.
  - Banner tones map to the palette pairs.
  - `ChoiceButton` selected state shows a check icon (not colour alone).
  - `EmptyState` with two actions in a matrix test.
- **Size:** about 450.
- **Risk:** medium. Every screen changes at once through the shared widgets. Key forwarding is covered by the R2a static key test (merge R2a first or rebase).
- **Parallel:** with R2a.

### R3a Today (normal) and navigation bar
- **Files:**
  - `features/today/`:
    - `today_screen.dart` — header with date, `ClampedText` title ×1.5, ring 56 (key `today-summary` moves to the ring or to the «Принято N из M» line shown at ≥ 1.6), gear, «+» (`today-add`, round 48 `action`) per Q1; `ProfileChips` replaces `ProfileSwitcher` on the tab; sections;
    - `today_widgets.dart` — `TodaySummaryCard` removed (alias counted by the guard, then deleted), `ProgressRing` 56, low-stock as a soft banner, as-needed rows in `PillPalCard`;
    - `dose_tile.dart` (438 lines: split) → `dose_tile.dart` (one public `DoseTile`, keyed by occurrence, `DoseTileLayout {hero, upcoming, past}`, menu sheet), `dose_hero.dart` (pine «Сейчас» card: `hero`/`onHero`, «Принял» full width `heroAction` with key `dose-take-<key>`, snooze outline `onHero` 55 % with key `dose-snooze-<key>`, name `ClampedText` ×1.6 with `overflow-wrap`), `dose_rows.dart` (upcoming: `RoundCheckButton` with key `dose-take-<key>`; past: `StatusDisc` plus a status line whose widget carries `dose-taken-<key>` / `dose-skipped-<key>` / `dose-missed-<key>`; keeps `dose-status-<key>`);
    - `today_state.dart` — pure `todaySections(TodayState) → (hero, upcoming, past)`: hero = `state.currentDose`; past = final statuses; upcoming = the rest, in time order;
  - `features/shell/home_shell.dart` — `NavigationBar` restyle (type kept): labels `ClampedText` ×1.15 with the full label as tooltip; indicator around icon and label; nav shadow / dark top line.
- **Tests first:**
  - `test/features/today_sections_test.dart` — pure function: hero not repeated in «Дальше»; each dose appears exactly once.
  - `today_screen_test` updates: viewer has no `dose-take-*`; the hero is a `DoseTile`; a taken dose shows `dose-taken-<key>` in «Уже было»; ring hidden and text shown at ≥ 1.6; header actions wrap to their own line at ≥ 1.6.
  - `today_ui_matrix_test.dart` with `expectContrast`.
  - Nav label clamp test.
- **Size:** about 600 (the dose tile split is mostly a move).
- **Risk:** high.
  - The journeys depend on `DoseTile` count and keys.
  - Duplicate `dose-take-` key if the hero dose also appears in «Дальше» (prevented by `todaySections`).
  - The snooze action reuses the existing dose-state snooze path used by `senior_cards.dart`; no rule changes.
- **Parallel:** with R4a, R5, R6a, R7a (disjoint files). R3b follows R3a.

### R3b Today senior (light and dark)
- **Files:** `features/today/today_senior.dart`, `senior_cards.dart` (358 lines: split `senior_now_card.dart` / `senior_groups.dart`):
  - the same hero at senior sizes («Принял» 76, snooze/skip 64; keys `senior-now`, `dose-take-<key>`, `senior-skip`, `senior-snooze`, `senior-confirmation`, `senior-undo` kept);
  - time groups as `PillPalListRow` with `StatusDisc` 52 (keys `senior-group-*` kept);
  - dark: soft hero plus mint «Принял» from the palette's `hero*` tokens;
  - remove `StatusSquare` and `PillPalSizes.statusSquare`.
- **Tests first:** `today_senior_ui_matrix_test.dart` with `expectTouchTargets` and `expectContrast` (7:1); the senior hero uses the `hero*` tokens of each palette; the group status is icon plus word.
- **Size:** about 450.
- **Risk:** medium (senior overflow at ×2.0 × 1.3).
- **Parallel:** after R3a; with the others.

### R4a Medications list, empty state, add medication, scan sheet
- **Files:**
  - `features/medications/medications_screen.dart` — cards radius 20 with pill tile, privacy and stock meta row, low stock as a soft pill, «+» round and profile button in the header, FAB stadium (`medications-scan`), bottom padding = FAB + 16, `EmptyState` per B2-EmptyMedications;
  - `features/medications/medications_scan_button.dart`;
  - `medication_form_view.dart` — top two tiles «Сканировать упаковку» (tonal, key `catalog-scan` stays on the scan entry) and «Ввести вручную»; search field; results card;
  - `features/catalog/` — `catalog_section.dart`, `catalog_section_parts.dart`, `catalog_result_tile.dart`, `product_card.dart` (colours/shapes only);
  - `scan_sheet.dart` — radius 28, 300 viewfinder with corner marks, torch, privacy text, «Ввести номер вручную» `scan-manual`;
  - `manual_gtin_entry.dart` — one field `scan-manual-field`, helper, error with icon, «Камера / Продолжить» `scan-manual-submit`;
  - `scan_prompts.dart` — `scan-unknown`, `scan-unknown-search`.
- **Tests first:** `medications_ui_matrix_test.dart` (list, empty); new `scan_sheet_ui_matrix_test.dart` (camera fake + manual) at 320 ×2.0; the manual entry error shows icon plus text and `danger` only for the blocking invalid code. All catalog and scan journey keys are present (static test plus widget test).
- **Size:** about 550.
- **Risk:** medium.
  - The catalog emulator phase uses the scan keys.
  - The scanner build check (`check_scanner_build.py`) is not affected (no dependency change).
- **Parallel:** with R3a/R3b, R5, R6a, R7a. R4b follows (both touch the medication form area).

### R4b Schedule editor and reminder level control (D3)
- **Files:**
  - `features/schedule/schedule_editor_view.dart`, `schedule_widgets.dart`, `course_card.dart`:
    - chips stadium with check;
    - time rows in a `PillPalCard` with big `numeral` time (`slot-time-*` kept);
    - course as two date fields;
    - sticky «Сохранить» (`schedule-save`);
    - Material `showTimePicker` kept (`TimePickerDialog`);
  - `features/reminders/reminder_level_picker.dart` — `PillPalSegmented` (quiet/normal/persistent) plus a «Будильник» `SwitchListTile` per D3; N/M `ChoiceGroup`s kept with their keys;
  - `reminder_settings_sections.dart` (layout of `MedicationReminderSection` only; Settings layout is R7c).
- **Tests first:**
  - `test/features/reminder_level_picker_test.dart` — the D3 mapping table: switch on → `alarm`; off → `persistent`; quiet/normal while alarm → that level and switch off; the segment shows `persistent` while alarm; N/M visible for persistent and alarm; keys.
  - `schedule_editor_ui_matrix_test.dart` with RU ×2.0 at 320 px (segmented falls back to radio).
- **Note (R7c):** the `GroupLabel` above the picker in Settings is a stopgap; it converges with the Settings group layout in R7c.
- **Size:** about 500.
- **Risk:** medium. A UI mapping onto stored levels: the emitted `ReminderSettings` must be identical to what the 4-option picker produced for the same choice. The table test enforces this.
- **Parallel:** after R4a; before R7c (both touch the reminders sections).

### R5 History, day view, report sheet
- **Files:**
  - `features/history/history_screen.dart` — calendar in a `PillPalCard`, centred legend with round markers, adherence numeral;
  - `month_calendar.dart` (396 lines: split `calendar_cell.dart`) — round day cells with glyphs; all taken `taken`/`onTaken`, partial `takenSoft`/`onTakenSoft`, missed days `missed`; height-only target rule kept (`heightOnlyWithin`);
  - day detail (B2-HistoryDay) — grouped by time of day with `StatusPill` and «Принято в …»;
  - `features/report/report_sheet.dart` — `SheetScaffold`, period chips, privacy soft banner; `report_pdf.dart` untouched.
- **Tests first:** `history_ui_matrix_test.dart` updated; a day-cell colour test (missed day never `danger`); report sheet matrix; custom-period branch still works.
- **Size:** about 550.
- **Risk:** low–medium.
- **Parallel:** with any lane except files it shares (none).

### R6a Family list, banners, empty family
- **Files:**
  - `features/family/family_screen.dart` — no `ProfileChips` (the tab lists every profile itself, so a switcher would change nothing; decision after review), «Пригласить» primary in header, `SectionHeader` 18/700, rows in cards with 48 avatars (shared `PillPalPersonRow` in `features/common/person_row.dart`) and `StatusPill` for paused links and archives (`StatusKind.inactive`); per-person dose pills arrive in R9; `EmptyState` (invite / add ward, accept as a quiet outlined button);
  - `family_tiles.dart` — `link-<id>` key kept on the tappable row;
  - `archived_profile_banner.dart`, `new_relative_banner.dart`, `push_unavailable_hint.dart`, `profile_note.dart` — `PillPalBanner` tones, keys kept;
  - `profile_switcher.dart` — untouched (History and Medications still use it until R4a).
- **Tests first:** `family_ui_matrix_test.dart` updated; `link-<id>` tap opens the day view; the empty family state has two actions.
- **Size:** about 450.
- **Risk:** medium. The relatives journey taps `link-<id>`.
- **Parallel:** with R3/R4/R5/R7a. R6b follows.

### R6b Invites (create, ready, accept), relative detail, managed profile, D4
- **Files:** `invite_create_screen.dart`, `invite_disclosure.dart`, `invite_share_view.dart`, `accept_invite_screen.dart`, `accept_invite_views.dart`, `relative_detail_screen.dart` (347 lines: split `relative_privacy_section.dart`), `managed_profile_screen.dart`.
  - Invite create: radio-card roles with hints; validity segmented.
  - Invite ready: QR 220 in a white raised frame (`ui-literal-ok` kept) plus a validity pill.
  - Accept: 72 avatar, what-you-will-see list, `StackedButtons` «Принять» (`accept-confirm`) / «Не сейчас»; `invite-preview-title`, `invite-accepted`, `accepted-done` kept.
  - Relative detail: 64 avatar header, soft explainer banner, the D4 per-medication `PillPalSegmented` (keys `relative-privacy-<medId>-<level>`) calling the existing medication privacy update used by `medication_sections.dart`, copy «Это касается всех близких», `notify-missed` switch, «Закрыть доступ» as a danger text button (`detail-revoke`).
- **Tests first:**
  - `family_invites_ui_matrix_test.dart` updated.
  - `relative_privacy_section_test.dart`: changing a level writes the same medication update as the form (one outbox entry, same fields) and shows the all-relatives copy.
  - Only the owner side shows the editor; a relative never sees it (role check).
- **Size:** about 600.
- **Risk:** high.
  - The relatives emulator phase.
  - D4 is a new entry point to an existing write path.
- **Parallel:** after R6a.
- **Deferred (backend follow-up):** the invite validity choice of B2-InviteCreate (1 / 3 / 7 days) needs a server field on `InviteCreate`; today the TTL is fixed (7 days, 24 h for a guardian). The create screen shows no validity control, the ready screen shows the expiry (with the hour for a 24 h invite).

### R7a Auth visuals: welcome, sign-in, register, verify, restore
- **Files:** `features/auth/welcome_screen.dart` (headline-first, no region block per Q5, primary + secondary pinned to the bottom), `auth_widgets.dart` (`AuthScaffold` with step indicator Q7, fields with leading icons, danger banner above the form keeps `Key('auth-error')`), `credentials_screens.dart`, `verify_screen.dart`, `restore_screen.dart`. Keys `welcome-register`, `welcome-login`, `auth-*` kept.
- **Tests first:** `auth_ui_matrix_test.dart` updated; the primary button is pinned and visible with the keyboard closed at 320 ×2.0; the step indicator reads «Шаг 1 из 2».
- **Size:** about 450.
- **Risk:** medium. Every journey starts here.
- **Follow-up (owner):** replace the placeholder logo (a medication icon in a tile on Welcome) with the real asset.
- **Parallel:** with R3–R6. R7b follows.

### R7b Password reset (D2)
- **Files:**
  - `app/lib/src/data/api/auth_api.dart` — `requestPasswordReset(email)`, `confirmPasswordReset(email, code, newPassword)`;
  - `auth_dto.dart` — bodies;
  - `features/auth/password_reset_screens.dart` (new):
    - `ForgotPasswordScreen` — email prefilled from sign-in; always the neutral «Если такой адрес зарегистрирован…» message (no account enumeration); resend with the same cooldown as `verify_screen.dart`;
    - `ResetPasswordScreen` — code plus new password with show/hide, autofill hints `oneTimeCode`/`newPassword`; on 204 it signs in through the existing login path in `auth_flow.dart`, so verification, restore and deletion branches still apply;
  - «Забыли пароль?» text button on sign-in (`auth-forgot`);
  - routes in `app/lib/src/routing/routes.dart` and the router;
  - error codes mapped in `auth_errors.dart` (read the exact codes from `backend/app/services/auth*.py` / `backend/app/errors.py`: invalid or expired code, weak password 422, 429 rate limit).
- **Tests first:**
  - `test/data/auth_api_password_reset_test.dart` (fake HTTP client: paths, bodies, 202/204, error mapping);
  - `test/features/password_reset_test.dart` (flow: request → code screen → confirm → login called; unknown email shows the same message; 429 message; nothing logged);
  - matrix test for both screens;
  - optional `test_e2e/password_reset_test.dart` against the real backend, if the e2e setup already exposes e-mailed codes the way verification does. No new emulator phase.
- **Size:** about 500.
- **Risk:** medium–high (auth path).
  - No email or code in logs.
  - The password field is never prefilled.
  - Codes are cleared on leaving the screen.
- **Parallel:** after R7a.

### R7c Settings and the account danger dialog
- **Files:**
  - `features/settings/settings_screen.dart` — account card, grouped `PillPalCard`s «Вид» (theme as `PillPalSegmented`, senior switch) / «Напоминания» / «Приватность и данные» (only existing rows, Q3) / «Аккаунт»; `sign-out` kept;
  - `account_section.dart`;
  - `delete_account_dialog.dart` — B2-DangerDialog: danger icon disc, consequences list, destructive first, full width; `confirm-sign-out` kept on the sign-out confirm;
  - `features/reminders/reminder_settings_sections.dart` (Settings part), `reminder_permission_card.dart` (banner tones: blocking → danger, hints → soft).
- **Tests first:** a settings matrix test (new `settings_ui_matrix_test.dart`); the delete dialog has its destructive button first and uses `danger`; the theme segmented falls back to radio in RU ×2.0 at 320.
- **Size:** about 450.
- **Risk:** medium (`sign-out` journey).
- **Parallel:** after R4b (reminder sections); with R5/R6.

### R9 Family dose status (owner request 2026-11-11)
- **Why:** the main user wants to see "how are all my people today" on the Family tab without opening each day view (B-Family board pills «Всё принято» / «1 пропуск» / «1 из 2» and «Следующий приём в 21:00»).
- **Data:** no network and no new cache. Relatives' doses are already in the local drift DB through scoped sync (they power the day view offline). A new provider computes today's per-profile summary (taken / missed / pending counts, next due time) from local data with the same privacy projection as the day view: `hidden` medications are excluded, `anonymous` ones count by time and status only. It recomputes when sync updates the tables.
- **UI:** `PillPalPersonRow` gets the status pill (StatusKind taken/missed/pending) and an optional «Следующий приём в HH:MM» line; viewers see only what their grant allows; stale data (no sync for a long time) shows a quiet "обновлено N назад" hint instead of a wrong status.
- **Tests:** pure summary function (counts, next due, hidden/anonymous projection, day boundary in the profile's time zone), matrix test of the Family tab with pills at 320 ×2.0 RU, privacy test that a hidden medication never changes the pill.
- **Reviewers:** ui-consistency-reviewer, code-reviewer, privacy-compliance-reviewer (relative-facing data).
- **Order:** after R8 (or right after R6b if a lane is free); app-only, no backend change.

### R8 Lock-in and platform visuals
- **Files:**
  - `.github/scripts/check_ui_tokens.py` — strict: alias patterns stay as hard failures; add `PillPalSizes.statusSquare`, `InfoNote`, `TodaySummaryCard` removal checks plus self-tests;
  - `app/tool/ui_literals_baseline.json` → `{}`;
  - delete `common/info_note.dart` and any remaining aliases;
  - `app/lib/src/reminders/flutter_notification_scheduler.dart` — `color:` accent from the light palette `action` (`#0C6B5D`) on `AndroidNotificationDetails`;
  - launch background in `android/app/src/main/res/{drawable,drawable-v21}/launch_background.xml` and `values*/styles.xml` → `bg`;
  - `docs/design.md` final pass;
  - `docs/ui-pass-plan.md` "Done when" closed;
  - proposed (owner OK, Q12) `.claude/agents/ui-consistency-reviewer.md` «Абрикос» → «Забота»;
  - CLAUDE.md "Current phase" line is updated by the orchestrator with the owner.
- **Tests first:** the guard self-test; a notification details test asserts the accent colour and an unchanged payload; `fonts_test` still green.
- **Size:** about 250.
- **Risk:** low–medium. The notification change touches reminders, so `notifications-specialist` reviews it.
- **Parallel:** last.

## Order and parallel lanes
R0 → R1 → (R2a ∥ R2b). Then at most **two lanes at a time**, because every PR touching `app/lib/**` runs the ~30-minute emulator job:
- Lane A: R3a → R3b → R4a → R4b → R7c
- Lane B: R5 → R6a → R6b → R7a → R7b

R8 comes last.

Shared files that can conflict:
- `app/tool/ui_literals_baseline.json`: after a rebase, run `python3 .github/scripts/check_ui_tokens.py --update`.
- ARB files: R2a adds all copy; later edits are rare.
- `ui_matrix.dart`: R2a only.

One push per PR where possible: batch CI fixes (performance.md).

## Migrations & compatibility
- No Alembic revision.
- No sync protocol change. D4 reuses the existing medication update; D3 maps onto the existing `ReminderLevel`.
- No schedule, dose-state or GTIN semantics change; vectors unchanged.
- Client versions in the field are unaffected (UI only). Field-test APKs keep registering without consents until A1 / 5.11.

## Privacy & region impact
- No new data, endpoints or stores. Fonts are bundled, so no request to Google from RU/EU devices. No analytics added.
- Accessibility semantics labels may contain medication names; they stay on device.
- Password reset sends only email, code and new password to the region's own backend, and nothing is logged.
- D4 copy makes the all-relatives effect explicit.
- Notification payload and text are unchanged; only the accent colour changes.

## Reviewers to run (agents)
- Every milestone: `ui-consistency-reviewer` + `code-reviewer`.
- Additionally:
  - R6b: `privacy-compliance-reviewer` (relative-facing privacy editor);
  - R7b: `security-reviewer` (auth flow, enumeration, rate-limit handling);
  - R4b and R8: `notifications-specialist` (level mapping, notification accent).
- R0: `code-reviewer` only (docs).

## Brief for the implementing agent (paste into every milestone prompt)
```
You implement milestone <Rn> of docs/redesign-plan.md (the «Забота» B2 redesign of the PillPal app).
Read first: CLAUDE.md, .claude/rules/{coding-style,testing,delivery,privacy}.md, docs/redesign-plan.md (section <Rn>,
"Keys and types that must survive", Decisions D1-D4), docs/design.md, and the design spec docs/design/b2/README.md
(if R0 has not merged: C:/Users/ivanl/AppData/Local/Temp/claude/1b73a8e729c4f54f/0bce23c2-069e-4f03-a05f-a9fba17e91ff/scratchpad/redesign/B2-README.md).
Boards for your screens: docs/design/b2/B-*.dc.html and B2-*.dc.html (+ png/ if present); read the HTML of each board
you implement for exact layout (paddings, sizes, order). B2-Components and B2-Narrow apply to every screen.
Also read the design skills' guidance and use their data/scripts for any decision the spec leaves open:
C:/Users/ivanl/.claude/plugins/cache/ui-ux-pro-max-skill/ui-ux-pro-max/2.13.0/.claude/skills/ui-ux-pro-max/SKILL.md,
.../skills/design-system/SKILL.md, .../skills/ui-styling/SKILL.md. The spec wins over the skills; the skills fill gaps.
Rules:
- Never invent a colour, radius, size or font weight: only PillPalPalette / PillPalRadius / PillPalSpacing /
  PillPalSizes / textTheme / PillPalText.numeral / PillPalShadows. No Colors.*, no Color(0x..) under features/
  (the guard check_ui_tokens.py fails the build). If a token is missing, stop and report it; do not add one silently.
- Use the shared widgets in features/common (StatusPill, StatusDisc, RoundCheckButton, ProfileChips, PillPalSegmented,
  PillPalCard, PillPalListRow, PillPalBanner, SheetScaffold, StackedButtons, EmptyState, ClampedText).
- Missed is never red; danger only for destructive or blocking cases; status = icon + word.
- Keep every key/type in the plan's list; tests/journey_keys_test.dart must stay green. Shared widgets forward `key`.
- B2-README §9 narrow rules at 320 px, RU, text x2.0; senior targets 64 and text 7:1; normal 44 and 4.5:1.
- TDD: failing widget/matrix test first (pumpUiMatrix with expectTouchTargets: true, expectContrast: true per screen).
- Compare your result with the board: list in the handoff each visible deviation and why (e.g. kept "+"/gear, Q1).
- Files <= 400 lines, functions <= 50; ARB strings for all copy (RU + EN); no medical data in logs.
- Flutter is verified in CI (state "verified in CI only" unless you ran flutter test locally).
- Delivery per .claude/rules/delivery.md; one PR, not draft; never merge; no AI attribution anywhere.
Reviewers the orchestrator will run: ui-consistency-reviewer + code-reviewer (+ the extra ones named for <Rn>).
```

## Done when
- [ ] Every milestone: `app.yml` green (analyze, unit/widget, format, `check_ui_tokens.py` self-test and check, `e2e`) and `app-emulator.yml` green; `/verify` green for the app part. Backend, core and vectors are untouched; `python spec/validate_vectors.py` still passes.
- [ ] `test/theme_contrast_test.dart` passes with no exceptions (normal ≥ 4.5, senior ≥ 7, UI ≥ 3).
- [ ] A `pumpUiMatrix` test with touch targets and contrast exists for every redesigned screen.
- [ ] `test/journey_keys_test.dart` and `test/fonts_test.dart` green; Rubik and Nunito gone; OFL licences on the licences page.
- [x] Guard strict with an empty baseline; deprecated aliases removed (R8).
- [x] `docs/design.md` describes «Забота»; `docs/ui-pass-plan.md` closed; D1–D4 reflected. Q1–Q11 answered or defaults accepted; Q12 (agent config «Абрикос» → «Забота») waits for the owner.
- [ ] A1/A2 (consent at registration, re-consent gate, privacy/export, promo) scheduled next on top of the R2 widgets.
