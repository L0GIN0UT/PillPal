import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../routing/router.dart';
import 'home_widget_updater.dart';

/// Opens Today when the app is started or brought back by a tap on the
/// home-screen widget. Wraps the app in `main.dart`.
class HomeWidgetScope extends ConsumerStatefulWidget {
  /// Wraps [child].
  const HomeWidgetScope({required this.child, super.key});

  /// The app.
  final Widget child;

  @override
  ConsumerState<HomeWidgetScope> createState() => _HomeWidgetScopeState();
}

class _HomeWidgetScopeState extends ConsumerState<HomeWidgetScope> {
  StreamSubscription<void>? _taps;

  @override
  void initState() {
    super.initState();
    final channel = ref.read(homeWidgetChannelProvider);
    if (!channel.isSupported) {
      return;
    }
    _taps = channel.taps.listen((_) => _openToday(), onError: (Object _) {});
    unawaited(_openIfLaunched());
  }

  Future<void> _openIfLaunched() async {
    try {
      if (await ref.read(homeWidgetChannelProvider).launchedFromWidget()) {
        _openToday();
      }
    } on Object {
      // No widget launch information: the app opens as usual.
    }
  }

  void _openToday() {
    if (mounted) {
      ref.read(routerProvider).go(AppRoutes.today);
    }
  }

  @override
  void dispose() {
    unawaited(_taps?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
