import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../auth/auth_session.dart';
import 'report_history.dart';

/// Keeps the reports kept on the device in line with the data (docs/adr/0019
/// §4): at start and after each successful sync it deletes expired reports,
/// reports of profiles that are gone (access revoked or evicted), and files
/// without a row. Nothing is logged: a failure only means the next run
/// retries.
class ReportScope extends ConsumerStatefulWidget {
  /// Wraps [child], above the router.
  const ReportScope({required this.child, super.key});

  /// The app.
  final Widget child;

  @override
  ConsumerState<ReportScope> createState() => _ReportScopeState();
}

class _ReportScopeState extends ConsumerState<ReportScope> {
  @override
  void initState() {
    super.initState();
    unawaited(_reconcile());
  }

  Future<void> _reconcile() async {
    try {
      await ref.read(reportHistoryProvider).reconcile();
    } on Object {
      // Intentionally silent, see above.
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      syncStatusProvider.select((status) => status.lastSuccessAt),
      (previous, next) {
        final signedIn = ref.read(authSessionProvider).valueOrNull ?? false;
        if (signedIn && next != null && next != previous) {
          unawaited(_reconcile());
        }
      },
    );
    return widget.child;
  }
}
