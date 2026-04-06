import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/conversation.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/settings_provider.dart';

class ConversationList extends ConsumerStatefulWidget {
  const ConversationList({super.key});

  @override
  ConsumerState<ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends ConsumerState<ConversationList> {
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conversationsAsync = ref.watch(conversationListProvider);
    final selectedId = ref.watch(selectedConversationIdProvider);

    return Column(
      children: [
        // Header with new chat button
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Text(
                'Chats',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add, size: 20),
                tooltip: 'New Chat',
                onPressed: () => _createNewChat(),
                style: IconButton.styleFrom(
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  foregroundColor:
                      Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),

        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search conversations...',
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest,
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
            ),
            onChanged: (value) =>
                setState(() => _searchQuery = value),
          ),
        ),

        const SizedBox(height: 8),

        // Conversation list
        Expanded(
          child: conversationsAsync.when(
            data: (conversations) {
              final filtered = _searchQuery.isEmpty
                  ? conversations
                  : conversations
                      .where((c) => c.title
                          .toLowerCase()
                          .contains(_searchQuery.toLowerCase()))
                      .toList();

              if (filtered.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 48,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.3),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _searchQuery.isEmpty
                              ? 'No conversations yet'
                              : 'No results found',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final conv = filtered[index];
                  final isSelected = conv.id == selectedId;

                  return _ConversationTile(
                    conversation: conv,
                    isSelected: isSelected,
                    onTap: () => ref
                        .read(selectedConversationIdProvider
                            .notifier)
                        .select(conv.id),
                    onDuplicate: () => _duplicateConversation(conv),
                    onRename: () => _renameConversation(conv),
                    onDelete: () => _deleteConversation(conv),
                  );
                },
              );
            },
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
          ),
        ),
      ],
    );
  }

  Future<void> _createNewChat() async {
    final settings = ref.read(settingsProvider);
    final actions = ref.read(conversationRepositoryProvider);
    final id = await actions.createConversation(
      systemPrompt: settings.defaultSystemPrompt.isNotEmpty
          ? settings.defaultSystemPrompt
          : null,
    );
    if (!mounted) return;
    ref.read(selectedConversationIdProvider.notifier).select(id);
  }

  Future<void> _duplicateConversation(Conversation conv) async {
    final repo = ref.read(conversationRepositoryProvider);
    final id = await repo.createConversation(
      systemPrompt: conv.systemPrompt,
      settings: conv.settings,
    );
    if (!mounted) return;
    ref.read(selectedConversationIdProvider.notifier).select(id);
  }

  Future<void> _renameConversation(Conversation conv) async {
    final controller = TextEditingController(text: conv.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Conversation'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration:
              const InputDecoration(hintText: 'Enter new title'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (newTitle != null && newTitle.isNotEmpty) {
      await ref
          .read(conversationRepositoryProvider)
          .renameConversation(conv.id, newTitle);
    }
  }

  Future<void> _deleteConversation(Conversation conv) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Conversation'),
        content: Text(
            'Are you sure you want to delete "${conv.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final selectedId = ref.read(selectedConversationIdProvider);
      if (selectedId == conv.id) {
        ref.read(selectedConversationIdProvider.notifier).select(
            null);
      }
      await ref
          .read(conversationRepositoryProvider)
          .deleteConversation(conv.id);
    }
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDuplicate;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _ConversationTile({
    required this.conversation,
    required this.isSelected,
    required this.onTap,
    required this.onDuplicate,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: isSelected
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
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
                  child: PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_horiz,
                    size: 16,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.5),
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'duplicate',
                      child: Row(
                        children: [
                          Icon(Icons.add_circle_outline, size: 16),
                          SizedBox(width: 8),
                          Text('New from this'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'rename',
                      child: Row(
                        children: [
                          Icon(Icons.edit, size: 16),
                          SizedBox(width: 8),
                          Text('Rename'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, size: 16),
                          SizedBox(width: 8),
                          Text('Delete'),
                        ],
                      ),
                    ),
                  ],
                  onSelected: (value) {
                    if (value == 'duplicate') onDuplicate();
                    if (value == 'rename') onRename();
                    if (value == 'delete') onDelete();
                  },
                )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
