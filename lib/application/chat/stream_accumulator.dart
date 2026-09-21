import '../../domain/models/message.dart';
import '../../domain/services/i_llm_service.dart';

/// Accumulates streamed tool call fragments into complete tool calls.
class ToolCallAccumulator {
  String? id;
  String? name;
  final StringBuffer argumentsBuffer = StringBuffer();

  bool get isValid => id != null && name != null;

  /// Arguments so far. Complete only once the stream has ended.
  String get arguments => argumentsBuffer.toString();
}

/// Mutable buffers for one in-flight assistant turn.
///
/// Owns nothing but strings and tool-call fragments; the session feeds it
/// [StreamEvent]s and asks it what has changed since the last persist.
class StreamAccumulator {
  final StringBuffer content = StringBuffer();
  final StringBuffer thinking = StringBuffer();
  final Map<int, ToolCallAccumulator> toolCalls = {};

  /// Images that arrived on the stream, as the blocks the final message
  /// will carry. Their bytes are already in the attachments table; only
  /// the reference is buffered so the accumulator never holds pixels.
  final List<ImageContentBlock> images = [];

  bool _dirty = false;

  /// Some servers leak the start of a `(`-call, a newline or an XML tag
  /// into the tool name; keep only the identifier.
  static final _toolNameNoise = RegExp(r'[(\n<]');

  /// `true` when something arrived since the last [markPersisted].
  bool get isDirty => _dirty;

  bool get hasValidToolCalls => toolCalls.values.any((tc) => tc.isValid);

  /// Whether the turn carries anything worth keeping.
  bool get isSendable =>
      content.isNotEmpty || images.isNotEmpty || hasValidToolCalls;

  void addContent(String text) {
    content.write(text);
    _dirty = true;
  }

  void addThinking(String text) {
    thinking.write(text);
    _dirty = true;
  }

  /// Record an image whose bytes the caller has already persisted.
  void addImage(ImageContentBlock image) {
    images.add(image);
    _dirty = true;
  }

  /// Merges a tool-call fragment. Returns `true` when the fragment opened a
  /// tool call not seen before — the caller flushes immediately so the
  /// tool name shows up without waiting for the throttle window.
  bool addToolCallDelta(ToolCallDelta delta) {
    final isNew = !toolCalls.containsKey(delta.index);
    final tc = toolCalls.putIfAbsent(delta.index, ToolCallAccumulator.new);
    if (delta.id != null) tc.id = delta.id;
    final name = delta.name;
    if (name != null) {
      final clean = name.split(_toolNameNoise).first.trim();
      tc.name = clean.isNotEmpty ? clean : name;
    }
    tc.argumentsBuffer.write(delta.argumentsDelta);
    _dirty = true;
    return isNew;
  }

  /// Whether a persist is due — `true` once per batch of changes, or
  /// always with [force]. Clears the dirty flag either way.
  bool shouldPersist({bool force = false}) {
    if (!force && !_dirty) return false;
    _dirty = false;
    return true;
  }

  /// Drop tool calls whose arguments were cut mid-stream — replaying them
  /// would make the server reject every later turn.
  void dropIncompleteToolCalls() {
    toolCalls.removeWhere((_, tc) => !hasParseableToolCallArgs(tc.arguments));
  }

  void reset() {
    content.clear();
    thinking.clear();
    toolCalls.clear();
    images.clear();
    _dirty = false;
  }
}
