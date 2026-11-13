import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/text_fit.dart';
import 'package:pillpal/src/theme/sizes.dart';

import 'common_test_host.dart';

// Word measurement behind the narrow-screen layouts. The test font draws
// every glyph 1 em wide: a 10 px word of N letters is N * 10 wide.

const TextStyle _style = TextStyle(fontSize: 10);

/// Runs [body] with a context of a themed app at text [scale].
Future<void> _withContext(
  WidgetTester tester,
  void Function(BuildContext context) body, {
  double scale = 1,
}) async {
  late BuildContext captured;
  await pumpThemed(
    tester,
    Builder(
      builder: (context) {
        captured = context;
        return const SizedBox.shrink();
      },
    ),
    scale: scale,
  );
  body(captured);
}

void main() {
  testWidgets('the longest word sets the width, at the text scale',
      (tester) async {
    await _withContext(tester, (context) {
      expect(longestWordWidth(context, 'ab abcdef abc', _style), 60);
    });
    await _withContext(
      tester,
      (context) {
        expect(longestWordWidth(context, 'ab abcdef abc', _style), 120);
      },
      scale: 2,
    );
  });

  testWidgets('wordsFit checks every word of every text', (tester) async {
    await _withContext(tester, (context) {
      expect(wordsFit(context, 60, const [('ab abcdef', _style)]), isTrue);
      expect(
        wordsFit(context, 59, const [('ab', _style), ('abcdef', _style)]),
        isFalse,
      );
      expect(
        wordsFit(context, double.infinity, const [('abcdef', _style)]),
        isTrue,
      );
    });
  });

  testWidgets('rowIsCompact: from the compact scale, or when a word breaks',
      (tester) async {
    await _withContext(tester, (context) {
      const texts = [('abcdef', _style)];
      expect(
        rowIsCompact(context, width: 100, reserved: 40, texts: texts),
        isFalse,
      );
      expect(
        rowIsCompact(context, width: 100, reserved: 41, texts: texts),
        isTrue,
      );
    });
    await _withContext(
      tester,
      (context) {
        expect(
          rowIsCompact(
            context,
            width: 1000,
            reserved: 0,
            texts: const [('ab', _style)],
          ),
          isTrue,
        );
      },
      scale: PillPalSizes.compactScale,
    );
  });
}
