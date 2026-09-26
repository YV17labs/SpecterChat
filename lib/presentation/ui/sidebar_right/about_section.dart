import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_info.dart';
import '../../../core/theme.dart';
import '../../providers/link_provider.dart';

/// App identity footer: name, dynamic version, copyright, and a link to the
/// bundled open-source license list. The version is read from the running
/// bundle, so it always matches pubspec `version` with no manual updates.
class AboutSection extends ConsumerWidget {
  // Attribution names the individual copyright holder alongside the trading
  // name: YV17labs is not a registered entity in every jurisdiction, so the
  // legally operative holder is the natural person.
  static const _copyright = 'Copyright © 2026 Yoann Vanitou (YV17labs)';
  static const _licenseLine = 'Open source — MIT License';
  static const _site = 'https://www.yv17labs.com';

  const AboutSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = context.specterStyles.smallMuted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppInfo.name,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text('Version ${AppInfo.versionLabel}', style: muted),
        const SizedBox(height: 2),
        Text(_copyright, style: muted),
        const SizedBox(height: 2),
        Text(_licenseLine, style: muted),
        const SizedBox(height: 8),
        Row(
          children: [
            _LinkButton(
              label: 'Licenses',
              onPressed: () => showLicensePage(
                context: context,
                applicationName: AppInfo.name,
                applicationVersion: AppInfo.versionLabel,
                applicationLegalese: '$_copyright\n$_licenseLine',
              ),
            ),
            _LinkButton(
              label: 'yv17labs.com',
              onPressed: () =>
                  ref.read(linkFollowerProvider).follow(_site).ignore(),
            ),
          ],
        ),
      ],
    );
  }
}

class _LinkButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _LinkButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
