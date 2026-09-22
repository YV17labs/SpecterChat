import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../domain/models/conversation.dart';
import '../../providers/conversation_provider.dart';
import '../widgets/snack.dart';
import 'conversation_tile.dart';

class ConversationList extends ConsumerStatefulWidget {
  const ConversationList({super.key});

  @override
  ConsumerState<ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends ConsumerState<ConversationList> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  ConversationController get _controller =>
      ref.read(conversationControllerProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final conversationsAsync = ref.watch(conversationListProvider);
    final selectedId = ref.watch(conversationControllerProvider);
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Text(
                'Chats',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add, size: 20),
                tooltip: 'New Chat',
                onPressed: () => _controller.createNew().ignore(),
                style: IconButton.styleFrom(
                  backgroundColor: cs.primaryContainer,
                  foregroundColor: cs.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search conversations...',
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: cs.surfaceContainerHighest,
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
            onChanged: (value) => setState(() => _searchQuery = value),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: conversationsAsync.when(
            data: (conversations) {
              final filtered = _filter(conversations);
              if (filtered.isEmpty) {
                return _EmptyList(
                  message: _searchQuery.isEmpty
                      ? 'No conversations yet'
                      : 'No results found',
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final conv = filtered[index];
                  return ConversationTile(
                    conversation: conv,
                    isSelected: conv.id == selectedId,
                    onTap: () => _controller.select(conv.id),
                    onMenuAction: (action) => _onMenuAction(action, conv),
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
          ),
        ),
      ],
    );
  }

  List<Conversation> _filter(List<Conversation> conversations) {
    if (_searchQuery.isEmpty) return conversations;
    final needle = _searchQuery.toLowerCase();
    return conversations
        .where((c) => c.title.toLowerCase().contains(needle))
        .toList();
  }

  Future<void> _onMenuAction(
    ConversationMenuAction action,
    Conversation conv,
  ) async {
    switch (action) {
      case ConversationMenuAction.duplicate:
        await _controller.fork(conv.id);
      case ConversationMenuAction.rename:
        final title = await _promptForTitle(conv.title);
        if (title != null && title.isNotEmpty) {
          await _controller.rename(conv.id, title);
        }
      case ConversationMenuAction.export:
        await _export(conv);
      case ConversationMenuAction.delete:
        if (await _confirmDelete(conv.title)) {
          await _controller.delete(conv.id);
        }
    }
  }

  Future<void> _export(Conversation conv) async {
    String? message;
    try {
      if (await _controller.export(conv.id)) message = 'Conversation exported';
    } on Exception catch (e) {
      message = 'Export failed: $e';
    }
    if (message == null || !mounted) return;
    showSnack(context, message);
  }

  Future<String?> _promptForTitle(String current) {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Conversation'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter new title'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<bool> _confirmDelete(String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Conversation'),
        content: Text('Are you sure you want to delete "$title"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

class _EmptyList extends StatelessWidget {
  final String message;

  const _EmptyList({required this.message});

  @override
  Widget build(BuildContext context) {
    final styles = context.specterStyles;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 48,
              color: styles.textFaint.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(message, style: TextStyle(color: styles.textSubtle)),
          ],
        ),
      ),
    );
  }
}
