import 'package:dio/dio.dart';

/// Represents a streamed chunk from the LLM.
sealed class StreamEvent {}

class ContentDelta extends StreamEvent {
  final String text;
  ContentDelta(this.text);
}

class ThinkingDelta extends StreamEvent {
  final String text;
  ThinkingDelta(this.text);
}

class ToolCallDelta extends StreamEvent {
  final int index;
  final String? id;
  final String? name;
  final String argumentsDelta;
  ToolCallDelta({
    required this.index,
    this.id,
    this.name,
    required this.argumentsDelta,
  });
}

class StreamUsage extends StreamEvent {
  final int promptTokens;
  final int completionTokens;
  StreamUsage({required this.promptTokens, required this.completionTokens});
}

class StreamDone extends StreamEvent {}

class StreamError extends StreamEvent {
  final String message;
  StreamError(this.message);
}

/// Contract for LLM API communication.
abstract interface class ILlmService {
  Future<List<String>> fetchModels();

  Stream<StreamEvent> streamChatCompletion({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  });
}
