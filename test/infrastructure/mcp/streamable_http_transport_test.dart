import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_dart/mcp_dart.dart'
    show JsonRpcInitializedNotification, JsonRpcRequest, McpError;
import 'package:specterchat/infrastructure/mcp/streamable_http_transport.dart';

const _sessionNotFound = 'Not Found: Session not found';

StreamableHttpClientTransport _transport(
  MockClient client, {
  String? sessionId,
}) {
  return StreamableHttpClientTransport(
    Uri.parse('http://localhost:3001/mcp'),
    opts: StreamableHttpClientTransportOptions(
      httpClient: client,
      sessionId: sessionId,
      // Fast enough that a retry, if one were scheduled, lands inside a test.
      reconnectionOptions: const StreamableHttpReconnectionOptions(
        initialReconnectionDelay: 10,
        maxReconnectionDelay: 10,
        reconnectionDelayGrowFactor: 1,
        maxRetries: 2,
      ),
    ),
  );
}

const _toolCall = JsonRpcRequest(
  id: 1,
  method: 'tools/call',
  params: {'name': 'screen_shot', 'arguments': <String, Object?>{}},
);

void main() {
  group('a 404 on a request that carried mcp-session-id', () {
    test('forgets the session and raises SessionNotFoundError', () async {
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        return http.Response(_sessionNotFound, 404);
      });
      final transport = _transport(client, sessionId: 'dead-session');

      await expectLater(
        transport.send(_toolCall),
        throwsA(
          isA<SessionNotFoundError>()
              .having((e) => e.code, 'code', 404)
              .having((e) => e.message, 'message', contains('dead-session'))
              .having((e) => e.message, 'message', contains(_sessionNotFound)),
        ),
      );

      expect(seen.single.headers['mcp-session-id'], 'dead-session');
      expect(
        transport.sessionId,
        isNull,
        reason: 'nothing may re-offer an id the server refused',
      );
    });

    test(
      'is reported to onerror once, so the protocol layer logs it',
      () async {
        final client = MockClient(
          (_) async => http.Response(_sessionNotFound, 404),
        );
        final transport = _transport(client, sessionId: 'dead-session');
        final reported = <Error>[];
        transport.onerror = reported.add;

        await expectLater(
          transport.send(_toolCall),
          throwsA(isA<SessionNotFoundError>()),
        );

        expect(reported.single, isA<SessionNotFoundError>());
      },
    );
  });

  test('a 404 with no session in play stays a generic POST error', () async {
    final client = MockClient((_) async => http.Response('Not Found', 404));
    final transport = _transport(client);

    await expectLater(
      transport.send(_toolCall),
      throwsA(
        isA<McpError>().having(
          (e) => e.message,
          'message',
          contains('HTTP 404'),
        ),
      ),
    );
  });

  test('a session-terminated SSE open stops the reconnection loop', () async {
    // The standalone GET stream opens right after `notifications/initialized`
    // is accepted; a server that has since evicted the session answers 404.
    var gets = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        gets++;
        return http.Response(_sessionNotFound, 404);
      }
      return http.Response('', 202);
    });
    final transport = _transport(client, sessionId: 'dead-session');
    final reported = <Error>[];
    transport.onerror = reported.add;

    await transport.start();
    await transport.send(const JsonRpcInitializedNotification());
    // Long enough for a first reconnection attempt if one were scheduled.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(gets, 1, reason: 'the refused id must not be retried');
    expect(transport.sessionId, isNull);
    // Upstream reports an SSE-open failure from both `_startOrAuthSse` and
    // `send`'s catchError; what matters here is that it is named, and that no
    // 'Failed to reconnect' report follows it.
    expect(reported.whereType<SessionNotFoundError>(), isNotEmpty);
    expect(
      reported.map((e) => e.toString()),
      everyElement(isNot(contains('Failed to reconnect'))),
    );
  });
}
