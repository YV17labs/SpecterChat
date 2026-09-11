import '../models/app_settings.dart';
import '../models/message.dart';
import 'cancellation_token.dart';

/// Represents a streamed chunk from the LLM.
sealed class StreamEvent {
  const StreamEvent();
}

class ContentDelta extends StreamEvent {
  final String text;
  const ContentDelta(this.text);
}

class ThinkingDelta extends StreamEvent {
  final String text;
  const ThinkingDelta(this.text);
}

class ToolCallDelta extends StreamEvent {
  final int index;
  final String? id;
  final String? name;
  final String argumentsDelta;
  const ToolCallDelta({
    required this.index,
    this.id,
    this.name,
    required this.argumentsDelta,
  });
}

class StreamUsage extends StreamEvent {
  final int promptTokens;
  final int completionTokens;
  const StreamUsage({
    required this.promptTokens,
    required this.completionTokens,
  });
}

/// The model finished its turn normally.
class StreamDone extends StreamEvent {
  const StreamDone();
}

/// The caller cancelled the request. Whatever arrived before this event is
/// partial; nothing that follows the cancel was ever generated.
class StreamCancelled extends StreamEvent {
  const StreamCancelled();
}

class StreamError extends StreamEvent {
  final String message;
  const StreamError(this.message);
}

/// Contract for LLM API communication.
///
/// Takes domain messages — the wire format (OpenAI chat/completions) is an
/// implementation detail of the service, not something the chat pipeline
/// knows about.
abstract interface class ILlmService {
  Future<List<String>> fetchModels();

  Stream<StreamEvent> streamChatCompletion({
    required List<Message> history,
    required String systemPrompt,
    ImageBytesMap imageBytes = const {},
    List<McpToolInfo> tools = const [],
    CancellationToken? cancellationToken,
  });
}

class LlmException implements Exception {
  final String message;
  LlmException(this.message);

  @override
  String toString() => message;
}
