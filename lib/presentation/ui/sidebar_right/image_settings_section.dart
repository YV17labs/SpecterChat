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
/// the controls display the server's defaults from [info] for those, and
/// a number the server gives no default for is a field left empty rather
/// than a slider set to a guess. Every change goes through [onChanged]
/// with the full updated [ImageSettings].
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
  late final TextEditingController _negativeController;

  @override
  void initState() {
    super.initState();
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
    final negative = widget.value.negativePrompt ?? '';
    if (_negativeController.text != negative) {
      _negativeController.text = negative;
    }
  }

  @override
  void dispose() {
    _negativeController.dispose();
    super.dispose();
  }

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
    final recommended = info.recommended;
    final v = widget.value;
    final styles = context.specterStyles;
    final canEdit = caps.referenceEdit;
    final canChat = info.canChat;
    final mode = switch (v.mode ?? ImageMode.auto) {
      ImageMode.chat when !canChat => ImageMode.auto,
      final m => m,
    };

    final sizes = defaults.baseSizes.where((s) => s <= caps.maxSide).toList();
    final baseSize = v.baseSize ?? defaults.baseSize;
    final sizeItems = {
      ...sizes,
      baseSize,
      if (recommended.baseSize case final r? when r <= caps.maxSide) r,
    }.toList()..sort();
    final ratios = defaults.aspectRatios;
    final ratio = ratios.contains(v.aspectRatio) ? v.aspectRatio : null;
    final maxSteps = max(defaults.maxSteps, 1);

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
                ButtonSegment(
                  value: ImageMode.chat,
                  label: const Text('Chat'),
                  enabled: canChat,
                  tooltip: canChat ? null : 'Not available on this backend',
                ),
              ],
              selected: {mode},
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
                    _sizeLabel(
                      size,
                      isDefault: size == defaults.baseSize,
                      isRecommended: size == recommended.baseSize,
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
            onChanged: (size) => _update((s) => s.copyWith(baseSize: size)),
          ),
        ),
        const SizedBox(height: 8),

        if (caps.fixedSteps case final fixed?) ...[
          LabeledField(
            label: 'Steps',
            child: Text('$fixed, fixed by this model', style: styles.small),
          ),
          const SizedBox(height: 8),
        ] else if (defaults.steps case final serverSteps?)
          SliderField(
            label: _withRecommended('Steps', recommended.steps),
            value: (v.steps ?? serverSteps).clamp(1, maxSteps).toDouble(),
            min: 1,
            max: maxSteps.toDouble(),
            divisions: max(maxSteps - 1, 1),
            fractionDigits: 0,
            onChanged: (n) => _update((s) => s.copyWith(steps: n.round())),
          )
        else ...[
          _OptionalNumberField<int>(
            label: _withRecommended('Steps', recommended.steps),
            hint: 'server default',
            value: v.steps,
            parse: _positiveInt,
            onChanged: (n) => _update((s) => s.copyWith(steps: n)),
          ),
          const SizedBox(height: 8),
        ],

        _OptionalNumberField<int>(
          label: 'Seed',
          hint: 'random',
          value: v.seed,
          parse: (text) => switch (int.tryParse(text)) {
            final n? when n >= 0 => n,
            _ => null,
          },
          onChanged: (seed) => _update((s) => s.copyWith(seed: seed)),
          suffixIcon: IconButton(
            icon: const Icon(Icons.casino_outlined, size: 18),
            tooltip: 'Pick a random seed',
            onPressed: () =>
                _update((s) => s.copyWith(seed: Random().nextInt(1 << 31))),
          ),
        ),
        const SizedBox(height: 8),

        if (defaults.guidance case final serverGuidance?)
          SliderField(
            label: _withRecommended(
              'Guidance',
              recommended.guidance?.toStringAsFixed(1),
            ),
            value: (v.guidance ?? serverGuidance).clamp(1.0, 10.0),
            min: 1,
            max: 10,
            divisions: 18,
            fractionDigits: 1,
            onChanged: (g) => _update((s) => s.copyWith(guidance: g)),
          )
        else ...[
          _OptionalNumberField<double>(
            label: _withRecommended(
              'Guidance',
              recommended.guidance?.toStringAsFixed(1),
            ),
            hint: 'server default',
            value: v.guidance,
            parse: _guidance,
            onChanged: (g) => _update((s) => s.copyWith(guidance: g)),
          ),
          const SizedBox(height: 8),
        ],
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

        SwitchRow(
          label: 'Transparent background',
          value: caps.rgba && (v.transparent ?? false),
          enabled: caps.rgba,
          disabledTooltip: 'Not available on this backend',
          onChanged: (on) => _update((s) => s.copyWith(transparent: on)),
        ),
      ],
    );
  }

  static String _sizeLabel(
    int size, {
    required bool isDefault,
    required bool isRecommended,
  }) {
    final mp = (size * size) / 1e6;
    final base = '$size px (≈${mp.toStringAsFixed(1)} MP)';
    final tags = [if (isDefault) 'default', if (isRecommended) 'recommended'];
    return tags.isEmpty ? base : '$base · ${tags.join(', ')}';
  }

  /// A control's label with what the model's authors recommend for it.
  static String _withRecommended(String label, Object? value) =>
      value == null ? label : '$label · $value recommended';

  // What a model that publishes no range may be asked: anything that is
  // a step count or a guidance scale at all. Its own limits are the
  // server's to enforce — it refuses a value by name, and the turn shows
  // it — rather than this panel's to guess (a distilled model wants a
  // guidance of 0, which a "1 to 10" check would silently never send).

  static int? _positiveInt(String text) => switch (int.tryParse(text)) {
    final n? when n >= 1 => n,
    _ => null,
  };

  /// A decimal point or a decimal comma: the numeric keypad of half the
  /// world's keyboards types the latter.
  static double? _guidance(String text) =>
      switch (double.tryParse(text.replaceAll(',', '.'))) {
        final g? when g >= 0 && g.isFinite => g,
        _ => null,
      };
}

/// A number that may be left unset: empty, nothing is sent and [hint]
/// says what happens then ("server default", "random").
///
/// Text that does not [parse] sets nothing, and says so: the field turns
/// to its error state while it holds such text, and goes back to the
/// value actually set when it is left — so what it shows at rest is
/// always what is sent. Owns its controller, refilled when the value
/// comes from elsewhere (a conversation switch, Reset, a button in
/// [suffixIcon]) and never while the text already says it.
class _OptionalNumberField<T extends num> extends StatefulWidget {
  final String label;
  final String hint;
  final T? value;

  /// The number [text] (trimmed, not empty) stands for, `null` when it
  /// is not one this field takes.
  final T? Function(String text) parse;
  final ValueChanged<T?> onChanged;
  final Widget? suffixIcon;

  const _OptionalNumberField({
    required this.label,
    required this.hint,
    required this.value,
    required this.parse,
    required this.onChanged,
    this.suffixIcon,
    super.key,
  });

  @override
  State<_OptionalNumberField<T>> createState() =>
      _OptionalNumberFieldState<T>();
}

class _OptionalNumberFieldState<T extends num>
    extends State<_OptionalNumberField<T>> {
  late final TextEditingController _controller = TextEditingController(
    text: _valueText,
  );
  late final FocusNode _focus = FocusNode()..addListener(_onFocusChange);

  String get _valueText => widget.value?.toString() ?? '';

  /// What the text stands for: unset when empty, else what it parses to.
  ({bool valid, T? value}) get _typed {
    final text = _controller.text.trim();
    if (text.isEmpty) return (valid: true, value: null);
    final value = widget.parse(text);
    return (valid: value != null, value: value);
  }

  /// Whether the text says the value — text that does not parse says
  /// nothing, whatever the value is.
  bool get _inStep {
    final typed = _typed;
    return typed.valid && typed.value == widget.value;
  }

  void _showValue() {
    if (!_inStep) _controller.text = _valueText;
  }

  void _onFocusChange() {
    if (mounted && !_focus.hasFocus) setState(_showValue);
  }

  @override
  void didUpdateWidget(covariant _OptionalNumberField<T> old) {
    super.didUpdateWidget(old);
    // While the user types, the text leads: only a value that changed
    // under it replaces it.
    if (!_focus.hasFocus || widget.value != old.value) _showValue();
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LabeledField(
    label: widget.label,
    child: TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: TextInputType.numberWithOptions(decimal: T == double),
      style: const TextStyle(fontSize: 13),
      decoration: settingsInputDecoration(context, widget.hint).copyWith(
        suffixIcon: widget.suffixIcon,
        errorText: _typed.valid ? null : 'Not a value this takes: not sent',
      ),
      onChanged: (_) {
        final typed = _typed;
        if (typed.valid) widget.onChanged(typed.value);
        // The error state follows the text, valid or not.
        setState(() {});
      },
    ),
  );
}
