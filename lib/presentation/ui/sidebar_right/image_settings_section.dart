import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../domain/models/image_settings.dart';
import '../../../domain/models/model_info.dart';
import '../widgets/settings_fields.dart';

/// The "Image" block of the settings panel, shown instead of the text-LLM
/// sections when the selected model is an image generator.
///
/// [value] holds only what the user overrode (`null` = server default);
/// the controls display the server's defaults from [info] for those. Every
/// change goes through [onChanged] with the full updated [ImageSettings].
class ImageSettingsSection extends StatefulWidget {
  final ImageModelInfo info;
  final ImageSettings value;
  final ValueChanged<ImageSettings> onChanged;

  const ImageSettingsSection({
    super.key,
    required this.info,
    required this.value,
    required this.onChanged,
  });

  @override
  State<ImageSettingsSection> createState() => _ImageSettingsSectionState();
}

class _ImageSettingsSectionState extends State<ImageSettingsSection> {
  late final TextEditingController _seedController;
  late final TextEditingController _negativeController;

  @override
  void initState() {
    super.initState();
    _seedController = TextEditingController(text: _seedText(widget.value));
    _negativeController = TextEditingController(
      text: widget.value.negativePrompt ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant ImageSettingsSection old) {
    super.didUpdateWidget(old);
    // Text controllers are not reactive: refill them when the value comes
    // from elsewhere (conversation switch, reset) but never while the
    // text already represents it — that would fight the user's typing.
    if (int.tryParse(_seedController.text.trim()) != widget.value.seed) {
      _seedController.text = _seedText(widget.value);
    }
    final negative = widget.value.negativePrompt ?? '';
    if (_negativeController.text != negative) {
      _negativeController.text = negative;
    }
  }

  @override
  void dispose() {
    _seedController.dispose();
    _negativeController.dispose();
    super.dispose();
  }

  static String _seedText(ImageSettings s) => s.seed?.toString() ?? '';

  /// Controls write plain values; a value that merely restates the
  /// server default is folded back to `null` here, in one place.
  void _update(ImageSettings Function(ImageSettings) change) {
    widget.onChanged(change(widget.value).normalised(widget.info.defaults));
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final caps = info.capabilities;
    final defaults = info.defaults;
    final v = widget.value;
    final styles = context.specterStyles;
    final canEdit = caps.referenceEdit;

    final sizes = defaults.baseSizes.where((s) => s <= caps.maxSide).toList();
    final baseSize = v.baseSize ?? defaults.baseSize;
    final sizeItems = {
      ...sizes,
      if (!sizes.contains(baseSize)) baseSize,
    }.toList()..sort();
    final ratios = defaults.aspectRatios;
    final ratio = ratios.contains(v.aspectRatio) ? v.aspectRatio : null;
    final maxSteps = max(defaults.maxSteps, 1);
    final steps = (v.steps ?? defaults.steps).clamp(1, maxSteps);
    final guidance = (v.guidance ?? defaults.guidance).clamp(1.0, 10.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Image',
          trailing: TextButton(
            onPressed: v.isDefault
                ? null
                : () => widget.onChanged(const ImageSettings()),
            child: const Text('Reset', style: TextStyle(fontSize: 12)),
          ),
        ),
        const SizedBox(height: 12),

        LabeledField(
          label: 'Mode',
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<ImageMode>(
              segments: [
                const ButtonSegment(value: ImageMode.auto, label: Text('Auto')),
                const ButtonSegment(
                  value: ImageMode.generate,
                  label: Text('Generate'),
                ),
                ButtonSegment(
                  value: ImageMode.edit,
                  label: const Text('Edit'),
                  enabled: canEdit,
                  tooltip: canEdit ? null : 'Not available on this backend',
                ),
                const ButtonSegment(value: ImageMode.chat, label: Text('Chat')),
              ],
              selected: {v.mode ?? ImageMode.auto},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 4),
                ),
              ),
              onSelectionChanged: (set) =>
                  _update((s) => s.copyWith(mode: set.first)),
            ),
          ),
        ),
        const SizedBox(height: 8),

        LabeledField(
          label: 'Aspect ratio',
          child: DropdownButtonFormField<String?>(
            isExpanded: true,
            initialValue: ratio,
            decoration: settingsInputDecoration(context, ''),
            style: const TextStyle(fontSize: 13),
            items: [
              const DropdownMenuItem<String?>(
                child: Text('Auto', style: TextStyle(fontSize: 13)),
              ),
              for (final r in ratios)
                DropdownMenuItem<String?>(
                  value: r,
                  child: Text(r, style: const TextStyle(fontSize: 13)),
                ),
            ],
            onChanged: (r) => _update((s) => s.copyWith(aspectRatio: r)),
          ),
        ),
        const SizedBox(height: 8),

        LabeledField(
          label: 'Size',
          child: DropdownButtonFormField<int>(
            isExpanded: true,
            initialValue: baseSize,
            decoration: settingsInputDecoration(context, ''),
            style: const TextStyle(fontSize: 13),
            items: [
              for (final size in sizeItems)
                DropdownMenuItem<int>(
                  value: size,
                  child: Text(
                    _sizeLabel(size, isDefault: size == defaults.baseSize),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
            onChanged: (size) => _update((s) => s.copyWith(baseSize: size)),
          ),
        ),
        const SizedBox(height: 8),

        SliderField(
          label: 'Steps',
          value: steps.toDouble(),
          min: 1,
          max: maxSteps.toDouble(),
          divisions: max(maxSteps - 1, 1),
          fractionDigits: 0,
          onChanged: (n) => _update((s) => s.copyWith(steps: n.round())),
        ),

        LabeledField(
          label: 'Seed',
          child: TextField(
            controller: _seedController,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 13),
            decoration: settingsInputDecoration(context, 'random').copyWith(
              suffixIcon: IconButton(
                icon: const Icon(Icons.casino_outlined, size: 18),
                tooltip: 'Pick a random seed',
                onPressed: () {
                  final seed = Random().nextInt(1 << 31);
                  _seedController.text = seed.toString();
                  _update((s) => s.copyWith(seed: seed));
                },
              ),
            ),
            onChanged: (text) {
              final trimmed = text.trim();
              if (trimmed.isEmpty) {
                _update((s) => s.copyWith(seed: null));
                return;
              }
              final parsed = int.tryParse(trimmed);
              if (parsed != null && parsed >= 0) {
                _update((s) => s.copyWith(seed: parsed));
              }
            },
          ),
        ),
        const SizedBox(height: 8),

        SliderField(
          label: 'Guidance',
          value: guidance,
          min: 1,
          max: 10,
          divisions: 18,
          fractionDigits: 1,
          onChanged: (g) => _update((s) => s.copyWith(guidance: g)),
        ),
        LabeledField(
          label: 'Negative prompt',
          child: TextField(
            controller: _negativeController,
            style: const TextStyle(fontSize: 13),
            decoration: settingsInputDecoration(context, 'blurry, low quality'),
            maxLines: 2,
            minLines: 1,
            onChanged: (text) =>
                _update((s) => s.copyWith(negativePrompt: text)),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Guidance above 1 needs a negative prompt and doubles the time per '
          'step.',
          style: styles.caption,
        ),
        const SizedBox(height: 12),

        _SwitchRow(
          label: 'Transparent background',
          value: caps.rgba && (v.transparent ?? false),
          enabled: caps.rgba,
          disabledTooltip: 'Not available on this backend',
          onChanged: (on) => _update((s) => s.copyWith(transparent: on)),
        ),
      ],
    );
  }

  static String _sizeLabel(int size, {required bool isDefault}) {
    final mp = (size * size) / 1e6;
    final base = '$size px (≈${mp.toStringAsFixed(1)} MP)';
    return isDefault ? '$base · default' : base;
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final bool enabled;
  final String disabledTooltip;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.disabledTooltip,
  });

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: enabled
                ? context.specterStyles.smallMuted
                : context.specterStyles.smallMuted.copyWith(
                    color: context.specterStyles.textFaint,
                  ),
          ),
        ),
        Switch(
          value: value,
          onChanged: enabled ? onChanged : null,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
    return enabled ? row : Tooltip(message: disabledTooltip, child: row);
  }
}
