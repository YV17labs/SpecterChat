import 'package:http/http.dart' as http;

/// Substrings of [http.ClientException.message] we treat as a dead pooled
/// socket. The exact wording differs across `dart:io` versions; both have
/// been observed in the wild for the same race.
const _deadSocketMarkers = <String>[
  'Connection closed before full header was received',
  'Connection closed while receiving data',
];

bool _isDeadPooledSocket(Object error) {
  if (error is! http.ClientException) return false;
  return _deadSocketMarkers.any(error.message.contains);
}

/// HTTP client wrapper that retries the very specific race in which
/// `dart:io`'s connection pool hands out a socket the server already
/// half-closed.
///
/// When the inner client throws [http.ClientException] with message
/// "Connection closed before full header was received" (or the equivalent
/// "while receiving data"), we know **zero bytes** of response were read
/// before EOF. RFC 7230 §6.3.1 — and the standard practice from Go's
/// `net/http`, OkHttp, libcurl — says the request is replayable in this
/// case, because the server never saw it: no side effects can have
/// occurred. We retry exactly once on a fresh request; any further
/// failure (or any other error class) propagates unchanged.
///
/// Scope is intentionally narrow: this is **not** a general-purpose retry
/// policy. Do not extend it to other exceptions, status codes, or methods
/// — the "0 bytes read so POST is replayable" reasoning only holds for
/// this exact failure mode.
class RetryHttpClient extends http.BaseClient {
  final http.Client _inner;

  RetryHttpClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // BaseRequest.finalize() returns a single-use ByteStream, so we
    // snapshot the body up-front to be able to rebuild the request on a
    // second attempt. The MCP transport only constructs http.Request
    // instances (POST with a JSON body, GET with empty body), both
    // trivially replayable.
    final bodyBytes = await request.finalize().toBytes();

    try {
      return await _inner.send(_replayable(request, bodyBytes));
    } on http.ClientException catch (e) {
      if (!_isDeadPooledSocket(e)) rethrow;
      return await _inner.send(_replayable(request, bodyBytes));
    }
  }

  @override
  void close() => _inner.close();

  static http.Request _replayable(http.BaseRequest original, List<int> body) {
    return http.Request(original.method, original.url)
      ..headers.addAll(original.headers)
      ..bodyBytes = body
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = original.persistentConnection;
  }
}
