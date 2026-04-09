import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_lifecycle_provider.dart';
import 'sidebar_left/conversation_list.dart';
import 'chat/chat_view.dart';
import 'sidebar_right/settings_panel.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _leftSidebarCollapsed = false;
  bool _rightSidebarCollapsed = false;
  late final AppLifecycleNotifier _lifecycle;

  static const double _leftSidebarWidth = 260;
  static const double _rightSidebarWidth = 320;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleNotifier(ref);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lifecycle.initialize();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // Left sidebar
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: _leftSidebarCollapsed ? 0 : _leftSidebarWidth,
            curve: Curves.easeInOut,
            child: _leftSidebarCollapsed
                ? const SizedBox.shrink()
                : Container(
                    decoration: BoxDecoration(
                      border: Border(
                        right: BorderSide(
                          color: Theme.of(context)
                              .colorScheme
                              .outlineVariant
                              .withValues(alpha: 0.3),
                        ),
                      ),
                    ),
                    child: const ConversationList(),
                  ),
          ),

          // Left sidebar toggle
          _SidebarToggle(
            isCollapsed: _leftSidebarCollapsed,
            icon: _leftSidebarCollapsed
                ? Icons.chevron_right
                : Icons.chevron_left,
            onPressed: () => setState(
                () => _leftSidebarCollapsed = !_leftSidebarCollapsed),
          ),

          // Center chat area
          const Expanded(child: ChatView()),

          // Right sidebar toggle
          _SidebarToggle(
            isCollapsed: _rightSidebarCollapsed,
            icon: _rightSidebarCollapsed
                ? Icons.chevron_left
                : Icons.chevron_right,
            onPressed: () => setState(() =>
                _rightSidebarCollapsed = !_rightSidebarCollapsed),
          ),

          // Right sidebar
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: _rightSidebarCollapsed ? 0 : _rightSidebarWidth,
            curve: Curves.easeInOut,
            child: _rightSidebarCollapsed
                ? const SizedBox.shrink()
                : Container(
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: Theme.of(context)
                              .colorScheme
                              .outlineVariant
                              .withValues(alpha: 0.3),
                        ),
                      ),
                    ),
                    child: const SettingsPanel(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SidebarToggle extends StatelessWidget {
  final bool isCollapsed;
  final IconData icon;
  final VoidCallback onPressed;

  const _SidebarToggle({
    required this.isCollapsed,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 16,
          color: Colors.transparent,
          child: Center(
            child: Icon(
              icon,
              size: 14,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.3),
            ),
          ),
        ),
      ),
    );
  }
}
