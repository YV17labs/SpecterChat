import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    AppEvent.started: [],
    AppEvent.resumed: [],
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
}
