import 'dart:ui';

import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:workmanager/workmanager.dart';

import '../data/sync/background_flush.dart';

/// WorkManager task name of the outbox flush.
const String flushTaskName = 'pillpal.flush_outbox';

/// Input-data key holding the account the job was queued for.
const String flushUserKey = 'user_id';

/// Unique work name: flushes queue up in one chain instead of piling up.
const String flushUniqueName = 'pillpal.flush';

/// First retry delay of a flush that could not reach the server.
const Duration flushBackoff = Duration(seconds: 30);

/// Android: one-off WorkManager jobs that run [backgroundFlushDispatcher]
/// once the network is connected (ADR 0001 addendum 3.7). One job per
/// recorded action, appended to one unique chain ([flushUniqueName]): a job
/// is never dropped (`keep`) or cancelled while it runs (`replace`), and they
/// run one after another. The sync lease and the idempotent push make a
/// repeat harmless, and a job with an empty outbox ends without a request.
class WorkmanagerFlushScheduler implements BackgroundFlushScheduler {
  /// Creates the scheduler.
  const WorkmanagerFlushScheduler();

  @override
  Future<void> enqueue(String userId) async {
    final workmanager = Workmanager();
    await workmanager.initialize(backgroundFlushDispatcher);
    await workmanager.registerOneOffTask(
      flushUniqueName,
      flushTaskName,
      existingWorkPolicy: ExistingWorkPolicy.append,
      constraints: Constraints(networkType: NetworkType.connected),
      inputData: {flushUserKey: userId},
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: flushBackoff,
    );
  }
}

/// Entry point of the WorkManager engine: flushes the outbox for the queued
/// account. Returning false makes WorkManager retry with back-off; every
/// other outcome ends the job (the app flushes at its next start anyway).
@pragma('vm:entry-point')
void backgroundFlushDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    final userId = inputData?[flushUserKey];
    if (task != flushTaskName || userId is! String) {
      return true;
    }
    final outcome = await runBackgroundFlush(userId: userId);
    return outcome != BackgroundFlushOutcome.retryLater;
  });
}
