import 'package:flutter/widgets.dart';

/// Scrolls [child] into view once, after its first frame: the details of a
/// tapped day open below the calendar, off screen on a small phone. Key it
/// by what it shows so another day scrolls again.
class ScrollIntoView extends StatefulWidget {
  /// Creates the wrapper.
  const ScrollIntoView({required this.child, super.key});

  /// The widget to bring on screen.
  final Widget child;

  @override
  State<ScrollIntoView> createState() => _ScrollIntoViewState();
}

class _ScrollIntoViewState extends State<ScrollIntoView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 250),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
