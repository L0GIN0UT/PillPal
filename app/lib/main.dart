import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/features/report/report_files.dart';
import 'src/home_widget/home_widget_scope.dart';
import 'src/reminders/providers.dart';
import 'src/reminders/reminder_scope.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // A report shared in an earlier session must not stay on the device.
  unawaited(const ReportFiles(getTemporaryDirectory).clear());
  runApp(
    ProviderScope(
      overrides: reminderAppOverrides,
      child: const ReminderScope(
        child: HomeWidgetScope(child: PillPalApp()),
      ),
    ),
  );
}
