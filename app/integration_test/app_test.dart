import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'phases/after_reminder.dart';
import 'phases/onboarding.dart';
import 'phases/relatives.dart';
import 'support/host.dart';

// Emulator journeys of milestone 2.5 (docs/phase2-plan.md). One app binary
// runs several phases against the same installation: between them the
// workflow (`.github/scripts/emulator/run.sh`) terminates or force-stops
// the app, waits for the reminder, taps its action through the system UI
// and inspects AlarmManager. The phase comes from the runner-side helper,
// so the binary is installed once: an update between phases would kill the
// process and re-arm the alarms itself (MY_PACKAGE_REPLACED), hiding what
// the phases check.
//
// Run through `flutter drive --keep-app-running` (not `flutter test`, which
// uninstalls the app after every run).

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'emulator journey phase',
    (tester) async {
      final host = HostControl();
      addTearDown(host.close);
      final phase = await host.phase();
      switch (phase) {
        case 'onboarding':
          await onboardingPhase(tester, host);
        case 'taken':
          await takenPhase(tester);
        case 'rearm':
          await rearmPhase(tester);
        case 'sign_out':
          await signOutPhase(tester);
        case 'relatives':
          await relativesPhase(tester, host);
        default:
          fail('Unknown phase "$phase"');
      }
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
