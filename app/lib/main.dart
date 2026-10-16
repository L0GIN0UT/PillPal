import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
import 'src/reminders/reminder_scope.dart';

void main() {
  runApp(
    const ProviderScope(
      child: ReminderScope(child: PillPalApp()),
    ),
  );
}
