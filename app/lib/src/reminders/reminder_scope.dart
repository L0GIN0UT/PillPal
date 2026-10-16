import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Starts the reminder triggers for the app's lifetime and re-plans on
/// resume and on language changes (ADR 0001 §9). Wraps the app in
/// `main.dart`; widget tests pump the app without it.
class ReminderScope extends ConsumerStatefulWidget {
  /// Wraps [child].
  const ReminderScope({required this.child, super.key});

  /// The app.
  final Widget child;

  @override
  ConsumerState<ReminderScope> createState() => _ReminderScopeState();
}

class _ReminderScopeState extends ConsumerState<ReminderScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(ref.read(reminderControllerProvider).start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(reminderControllerProvider).onResume());
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    ref.read(reminderControllerProvider).requestReplan();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Locale>(
      reminderLocaleProvider,
      (previous, next) => ref.read(reminderControllerProvider).requestReplan(),
    );
    return widget.child;
  }
}
