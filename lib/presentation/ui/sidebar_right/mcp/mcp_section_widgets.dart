import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../../../core/theme.dart';
import '../../../providers/chat_input_provider.dart';
import '../../widgets/snack.dart';

final _log = Logger('McpSidebar');

/// First non-empty string in [candidates], or the empty string. Used to
/// resolve a display name: prefer `title`, then an annotation title, then
/// `name`.
String firstNonEmpty(List<String?> candidates) {
  for (final c in candidates) {
    if (c != null && c.isNotEmpty) return c;
  }
  return '';
}

class McpEmptyHint extends StatelessWidget {
  final String text;

  const McpEmptyHint({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(text, style: context.specterStyles.small),
    );
  }
}

/// Small coloured pill used for tool annotation hints.
class McpBadge extends StatelessWidget {
  final String text;
  final Color color;
  final String? tooltip;

  const McpBadge({
    super.key,
    required this.text,
    required this.color,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    final tip = tooltip;
    return tip == null ? pill : Tooltip(message: tip, child: pill);
  }
}

/// Shared tail of "insert this MCP thing into the chat": load text through
/// [load], report empty or failed loads with a snackbar, otherwise hand the
/// text to the chat input.
Future<void> injectMcpTextIntoChat(
  BuildContext context,
  WidgetRef ref, {
  required Future<String> Function() load,
  required String emptyMessage,
  required String failureLabel,
}) async {
  try {
    final text = await load();
    if (!context.mounted) return;
    if (text.trim().isEmpty) {
      showSnack(context, emptyMessage);
      return;
    }
    ref.read(chatInputInjectionProvider.notifier).inject(text);
  } catch (e, st) {
    _log.warning('$failureLabel failed', e, st);
    if (!context.mounted) return;
    showSnack(context, '$failureLabel: $e');
  }
}
