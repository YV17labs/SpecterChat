import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'chat/chat_view.dart';
import 'sidebar_left/conversation_list.dart';
import 'sidebar_right/settings_panel.dart';

/// Three-panel desktop layout: conversations | chat | settings.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _leftSidebarCollapsed = false;
  bool _rightSidebarCollapsed = false;

  static const double _leftSidebarWidth = 260;
  static const double _rightSidebarWidth = 320;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          _CollapsibleSidebar(
            collapsed: _leftSidebarCollapsed,
            width: _leftSidebarWidth,
            border: Border(right: context.specterStyles.sidebarBorderSide),
            child: const ConversationList(),
          ),
          _SidebarToggle(
            icon: _leftSidebarCollapsed
                ? Icons.chevron_right
                : Icons.chevron_left,
            onPressed: () =>
                setState(() => _leftSidebarCollapsed = !_leftSidebarCollapsed),
          ),
          const Expanded(child: ChatView()),
          _SidebarToggle(
            icon: _rightSidebarCollapsed
                ? Icons.chevron_left
                : Icons.chevron_right,
            onPressed: () => setState(
              () => _rightSidebarCollapsed = !_rightSidebarCollapsed,
            ),
          ),
          _CollapsibleSidebar(
            collapsed: _rightSidebarCollapsed,
            width: _rightSidebarWidth,
            border: Border(left: context.specterStyles.sidebarBorderSide),
            child: const SettingsPanel(),
          ),
        ],
      ),
    );
  }
}

class _CollapsibleSidebar extends StatelessWidget {
  final bool collapsed;
  final double width;
  final Border border;
  final Widget child;

  const _CollapsibleSidebar({
    required this.collapsed,
    required this.width,
    required this.border,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: collapsed ? 0 : width,
      curve: Curves.easeInOut,
      child: collapsed
          ? const SizedBox.shrink()
          : Container(
              decoration: BoxDecoration(border: border),
              child: child,
            ),
    );
  }
}

class _SidebarToggle extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _SidebarToggle({required this.icon, required this.onPressed});

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
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.3),
            ),
          ),
        ),
      ),
    );
  }
}
