import 'package:flutter/material.dart';

import '../../../core/theme.dart';

/// Section header with optional trailing widget.
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const SectionHeader({super.key, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
            letterSpacing: 0.5,
          ),
        ),
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    );
  }
}

/// Small uppercase tracked label for a section inside a card or block.
class SectionLabel extends StatelessWidget {
  final String label;
  final EdgeInsetsGeometry padding;

  const SectionLabel(this.label, {super.key, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        label.toUpperCase(),
        style: context.specterStyles.sectionLabel,
      ),
    );
  }
}

/// A label above a child widget.
class LabeledField extends StatelessWidget {
  final String label;
  final Widget child;

  const LabeledField({super.key, required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: context.specterStyles.smallMuted),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

/// A slider with label and current value display.
class SliderField extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  /// Decimals shown next to the label (0 for integer-valued sliders).
  final int fractionDigits;

  const SliderField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.fractionDigits = 2,
  });

  @override
  Widget build(BuildContext context) {
    final styles = context.specterStyles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: styles.smallMuted,
              ),
            ),
            Text(
              value.toStringAsFixed(fractionDigits),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: const SliderThemeData(
            trackHeight: 3,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// A label with a switch at the end of the row. When [enabled] is false the
/// switch is inert, the label faint, and [disabledTooltip] says why.
class SwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final bool enabled;
  final String? disabledTooltip;
  final ValueChanged<bool> onChanged;

  const SwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.disabledTooltip,
  });

  @override
  Widget build(BuildContext context) {
    final styles = context.specterStyles;
    final row = Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: enabled
                ? styles.smallMuted
                : styles.smallMuted.copyWith(color: styles.textFaint),
          ),
        ),
        Switch(
          value: value,
          onChanged: enabled ? onChanged : null,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
    final tooltip = disabledTooltip;
    return enabled || tooltip == null
        ? row
        : Tooltip(message: tooltip, child: row);
  }
}

/// Standard input decoration used across the settings panel.
InputDecoration settingsInputDecoration(BuildContext context, String hint) {
  return InputDecoration(
    hintText: hint,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(
        color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
      ),
    ),
    filled: true,
    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
  );
}
