import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../domain/models/app_settings.dart';
import '../widgets/settings_fields.dart';

/// The "Photo Metadata" block of the settings panel: what "Save as…"
/// writes into an image made from a photo. Global, like the connection —
/// never a per-conversation override.
class PhotoMetadataSection extends StatelessWidget {
  final PhotoMetadataExport value;
  final ValueChanged<PhotoMetadataExport> onChanged;

  const PhotoMetadataSection({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Photo Metadata'),
        const SizedBox(height: 4),
        SwitchRow(
          label: 'Keep the original metadata',
          value: value.keepOriginal,
          onChanged: (on) => onChanged(value.copyWith(keepOriginal: on)),
        ),
        Text(
          'Saving an image made from a photo gives it everything the '
          'photo’s file carried: camera, date, place, and any other '
          'metadata.',
          style: context.specterStyles.caption,
        ),
        const SizedBox(height: 8),
        SwitchRow(
          label: 'Mark generated images as AI',
          value: value.markGeneratedAsAi,
          onChanged: (on) => onChanged(value.copyWith(markGeneratedAsAi: on)),
        ),
        Text(
          'The IPTC tag photo apps read to flag AI images.',
          style: context.specterStyles.caption,
        ),
      ],
    );
  }
}
