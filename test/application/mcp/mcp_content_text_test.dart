import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/mcp/mcp_content_text.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/services/i_mcp_service.dart';

void main() {
  test('promptMessagesToText joins text blocks, drops the rest', () {
    final result = McpPromptResult(
      messages: [
        McpPromptMessage(
          role: MessageRole.user,
          content: [McpTextContent('a')],
        ),
        McpPromptMessage(
          role: MessageRole.assistant,
          content: [
            McpImageContent(base64Data: 'x', mimeType: 'image/png'),
            McpTextContent('b'),
          ],
        ),
      ],
    );
    expect(promptMessagesToText(result), 'a\n\nb');
  });

  test('resourceContentsToText embeds text and describes blobs', () {
    final result = McpResourceResult(
      contents: [
        McpResourceTextContent(uri: 'x://1', text: 'hello'),
        McpResourceBlobContent(
          uri: 'x://2',
          mimeType: 'image/png',
          base64Data: 'abcd',
        ),
      ],
    );
    expect(
      resourceContentsToText(result),
      'hello\n\n[Binary resource: x://2 (image/png), 4 base64 chars]',
    );
  });
}
