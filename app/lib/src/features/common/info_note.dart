import 'package:flutter/material.dart';

/// A card with an info icon and an explanation.
class InfoNote extends StatelessWidget {
  /// Creates the note.
  const InfoNote({required this.text, super.key});

  /// The explanation.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}
