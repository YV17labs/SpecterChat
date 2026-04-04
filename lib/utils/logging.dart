import 'dart:developer' as developer;

import 'package:logging/logging.dart';

/// Initializes the root logger with console output.
///
/// Call once in `main()` before `runApp()`.
void initLogging() {
  // Log everything in debug; in release you could raise this to Level.WARNING.
  Logger.root.level = Level.ALL;

  Logger.root.onRecord.listen((record) {
    final time = record.time.toIso8601String().substring(11, 23); // HH:mm:ss.mmm
    final level = record.level.name.padRight(7);
    final loggerName = record.loggerName;
    final message = record.message;

    final buffer = StringBuffer('$time $level $loggerName: $message');
    if (record.error != null) {
      buffer.write('\n  Error: ${record.error}');
    }
    if (record.stackTrace != null) {
      buffer.write('\n  Stack: ${record.stackTrace}');
    }

    // ignore: avoid_print
    print(buffer);

    developer.log(
      message,
      time: record.time,
      level: record.level.value,
      name: record.loggerName,
      error: record.error,
      stackTrace: record.stackTrace,
    );
  });
}
