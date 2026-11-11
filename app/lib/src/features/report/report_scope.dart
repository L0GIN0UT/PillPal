import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/sync/sync_status.dart';
import 'report_history.dart';

/// Keeps the reports kept on the device in line with the data (docs/adr/0019
/// §4): at start and at the end of every sync run it deletes expired reports,
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
    // At the end of every run, failed ones too: a pull that evicted a scope
    // commits before the run fails.
    ref.listen(syncStatusProvider.select((status) => status.phase), (
      previous,
      next,
    ) {
      if (previous == SyncPhase.syncing && next != SyncPhase.syncing) {
        unawaited(_reconcile());
      }
    });
    return widget.child;
  }
}
