import 'package:flutter/widgets.dart';

/// Motion tokens of the «Забота» design system (docs/design/b2/README.md,
/// section "Motion"; docs/design.md). Screens and widgets take every
/// animation duration and curve from here: a literal `Duration(milliseconds:)`
/// or `Curves.*` under `features/` fails `check_ui_tokens.py`.
abstract final class PillPalMotion {
  /// 150 ms: menus, the way out of a dialog, content that only fades.
  static const Duration fast = Duration(milliseconds: 150);

  /// 250 ms: screens, state changes, dialogs and banners coming in.
  static const Duration base = Duration(milliseconds: 250);

  /// 350 ms: the page turn of the tabs and bottom sheets coming in.
  static const Duration slow = Duration(milliseconds: 350);

  /// `cubic-bezier(.2, 0, 0, 1)`: things that move on screen and leave it.
  static const Curve standard = Cubic(.2, 0, 0, 1);

  /// `cubic-bezier(.05, .7, .1, 1)`: things that arrive (decelerate to rest).
  static const Curve emphasizedDecelerate = Cubic(.05, .7, .1, 1);

  /// A bottom sheet: slides up with its scrim in [slow], closes in [base]
  /// (`showPillPalSheet`; Flutter reads it from the call, not from the theme).
  static final AnimationStyle sheet = AnimationStyle(
    curve: emphasizedDecelerate,
    reverseCurve: standard,
    duration: slow,
    reverseDuration: base,
  );

  /// An overflow menu (`PopupMenuButton.popUpAnimationStyle`): in and out in
  /// [fast].
  static final AnimationStyle menu = AnimationStyle(
    curve: emphasizedDecelerate,
    reverseCurve: standard,
    duration: fast,
    reverseDuration: fast,
  );

  /// Whether the system asks for no animations (`MediaQuery.disableAnimations`:
  /// Android "Remove animations", iOS "Reduce Motion"). The one place that
  /// reads it: screens and tabs then fade only (see [fast]), state changes are
  /// instant, banners and menus fade. Senior mode changes nothing here.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [duration], or [Duration.zero] when [reduced]: for state changes that
  /// must be instant under reduced motion.
  static Duration stateChange(BuildContext context, [Duration? duration]) =>
      reduced(context) ? Duration.zero : (duration ?? base);
}
