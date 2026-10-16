import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
import 'src/reminders/providers.dart';
import 'src/reminders/reminder_scope.dart';

void main() {
  runApp(
    ProviderScope(
      overrides: reminderAppOverrides,
      child: const ReminderScope(child: PillPalApp()),
    ),
  );
}
