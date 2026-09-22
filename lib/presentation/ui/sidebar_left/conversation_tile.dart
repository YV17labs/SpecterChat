import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../domain/models/conversation.dart';

enum ConversationMenuAction { duplicate, rename, export, delete }

/// One row in the conversation list with its overflow menu.
class ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final bool isSelected;
  final VoidCallback onTap;
  final ValueChanged<ConversationMenuAction> onMenuAction;

  const ConversationTile({
    super.key,
    required this.conversation,
    required this.isSelected,
    required this.onTap,
    required this.onMenuAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: isSelected ? cs.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    conversation.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: PopupMenuButton<ConversationMenuAction>(
                    icon: Icon(
                      Icons.more_horiz,
                      size: 16,
                      color: context.specterStyles.textSubtle,
                    ),
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    onSelected: onMenuAction,
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: ConversationMenuAction.duplicate,
                        child: _MenuRow(
                          icon: Icons.add_circle_outline,
                          label: 'New from this',
                        ),
                      ),
                      PopupMenuItem(
                        value: ConversationMenuAction.rename,
                        child: _MenuRow(icon: Icons.edit, label: 'Rename'),
                      ),
                      PopupMenuItem(
                        value: ConversationMenuAction.export,
                        child: _MenuRow(
                          icon: Icons.file_download_outlined,
                          label: 'Export (JSON)',
                        ),
                      ),
                      PopupMenuItem(
                        value: ConversationMenuAction.delete,
                        child: _MenuRow(icon: Icons.delete, label: 'Delete'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [Icon(icon, size: 16), const SizedBox(width: 8), Text(label)],
    );
  }
}
