import '../../domain/services/i_mcp_service.dart';

/// Flatten a `prompts/get` result into text the user can drop into the
/// chat input. Only text blocks survive; roles are not rendered.
String promptMessagesToText(McpPromptResult result) {
  final buf = StringBuffer();
  for (final msg in result.messages) {
    for (final c in msg.content) {
      if (c is McpTextContent) {
        if (buf.isNotEmpty) buf.write('\n\n');
        buf.write(c.text);
      }
    }
  }
  return buf.toString();
}

/// Flatten a `resources/read` result into text. Binary blobs are described
/// rather than embedded — the input box is text-only.
String resourceContentsToText(McpResourceResult result) {
  final buf = StringBuffer();
  for (final c in result.contents) {
    if (buf.isNotEmpty) buf.write('\n\n');
    switch (c) {
      case McpResourceTextContent():
        buf.write(c.text);
      case McpResourceBlobContent():
        buf.write(
          '[Binary resource: ${c.uri}'
          '${c.mimeType != null ? " (${c.mimeType})" : ""}'
          ', ${c.base64Data.length} base64 chars]',
        );
    }
  }
  return buf.toString();
}
