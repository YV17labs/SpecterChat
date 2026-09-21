import 'dart:typed_data';

import '../chat_session_state.dart' show GenerationProgress;
import '../models/app_settings.dart';
import '../models/message.dart';
import '../models/model_info.dart';
import '../models/request_profile.dart';
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

/// Progress of a long-running server-side step (image generation). Purely
/// transient: the session mirrors the latest one into its state for the UI
/// and never persists it.
class ProgressDelta extends StreamEvent {
  final GenerationProgress progress;
  const ProgressDelta(this.progress);
}

/// One complete image produced by the assistant turn (decoded bytes, never
/// a URL).
class ImageDelta extends StreamEvent {
  final Uint8List bytes;
  final String mimeType;

  /// What the server says it did: `true` drawn from the prompt alone,
  /// `false` edited from the images it was sent, `null` when it does not
  /// say (`ChatLogic.generatedImageOrigin` then decides).
  final bool? textToImage;

  const ImageDelta({
    required this.bytes,
    required this.mimeType,
    this.textToImage,
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
  /// The server's model list, sorted by id. Image-generation servers
  /// describe themselves in [ModelInfo.image].
  Future<List<ModelInfo>> fetchModels();

  /// One assistant turn as a stream of events. [profile] decides what the
  /// request carries besides [history]: a text profile sends [systemPrompt]
  /// and [tools] along with its sampling parameters; an image profile
  /// sends its image options and drops both (the server ignores them).
  Stream<StreamEvent> streamChatCompletion({
    required List<Message> history,
    required String systemPrompt,
    RequestProfile profile = const TextRequestProfile(),
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
