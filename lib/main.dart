import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

import 'ui/app_shell.dart';
import 'utils/logging.dart';
import 'utils/theme.dart';

final _log = Logger('Main');

void main() async {
  initLogging();

  WidgetsFlutterBinding.ensureInitialized();

  // Catch Flutter framework errors (widget build failures, etc.)
  FlutterError.onError = (details) {
    _log.severe(
      'FlutterError: ${details.exceptionAsString()}',
      details.exception,
      details.stack,
    );
  };

  // Catch async errors not handled by any zone.
  PlatformDispatcher.instance.onError = (error, stack) {
    _log.severe('Uncaught async error', error, stack);
    return true;
  };

  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(800, 500),
    center: true,
    title: 'SpecterChat',
    titleBarStyle: TitleBarStyle.normal,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const ProviderScope(child: SpecterApp()));
}

class SpecterApp extends StatelessWidget {
  const SpecterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpecterChat',
      debugShowCheckedModeBanner: false,
      theme: SpecterTheme.darkTheme,
      home: const AppShell(),
    );
  }
}
