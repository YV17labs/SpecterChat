// Manual end-to-end check against a running MCP server: does a tool call
// survive the server terminating the session? Not part of the suite.
//
//   dart run tool/mcp_session_loss_check.dart http://localhost:3001/mcp "$TOKEN"
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:specterchat/models/app_settings.dart';
import 'package:specterchat/services/mcp/streamable_http_transport.dart'
    as transport;
import 'package:specterchat/services/mcp_service.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: mcp_session_loss_check <mcp url> <bearer token>');
    exit(64);
  }
  final server = McpServerConfig(
    id: 'live',
    name: 'live',
    url: args[0],
    headers: {'Authorization': 'Bearer ${args[1]}'},
  );

  // Transports are injected so the script can read the negotiated session id.
  final made = <transport.StreamableHttpClientTransport>[];
  final service = McpService(clientFactory: (cfg) {
    final t = transport.StreamableHttpClientTransport(
      Uri.parse(cfg.url),
      opts: transport.StreamableHttpClientTransportOptions(
        requestInit: {'headers': cfg.headers},
        httpClient: http.Client(),
      ),
    );
    made.add(t);
    return McpClient(serverUrl: cfg.url, transport: t);
  });

  final connected = await service.connect(server);
  final tool = connected.tools.first.name;
  final first = await service.callTool('live', tool, {});
  print('1. $tool on session ${made.single.sessionId}: isError=${first.isError}');

  // Terminate the session server-side — same outcome as an idle eviction,
  // without waiting for it.
  final del = await http.delete(
    Uri.parse(server.url),
    headers: {...server.headers, 'mcp-session-id': made.single.sessionId!},
  );
  print('2. DELETE session: HTTP ${del.statusCode}');

  final second = await service.callTool('live', tool, {});
  print('3. $tool again: isError=${second.isError}, '
      'clients made=${made.length}, '
      'new session=${made.last.sessionId}, '
      'connected=${service.isConnected('live')}');

  service.disconnectAll();
  exit(second.isError || made.length != 2 ? 1 : 0);
}
