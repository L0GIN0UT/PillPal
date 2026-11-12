import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/common/now_ticker.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';

// The shared once-a-minute "now" (Today and the Family tab): it ticks while
// the app is in the foreground, stops in the background and re-reads the
// clock at once on resume. The clock is a fake the test moves.

DateTime _clock = DateTime.utc(2026, 10, 16, 6);

class _Screen extends ConsumerStatefulWidget {
  const _Screen();

  @override
  ConsumerState<_Screen> createState() => _ScreenState();
}

class _ScreenState extends ConsumerState<_Screen> {
  late final NowTicker _ticker = ref.read(nowTickerProvider);

  @override
  void initState() {
    super.initState();
    _ticker.attach();
  }

  @override
  void dispose() {
    _ticker.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(nowProvider);
    return Text('${now.hour}:${now.minute}', textDirection: TextDirection.ltr);
  }
}

Widget _app({int screens = 1}) => ProviderScope(
      overrides: [clockProvider.overrideWithValue(() => _clock)],
      child: Column(
        textDirection: TextDirection.ltr,
        children: [for (var i = 0; i < screens; i++) const _Screen()],
      ),
    );

void _background(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _foreground(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  setUp(() => _clock = DateTime.utc(2026, 10, 16, 6));

  testWidgets('ticks every minute while the app is resumed', (tester) async {
    await tester.pumpWidget(_app());
    expect(find.text('6:0'), findsOneWidget);

    _clock = _clock.add(DoseTiming.refreshEvery);
    await tester.pump(DoseTiming.refreshEvery);

    expect(find.text('6:1'), findsOneWidget);
  });

  testWidgets('does not tick while paused and refreshes on resume',
      (tester) async {
    await tester.pumpWidget(_app());
    _background(tester);

    _clock = _clock.add(const Duration(minutes: 5));
    await tester.pump(const Duration(minutes: 5));
    expect(find.text('6:0'), findsOneWidget);

    _foreground(tester);
    await tester.pump();
    expect(find.text('6:5'), findsOneWidget);

    // And it ticks again afterwards.
    _clock = _clock.add(DoseTiming.refreshEvery);
    await tester.pump(DoseTiming.refreshEvery);
    expect(find.text('6:6'), findsOneWidget);
  });

  testWidgets('two screens share one timer; the last one stops it',
      (tester) async {
    await tester.pumpWidget(_app(screens: 2));
    _clock = _clock.add(DoseTiming.refreshEvery);
    await tester.pump(DoseTiming.refreshEvery);
    expect(find.text('6:1'), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox.shrink());

    // A pending periodic timer would fail the test at its end.
  });
}
