import '../../domain/services/i_llm_service.dart';

/// Splits inline `<think>…</think>` markers out of streamed `content`.
///
/// Some servers (llama.cpp by default, a few OpenAI-compatible proxies)
/// send the model's reasoning inside `content` wrapped in tags rather
/// than on a dedicated field. Both tags come from the model's own
/// generation, so the opener always precedes the closer. A tag may span
/// two deltas, so the splitter holds back any trailing characters that
/// could be the start of a tag until the next delta settles it.
///
/// Purely synchronous: no allocation of stream machinery per token.
class SseThinkSplitter {
  static const _openTag = '<think>';
  static const _closeTag = '</think>';

  bool _inThinking = false;
  String _buf = '';

  /// Feed one content delta; returns the events it resolves to.
  ///
  /// Eager (a list, not a lazy iterable): the state mutation must happen
  /// exactly once, when the delta is pushed.
  List<StreamEvent> push(String content) => _push(content).toList();

  /// Emit whatever is still held back. Call once the stream has ended.
  List<StreamEvent> flush() => _flush().toList();

  Iterable<StreamEvent> _push(String content) sync* {
    _buf += content;
    while (true) {
      if (_inThinking) {
        final idx = _buf.indexOf(_closeTag);
        if (idx >= 0) {
          if (idx > 0) yield ThinkingDelta(_buf.substring(0, idx));
          // Strip the blank line some models emit after </think>.
          _buf = _buf
              .substring(idx + _closeTag.length)
              .replaceFirst(RegExp(r'^\n{1,2}'), '');
          _inThinking = false;
          continue;
        }
        final safe = _buf.length - _partialTagSuffixLen(_buf, _closeTag);
        if (safe > 0) {
          yield ThinkingDelta(_buf.substring(0, safe));
          _buf = _buf.substring(safe);
        }
        return;
      }

      final idx = _buf.indexOf(_openTag);
      if (idx >= 0) {
        if (idx > 0) yield ContentDelta(_buf.substring(0, idx));
        _buf = _buf.substring(idx + _openTag.length);
        _inThinking = true;
        continue;
      }
      final safe = _buf.length - _partialTagSuffixLen(_buf, _openTag);
      if (safe > 0) {
        yield ContentDelta(_buf.substring(0, safe));
        _buf = _buf.substring(safe);
      }
      return;
    }
  }

  Iterable<StreamEvent> _flush() sync* {
    if (_buf.isEmpty) return;
    yield _inThinking ? ThinkingDelta(_buf) : ContentDelta(_buf);
    _buf = '';
  }

  /// Longest suffix of [s] that is also a proper prefix of [tag].
  static int _partialTagSuffixLen(String s, String tag) {
    final maxLen = s.length < tag.length - 1 ? s.length : tag.length - 1;
    for (var n = maxLen; n > 0; n--) {
      if (s.endsWith(tag.substring(0, n))) return n;
    }
    return 0;
  }
}
