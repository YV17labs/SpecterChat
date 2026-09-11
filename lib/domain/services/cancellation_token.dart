import 'dart:async';

/// Cooperative cancellation signal shared between the chat pipeline and
/// the transport that performs the request.
///
/// Deliberately independent of any HTTP client: the domain hands one to
/// `ILlmService`, and the implementation maps it onto whatever cancel
/// primitive its transport offers.
class CancellationToken {
  final _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  /// Completes once [cancel] has been called. Never completes with an
  /// error, so it is safe to chain without a catch.
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}
