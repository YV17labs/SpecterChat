import 'dart:async';

import 'package:intl/date_symbol_data_local.dart';

/// Runs before every test file: what `main` sets up before `runApp` and
/// widgets read synchronously — the date formats of every locale.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await initializeDateFormatting();
  await testMain();
}
