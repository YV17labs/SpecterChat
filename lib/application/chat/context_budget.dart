import '../../domain/models/message.dart';
import '../conversations/conversation_runs.dart';

/// Tokens counted for one image, whatever its size.
///
/// What an image really costs depends on the model — tiles for OpenAI,
/// pixels over 750 for Anthropic, a projector's own patch count for a
/// local vision model — and an OpenAI-compatible server says none of it.
/// Continue, which also speaks to every backend and cannot know either,
/// counts a flat 1024 (`core/llm/countTokens.ts`); this follows it.
const int kImageTokens = 1024;

/// Bytes of UTF-8 per token. Four is the usual rule of thumb for prose;
/// JSON and code run denser, which is part of what [kBudgetBuffer] is
/// there to absorb.
const int kBytesPerToken = 4;

/// What a message costs beyond its content: its role, and the framing
/// the server's chat template puts around it.
const int kMessageTokens = 4;

/// The share of the window held back for the estimate being wrong, on
/// top of what the answer will take. Roo-Code holds back the same tenth
/// (`TOKEN_BUFFER_PERCENTAGE` in its context management).
const double kBudgetBuffer = 0.1;

/// What one request may carry, and so what is left out of it when the
/// history no longer fits.
///
/// The app talks to any OpenAI-compatible server: there is no tokenizer
/// to ask and no `count_tokens` endpoint to call, so what a history
/// weighs is estimated rather than measured and the buffer absorbs the
/// error. Trimming here rather than letting the server do it is the
/// whole point — a server that overflows decides alone what to forget,
/// says nothing about it, and can cut a tool call away from the result
/// that answers it.
class ContextBudget {
  /// The model's window, as the user set it
  /// (`AppSettings.contextLength`). Zero or less: nothing is trimmed.
  final int contextLength;

  /// What the answer may take, and so what the prompt may not
  /// (`GenerationSettings.maxTokens`).
  final int answerTokens;

  /// How many of the history's images travel, the newest first. Zero
  /// sends every one of them, and that is the default: keeping only the
  /// last few is not a norm — the one documented precedent is
  /// Anthropic's computer-use demo, which keeps three on the stated
  /// assumption that "images are screenshots that are of diminishing
  /// value as the conversation progresses". That assumption holds for an
  /// agent watching a screen and not for a conversation about three
  /// photographs, so the user says which they are having.
  final int imageLimit;

  const ContextBudget({
    required this.contextLength,
    required this.answerTokens,
    this.imageLimit = 0,
  });

  /// The whole history travels, whatever it weighs. What an image
  /// request uses — it carries no history worth trimming — and what a
  /// test uses when the budget is not what it is about.
  const ContextBudget.unlimited()
    : contextLength = 0,
      answerTokens = 0,
      imageLimit = 0;

  /// Whether nothing can be left out, whatever the history holds.
  bool get isUnlimited => contextLength <= 0 && imageLimit <= 0;

  /// What the prompt may weigh: the window, less the answer, less the
  /// buffer. `null` when no window was set, so nothing is weighed.
  int? get maxPromptTokens {
    if (contextLength <= 0) return null;
    final left =
        contextLength - answerTokens - (contextLength * kBudgetBuffer).round();
    return left > 0 ? left : 0;
  }
}

/// A history as it will be sent, and what it cost to make it fit.
typedef HistoryTrim = ({
  /// What goes to the model.
  List<Message> history,

  /// Whole exchanges dropped from the oldest end.
  int droppedRuns,

  /// Images taken off the messages that stayed.
  int droppedImages,
});

/// What [message] is estimated to weigh on the wire.
///
/// Only what is actually sent is counted. Reasoning never travels —
/// `OpenAiCodec.contentParts` drops thinking blocks — so counting it
/// would trim a history that fits. A tool result is counted as the text
/// the model is given, not as the whole server answer kept beside it.
int estimateMessageTokens(Message message) {
  final (:bytes, :images) = _countBlocks(message.content);
  return kMessageTokens +
      (bytes + kBytesPerToken - 1) ~/ kBytesPerToken +
      images * kImageTokens;
}

/// What [blocks] send: the bytes of their text, and how many pictures.
({int bytes, int images}) _countBlocks(Iterable<ContentBlock> blocks) {
  var bytes = 0;
  var images = 0;
  for (final block in blocks) {
    switch (block) {
      case TextContentBlock(:final text):
        bytes += utf8Length(text);
      case ToolCallContentBlock(:final name, :final arguments):
        bytes += utf8Length(name) + utf8Length(arguments);
      case ToolResultContentBlock(:final resultContent):
        final inner = _countBlocks(resultContent);
        bytes += inner.bytes;
        images += inner.images;
      case ImageContentBlock():
        images++;
      case ThinkingContentBlock():
        break;
    }
  }
  return (bytes: bytes, images: images);
}

/// [history] cut down to what [budget] allows.
///
/// Images go first, because one is worth a thousand tokens of the
/// conversation that would otherwise be dropped to make room for it.
/// What still does not fit is dropped a whole run at a time, oldest
/// first (see [runStartsOf]): anything finer can separate a tool call
/// from the result answering it, which the server then refuses. The last
/// run always stays — it holds the message being answered — even when it
/// alone is over budget, since sending it is the only way to find out
/// what the server makes of it.
HistoryTrim trimHistory(List<Message> history, ContextBudget budget) {
  if (budget.isUnlimited || history.isEmpty) {
    return (history: history, droppedRuns: 0, droppedImages: 0);
  }

  final limited = budget.imageLimit > 0
      ? _limitImages(history, budget.imageLimit)
      : (history: history, dropped: 0);

  var kept = limited.history;
  var droppedRuns = 0;
  final max = budget.maxPromptTokens;

  if (max != null) {
    // Each message weighed once; dropping a run subtracts what it cost.
    final costs = [for (final message in kept) estimateMessageTokens(message)];
    var tokens = costs.fold(0, (total, cost) => total + cost);
    if (tokens > max) {
      final starts = runStartsOf(kept);
      var run = 0;
      var from = 0;
      while (tokens > max && run + 1 < starts.length) {
        final end = starts[run + 1];
        for (var i = from; i < end; i++) {
          tokens -= costs[i];
        }
        from = end;
        run++;
        droppedRuns++;
      }
      if (from > 0) kept = kept.sublist(from);
    }
  }

  return (
    history: kept,
    droppedRuns: droppedRuns,
    droppedImages: limited.dropped,
  );
}

/// [history] with every image but the newest [limit] taken off the
/// messages that carry them, walking from the end so the pictures that
/// stay are the ones the model has just been shown.
({List<Message> history, int dropped}) _limitImages(
  List<Message> history,
  int limit,
) {
  var room = limit;
  var dropped = 0;
  List<Message>? out;

  for (var i = history.length - 1; i >= 0; i--) {
    final message = history[i];
    if (!message.hasImages) continue;

    // Removals only ever happen at or after the index being read, so the
    // copy stays aligned with the original for everything still to come.
    List<ContentBlock>? content;

    for (var j = message.content.length - 1; j >= 0; j--) {
      final block = message.content[j];
      if (block is ImageContentBlock) {
        if (room > 0) {
          room--;
        } else {
          (content ??= List<ContentBlock>.of(message.content)).removeAt(j);
          dropped++;
        }
      } else if (block is ToolResultContentBlock) {
        List<ContentBlock>? inner;
        for (var k = block.resultContent.length - 1; k >= 0; k--) {
          if (block.resultContent[k] is! ImageContentBlock) continue;
          if (room > 0) {
            room--;
          } else {
            (inner ??= List<ContentBlock>.of(block.resultContent)).removeAt(k);
            dropped++;
          }
        }
        if (inner != null) {
          (content ??= List<ContentBlock>.of(message.content))[j] = block
              .copyWith(resultContent: inner);
        }
      }
    }

    if (content != null) {
      (out ??= List<Message>.of(history))[i] = message.copyWith(
        content: content,
      );
    }
  }

  return (history: out ?? history, dropped: dropped);
}
