import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:specterchat/services/mcp/retry_http_client.dart';

void main() {
  group('RetryHttpClient (unit)', () {
    test('replays once on "Connection closed before full header" and returns the second response',
        () async {
      var attempts = 0;
      final inner = _StubClient((req) async {
        attempts++;
        if (attempts == 1) {
          throw http.ClientException(
            'Connection closed before full header was received',
            req.url,
          );
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"ok":true}')),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = RetryHttpClient(inner);
      final response = await client.send(_jsonPost('https://example/mcp'));

      expect(attempts, 2);
      expect(response.statusCode, 200);
      expect(await response.stream.bytesToString(), '{"ok":true}');
    });

    test('also handles the "while receiving data" variant', () async {
      var attempts = 0;
      final inner = _StubClient((req) async {
        attempts++;
        if (attempts == 1) {
          throw http.ClientException(
            'Connection closed while receiving data',
            req.url,
          );
        }
        return http.StreamedResponse(const Stream.empty(), 204);
      });

      final response = await RetryHttpClient(inner).send(
        _jsonPost('https://example/mcp'),
      );
      expect(attempts, 2);
      expect(response.statusCode, 204);
    });

    test('does not retry on unrelated ClientException', () async {
      var attempts = 0;
      final inner = _StubClient((req) async {
        attempts++;
        throw http.ClientException('Connection refused', req.url);
      });

      await expectLater(
        RetryHttpClient(inner).send(_jsonPost('https://example/mcp')),
        throwsA(isA<http.ClientException>()),
      );
      expect(attempts, 1);
    });

    test('does not retry on SocketException', () async {
      var attempts = 0;
      final inner = _StubClient((req) async {
        attempts++;
        throw const SocketException('connect failure');
      });

      await expectLater(
        RetryHttpClient(inner).send(_jsonPost('https://example/mcp')),
        throwsA(isA<SocketException>()),
      );
      expect(attempts, 1);
    });

    test('propagates the second failure when retry also fails', () async {
      var attempts = 0;
      final inner = _StubClient((req) async {
        attempts++;
        throw http.ClientException(
          'Connection closed before full header was received',
          req.url,
        );
      });

      await expectLater(
        RetryHttpClient(inner).send(_jsonPost('https://example/mcp')),
        throwsA(isA<http.ClientException>()),
      );
      expect(attempts, 2);
    });

    test('replayed request preserves method, URL, headers, and body', () async {
      final captured = <_CapturedRequest>[];
      final inner = _StubClient((req) async {
        captured.add(_CapturedRequest(
          method: req.method,
          url: req.url,
          headers: Map.of(req.headers),
          body: await req.finalize().bytesToString(),
        ));
        if (captured.length == 1) {
          throw http.ClientException(
            'Connection closed before full header was received',
            req.url,
          );
        }
        return http.StreamedResponse(const Stream.empty(), 202);
      });

      final original = http.Request('POST', Uri.parse('https://example/mcp'))
        ..headers['content-type'] = 'application/json'
        ..headers['x-custom'] = 'token-42'
        ..body = '{"jsonrpc":"2.0","method":"tools/call","id":7}';

      await RetryHttpClient(inner).send(original);

      expect(captured.length, 2);
      final replayed = captured[1];
      expect(replayed.method, 'POST');
      expect(replayed.url.toString(), 'https://example/mcp');
      expect(replayed.headers['content-type'], 'application/json');
      expect(replayed.headers['x-custom'], 'token-42');
      expect(replayed.body, '{"jsonrpc":"2.0","method":"tools/call","id":7}');
      // Both attempts must carry the same body bytes — no partial consumption.
      expect(captured[0].body, captured[1].body);
    });
  });

  group('RetryHttpClient (integration with real sockets)', () {
    test(
        'recovers when the server closes the TCP socket before sending response bytes',
        () async {
      // Two real sockets: the first accept() drops the connection without
      // writing any HTTP bytes — exactly the FIN-on-idle-keepalive race that
      // bites us in production. The second accept() returns a normal 200.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      var connection = 0;
      server.listen((socket) {
        connection++;
        if (connection == 1) {
          // Read enough of the request to be sure the client wrote it,
          // then destroy the socket without responding.
          socket.listen(
            (_) {},
            onDone: () {},
            cancelOnError: true,
          );
          // Give the client a moment to flush its request before we kill it.
          Future<void>.delayed(const Duration(milliseconds: 20), () {
            socket.destroy();
          });
        } else {
          socket.listen(
            (data) {
              // Once we see the end of the request line, reply.
              if (utf8.decode(data, allowMalformed: true).contains('\r\n\r\n')) {
                socket.add(utf8.encode(
                  'HTTP/1.1 200 OK\r\n'
                  'Content-Type: application/json\r\n'
                  'Content-Length: 11\r\n'
                  'Connection: close\r\n'
                  '\r\n'
                  '{"ok":true}',
                ));
                socket.flush().then((_) => socket.close());
              }
            },
            cancelOnError: true,
          );
        }
      });

      final client = RetryHttpClient(http.Client());
      addTearDown(client.close);

      final request = http.Request(
        'POST',
        Uri.parse('http://${server.address.host}:${server.port}/mcp'),
      )
        ..headers['content-type'] = 'application/json'
        ..body = '{"jsonrpc":"2.0","method":"ping","id":1}';

      final response = await client.send(request);
      expect(response.statusCode, 200);
      expect(await response.stream.bytesToString(), '{"ok":true}');
      expect(connection, 2);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}

http.Request _jsonPost(String url) {
  return http.Request('POST', Uri.parse(url))
    ..headers['content-type'] = 'application/json'
    ..body = '{"jsonrpc":"2.0","method":"ping","id":1}';
}

class _CapturedRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;

  _CapturedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });
}

class _StubClient extends http.BaseClient {
  final FutureOr<http.StreamedResponse> Function(http.BaseRequest request) handler;

  _StubClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return await handler(request);
  }
}
