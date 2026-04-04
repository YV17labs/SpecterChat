import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'mcp_provider.dart';
import 'settings_provider.dart';

final _log = Logger('AppLifecycle');

/// Application lifecycle events.
enum AppEvent { started, resumed, paused }

/// Callback signature for lifecycle event handlers.
typedef AppEventHandler = Future<void> Function(WidgetRef ref);

/// Manages application lifecycle and dispatches events to registered handlers.
///
/// Add new startup or resume behaviors by registering handlers in [_handlers]
/// rather than scattering logic across main.dart or individual providers.
class AppLifecycleNotifier extends WidgetsBindingObserver {
  final WidgetRef _ref;
  bool _started = false;

  AppLifecycleNotifier(this._ref);

  /// Event → handler registry. Add new lifecycle actions here.
  static final Map<AppEvent, List<AppEventHandler>> _handlers = {
    AppEvent.started: [_reconnectMcpServers],
    AppEvent.resumed: [_reconnectMcpServers],
  };

  /// Call once after the first frame to fire [AppEvent.started].
  void initialize() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _dispatch(AppEvent.started);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _dispatch(AppEvent.resumed);
      case AppLifecycleState.paused:
        _dispatch(AppEvent.paused);
      default:
        break;
    }
  }

  void _dispatch(AppEvent event) {
    final handlers = _handlers[event];
    if (handlers == null) return;
    for (final handler in handlers) {
      handler(_ref).ignore();
    }
  }

  // ---------------------------------------------------------------------------
  // Event handlers
  // ---------------------------------------------------------------------------

  /// Reconnect all enabled MCP servers that aren't currently connected.
  static Future<void> _reconnectMcpServers(WidgetRef ref) async {
    final settings = ref.read(settingsProvider);
    final mcpService = ref.read(mcpServiceProvider);
    final notifier = ref.read(settingsProvider.notifier);

    await Future.wait(
      settings.mcpServers
          .where((s) => s.enabled && !s.connected)
          .map((server) async {
        try {
          await connectMcpServer(
            server: server,
            mcpService: mcpService,
            notifier: notifier,
          );
        } catch (e) {
          _log.info('MCP server "${server.name}" unavailable on reconnect', e);
        }
      }),
    );
  }
}
