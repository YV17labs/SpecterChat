// Vendored from mcp_dart 2.1.0 (lib/src/client/streamable_https.dart) with one
// change: the constructor accepts an injected `http.Client` so we can wrap it
// with [RetryHttpClient]. Upstream hardcodes `http.Client()` with no override.
//
// Keep this file diffable against the upstream source; if you upgrade
// mcp_dart, re-vendor and re-apply the httpClient injection.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';

const _defaultStreamableHttpReconnectionOptions =
    StreamableHttpReconnectionOptions(
  initialReconnectionDelay: 1000,
  maxReconnectionDelay: 30000,
  reconnectionDelayGrowFactor: 1.5,
  maxRetries: 2,
);

class StreamableHttpError extends Error {
  final int? code;
  final String message;

  StreamableHttpError(this.code, this.message);

  @override
  String toString() => 'Streamable HTTP error: $message';
}

class StartSseOptions {
  final String? resumptionToken;
  final void Function(String token)? onResumptionToken;
  final dynamic replayMessageId;
  final bool shouldReconnect;

  const StartSseOptions({
    this.resumptionToken,
    this.onResumptionToken,
    this.replayMessageId,
    this.shouldReconnect = true,
  });
}

class StreamableHttpReconnectionOptions {
  final int maxReconnectionDelay;
  final int initialReconnectionDelay;
  final double reconnectionDelayGrowFactor;
  final int maxRetries;

  const StreamableHttpReconnectionOptions({
    required this.maxReconnectionDelay,
    required this.initialReconnectionDelay,
    required this.reconnectionDelayGrowFactor,
    required this.maxRetries,
  });
}

class StreamableHttpClientTransportOptions {
  final OAuthClientProvider? authProvider;
  final Map<String, dynamic>? requestInit;
  final StreamableHttpReconnectionOptions? reconnectionOptions;
  final String? sessionId;

  /// Optional HTTP client. If null, a default `http.Client()` is created.
  /// Pass a `RetryHttpClient` here to recover from dead pooled sockets.
  final http.Client? httpClient;

  const StreamableHttpClientTransportOptions({
    this.authProvider,
    this.requestInit,
    this.reconnectionOptions,
    this.sessionId,
    this.httpClient,
  });
}

class StreamableHttpClientTransport
    implements Transport, ProtocolVersionAwareTransport {
  StreamController<bool>? _abortController;
  final Uri _url;
  final Map<String, dynamic>? _requestInit;
  final OAuthClientProvider? _authProvider;
  String? _sessionId;
  String? _protocolVersion;
  final StreamableHttpReconnectionOptions _reconnectionOptions;
  bool _isClosed = false;

  @override
  void Function()? onclose;

  @override
  void Function(Error error)? onerror;

  @override
  void Function(JsonRpcMessage message)? onmessage;

  final http.Client _httpClient;

  StreamableHttpClientTransport(
    Uri url, {
    StreamableHttpClientTransportOptions? opts,
  })  : _url = url,
        _requestInit = opts?.requestInit,
        _authProvider = opts?.authProvider,
        _sessionId = opts?.sessionId,
        _reconnectionOptions = opts?.reconnectionOptions ??
            _defaultStreamableHttpReconnectionOptions,
        _httpClient = opts?.httpClient ?? http.Client();

  Future<void> _authThenStart() async {
    if (_authProvider == null) {
      throw UnauthorizedError('No auth provider');
    }

    AuthResult result;
    try {
      result = await auth(_authProvider, serverUrl: _url);
    } catch (error) {
      if (error is Error) {
        onerror?.call(error);
      } else {
        onerror?.call(McpError(0, error.toString()));
      }
      rethrow;
    }

    if (result != 'AUTHORIZED') {
      throw UnauthorizedError();
    }

    return await _startOrAuthSse(const StartSseOptions());
  }

  Future<Map<String, String>> _commonHeaders() async {
    final headers = <String, String>{};

    if (_authProvider != null) {
      final tokens = await _authProvider.tokens();
      if (tokens != null) {
        headers['Authorization'] = 'Bearer ${tokens.accessToken}';
      }
    }

    if (_sessionId != null) {
      headers['mcp-session-id'] = _sessionId!;
    }

    if (_protocolVersion != null) {
      headers['MCP-Protocol-Version'] = _protocolVersion!;
    }

    if (_requestInit != null && _requestInit.containsKey('headers')) {
      final requestHeaders = _requestInit['headers'] as Map<String, dynamic>;
      for (final entry in requestHeaders.entries) {
        headers[entry.key] = entry.value.toString();
      }
    }

    return headers;
  }

  Future<void> _startOrAuthSse(StartSseOptions options) async {
    final resumptionToken = options.resumptionToken;
    try {
      final headers = await _commonHeaders();
      headers['Accept'] = 'text/event-stream';

      if (resumptionToken != null) {
        headers['last-event-id'] = resumptionToken;
      }

      final request = http.Request('GET', _url);
      request.headers.addAll(headers);
      final response = await _httpClient.send(request);

      if (response.statusCode != 200) {
        if (response.statusCode == 401 && _authProvider != null) {
          return await _authThenStart();
        }

        if (response.statusCode == 405) {
          return;
        }

        throw StreamableHttpError(
          response.statusCode,
          'Failed to open SSE stream: ${response.reasonPhrase}',
        );
      }

      _handleSseStream(response, options);
    } catch (error) {
      if (error is Error) {
        onerror?.call(error);
      } else {
        final err = McpError(0, error.toString());
        onerror?.call(err);
      }
      rethrow;
    }
  }

  int _getNextReconnectionDelay(int attempt) {
    final initialDelay = _reconnectionOptions.initialReconnectionDelay;
    final growFactor = _reconnectionOptions.reconnectionDelayGrowFactor;
    final maxDelay = _reconnectionOptions.maxReconnectionDelay;

    return (initialDelay * math.pow(growFactor, attempt))
        .round()
        .clamp(0, maxDelay);
  }

  void _scheduleReconnection(
    StartSseOptions options, [
    int attemptCount = 0,
    int? retryDelayMs,
  ]) {
    final maxRetries = _reconnectionOptions.maxRetries;

    if (maxRetries > 0 && attemptCount >= maxRetries) {
      onerror?.call(
        McpError(0, 'Maximum reconnection attempts ($maxRetries) exceeded.'),
      );
      return;
    }

    final delay = retryDelayMs ?? _getNextReconnectionDelay(attemptCount);

    Future.delayed(Duration(milliseconds: delay), () {
      _startOrAuthSse(options).catchError((error) {
        final errorMessage =
            error is Error ? error.toString() : error.toString();
        onerror?.call(
          McpError(0, 'Failed to reconnect SSE stream: $errorMessage'),
        );

        _scheduleReconnection(options, attemptCount + 1);

        return null;
      });
    });
  }

  void _handleSseStream(http.StreamedResponse stream, StartSseOptions options) {
    final onResumptionToken = options.onResumptionToken;
    final replayMessageId = options.replayMessageId;

    String? lastEventId;
    int? retryDelayMs;
    String buffer = '';
    String? eventName;
    String? eventId;
    String? eventData;

    void processEvent() {
      if (eventData == null) return;

      if (eventId != null) {
        lastEventId = eventId;
        onResumptionToken?.call(eventId!);
      }

      if (eventName == null || eventName == 'message') {
        try {
          final message = JsonRpcMessage.fromJson(jsonDecode(eventData!));

          if (replayMessageId != null && message is JsonRpcResponse) {
            final newMessage = JsonRpcResponse(
              id: replayMessageId,
              result: message.result,
              meta: message.meta,
            );
            onmessage?.call(newMessage);
          } else {
            onmessage?.call(message);
          }
        } catch (error) {
          if (error is Error) {
            onerror?.call(error);
          } else {
            onerror?.call(McpError(0, error.toString()));
          }
        }
      }

      eventName = null;
      eventId = null;
      eventData = null;
    }

    void handleReconnection(String? eventId, [int? retryDelayOverrideMs]) {
      if (_isClosed || !options.shouldReconnect) return;

      if (_abortController != null && !_abortController!.isClosed) {
        try {
          _scheduleReconnection(
            StartSseOptions(
              resumptionToken: eventId,
              onResumptionToken: onResumptionToken,
              replayMessageId: replayMessageId,
              shouldReconnect: options.shouldReconnect,
            ),
            0,
            retryDelayOverrideMs,
          );
        } catch (error) {
          final errorMessage =
              error is Error ? error.toString() : error.toString();
          onerror?.call(McpError(0, 'Failed to reconnect: $errorMessage'));
        }
      }
    }

    final broadcastStream = stream.stream;

    final subscription =
        broadcastStream.transform(utf8.decoder).asBroadcastStream().listen(
      (data) {
        buffer += data;

        while (buffer.contains('\n')) {
          final index = buffer.indexOf('\n');
          var line = buffer.substring(0, index);
          if (line.endsWith('\r')) {
            line = line.substring(0, line.length - 1);
          }
          buffer = buffer.substring(index + 1);

          if (line.isEmpty) {
            processEvent();
            continue;
          }

          if (line.startsWith(':')) {
            continue;
          }

          final colonIndex = line.indexOf(':');
          if (colonIndex > 0) {
            final field = line.substring(0, colonIndex);
            final valueStart = colonIndex +
                1 +
                (line.length > colonIndex + 1 && line[colonIndex + 1] == ' '
                    ? 1
                    : 0);
            final value = line.substring(valueStart);

            switch (field) {
              case 'event':
                eventName = value;
                break;
              case 'id':
                eventId = value;
                break;
              case 'retry':
                final parsedRetry = int.tryParse(value.trim());
                if (parsedRetry != null && parsedRetry >= 0) {
                  retryDelayMs = parsedRetry;
                }
                break;
              case 'data':
                eventData = (eventData ?? '') + value;
                break;
            }
          }
        }
      },
      onDone: () {
        processEvent();
        handleReconnection(lastEventId, retryDelayMs);
      },
      onError: (error) {
        final errorMessage =
            error is Error ? error.toString() : error.toString();
        onerror?.call(McpError(0, 'SSE stream disconnected: $errorMessage'));

        handleReconnection(lastEventId, retryDelayMs);
      },
    );

    _abortController?.stream.listen((_) {
      subscription.cancel();
    });
  }

  @override
  Future<void> start() async {
    if (_abortController != null) {
      throw McpError(
        0,
        'StreamableHttpClientTransport already started! If using Client class, note that connect() calls start() automatically.',
      );
    }

    _abortController = StreamController<bool>.broadcast();
  }

  Future<void> finishAuth(String authorizationCode) async {
    if (_authProvider == null) {
      throw UnauthorizedError('No auth provider');
    }

    final result = await auth(
      _authProvider,
      serverUrl: _url,
      authorizationCode: authorizationCode,
    );
    if (result != 'AUTHORIZED') {
      throw UnauthorizedError('Failed to authorize');
    }
  }

  @override
  Future<void> close() async {
    _isClosed = true;
    _abortController?.add(true);
    _abortController?.close();
    _httpClient.close();

    onclose?.call();
  }

  @override
  Future<void> send(
    JsonRpcMessage message, {
    int? relatedRequestId,
    String? resumptionToken,
    void Function(String)? onResumptionToken,
  }) async {
    try {
      if (resumptionToken != null) {
        final replayId = message is JsonRpcRequest ? message.id : null;
        _startOrAuthSse(
          StartSseOptions(
            resumptionToken: resumptionToken,
            replayMessageId: replayId,
            onResumptionToken: onResumptionToken,
          ),
        ).catchError((err) {
          if (err is Error) {
            onerror?.call(err);
          } else {
            onerror?.call(McpError(0, err.toString()));
          }
        });
        return;
      }

      if (_authProvider != null) {
        final tokens = await _authProvider.tokens();
        if (tokens == null) {
          await _authProvider.redirectToAuthorization();
          throw UnauthorizedError('Authentication required');
        }
      }

      final headers = await _commonHeaders();
      headers['content-type'] = 'application/json';
      headers['accept'] = 'application/json, text/event-stream';

      final request = http.Request('POST', _url);
      request.headers.addAll(headers);
      request.body = jsonEncode(message.toJson());

      final response = await _httpClient.send(request);

      final sessionId = response.headers['mcp-session-id'];
      if (sessionId != null) {
        _sessionId = sessionId;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 401 && _authProvider != null) {
          await _authProvider.redirectToAuthorization();
          throw UnauthorizedError('Authentication failed with the server');
        }

        final text = await response.stream.transform(utf8.decoder).join();
        throw McpError(
          0,
          'Error POSTing to endpoint (HTTP ${response.statusCode}): $text',
        );
      }

      if (response.statusCode == 202) {
        await response.stream.drain();

        await Future.delayed(Duration.zero);

        if (_isInitializedNotification(message)) {
          _startOrAuthSse(const StartSseOptions()).catchError((err) {
            if (err is Error) {
              onerror?.call(err);
            } else {
              onerror?.call(McpError(0, err.toString()));
            }
          });
        }
        return;
      }

      if (_isInitializedNotification(message)) {
        _startOrAuthSse(const StartSseOptions()).catchError((err) {
          if (err is Error) {
            onerror?.call(err);
          } else {
            onerror?.call(McpError(0, err.toString()));
          }
        });
      }

      final hasRequests = message is JsonRpcRequest && message.id != null;

      final contentType = response.headers['content-type'];

      if (hasRequests) {
        if (contentType?.contains('text/event-stream') ?? false) {
          _handleSseStream(
            response,
            StartSseOptions(
              onResumptionToken: onResumptionToken,
              shouldReconnect: false,
            ),
          );
        } else if (contentType?.contains('application/json') ?? false) {
          final jsonStr = await response.stream.transform(utf8.decoder).join();
          final data = jsonDecode(jsonStr);

          if (data is List) {
            for (final item in data) {
              final msg = JsonRpcMessage.fromJson(item);
              onmessage?.call(msg);
            }
          } else {
            final msg = JsonRpcMessage.fromJson(data);
            onmessage?.call(msg);
          }
        } else {
          throw StreamableHttpError(
            -1,
            'Unexpected content type: $contentType',
          );
        }
      }
    } catch (error) {
      if (error is Error) {
        onerror?.call(error);
      } else {
        onerror?.call(McpError(0, error.toString()));
      }
      rethrow;
    }
  }

  @override
  String? get sessionId => _sessionId;

  @override
  String? get protocolVersion => _protocolVersion;

  @override
  set protocolVersion(String? value) {
    _protocolVersion = value;
  }

  Future<void> terminateSession() async {
    if (_sessionId == null) {
      return;
    }

    try {
      final headers = await _commonHeaders();

      final response = await _httpClient.delete(_url, headers: headers);

      if (response.statusCode < 200 ||
          response.statusCode >= 300 && response.statusCode != 405) {
        throw StreamableHttpError(
          response.statusCode,
          'Failed to terminate session: ${response.reasonPhrase}',
        );
      }

      _sessionId = null;
    } catch (error) {
      if (error is Error) {
        onerror?.call(error);
      } else {
        onerror?.call(McpError(0, error.toString()));
      }
      rethrow;
    }
  }

  bool _isInitializedNotification(JsonRpcMessage message) {
    if (message is JsonRpcNotification) {
      return message.method == 'notifications/initialized';
    }
    return false;
  }
}

class UnauthorizedError extends Error {
  final String? message;

  UnauthorizedError([this.message]);

  @override
  String toString() => 'Unauthorized${message != null ? ': $message' : ''}';
}

abstract class OAuthClientProvider {
  Future<OAuthTokens?> tokens();
  Future<void> redirectToAuthorization();
}

class OAuthTokens {
  final String accessToken;
  final String? refreshToken;

  OAuthTokens({required this.accessToken, this.refreshToken});
}

typedef AuthResult = String;

Future<AuthResult> auth(
  OAuthClientProvider provider, {
  required Uri serverUrl,
  String? authorizationCode,
}) async {
  final tokens = await provider.tokens();
  if (tokens != null) {
    return 'AUTHORIZED';
  }

  if (authorizationCode != null) {
    return 'AUTHORIZED';
  }

  await provider.redirectToAuthorization();
  return 'NEEDS_AUTH';
}
