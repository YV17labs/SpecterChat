import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/llm_provider.dart';
import '../../providers/settings_provider.dart';
import '../widgets/settings_fields.dart';

class ModelSelector extends ConsumerWidget {
  const ModelSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final modelsAsync = ref.watch(availableModelsProvider);

    return LabeledField(
      label: 'Model',
      child: Row(
        children: [
          Expanded(
            child: modelsAsync.when(
              data: (models) {
                if (models.isEmpty) {
                  return const Text('No models available');
                }
                return DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: models.contains(settings.api.selectedModel)
                      ? settings.api.selectedModel
                      : null,
                  decoration: settingsInputDecoration(context, ''),
                  items: models
                      .map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(
                              m,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ))
                      .toList(),
                  onChanged: (model) {
                    if (model != null) {
                      ref.read(settingsProvider.notifier).updateApi(
                            settings.api
                                .copyWith(selectedModel: model),
                          );
                    }
                  },
                );
              },
              loading: () => const SizedBox(
                height: 36,
                child: Center(
                  child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ),
              error: (e, _) => Text(
                'Failed to load models',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Refresh models',
            onPressed: () =>
                ref.invalidate(availableModelsProvider),
          ),
        ],
      ),
    );
  }
}
