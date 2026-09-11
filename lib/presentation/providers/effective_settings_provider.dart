import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/effective_settings.dart';
import 'conversation_provider.dart';
import 'settings_provider.dart';

final effectiveSettingsProvider = Provider<EffectiveSettings>((ref) {
  final global = ref.watch(settingsProvider);
  final conversation = ref.watch(selectedConversationProvider);
  return conversation == null
      ? EffectiveSettings.global(global)
      : EffectiveSettings.resolve(global, conversation);
});
