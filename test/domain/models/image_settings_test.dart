import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/conversation_settings.dart';
import 'package:specterchat/domain/models/image_settings.dart';
import 'package:specterchat/domain/models/model_info.dart';

void main() {
  group('ImageSettings', () {
    test('round-trips through JSON with every field set', () {
      const s = ImageSettings(
        mode: ImageMode.edit,
        baseSize: 1536,
        aspectRatio: '16:9',
        steps: 12,
        seed: 42,
        guidance: 3.0,
        negativePrompt: 'blurry',
        transparent: true,
      );
      final json = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
      expect(json['mode'], 'edit');
      expect(json['aspectRatio'], '16:9');
      expect(ImageSettings.fromJson(json), s);
    });

    test('JSON with the removed keys (strength, enhance, editMode, backend) '
        'still loads', () {
      final s = ImageSettings.fromJson(
        jsonDecode(
              '{"steps": 4, "transparent": true, "strength": 0.6, '
              '"enhance": false, "editMode": "img2img", "backend": "mlx"}',
            )
            as Map<String, dynamic>,
      );
      expect(s, const ImageSettings(steps: 4, transparent: true));
    });

    test('empty object is the default and reports isDefault', () {
      expect(ImageSettings.fromJson(const {}), const ImageSettings());
      expect(const ImageSettings().isDefault, isTrue);
      expect(const ImageSettings(steps: 3).isDefault, isFalse);
    });
  });

  group('backward compatibility', () {
    test('ConversationSettings JSON without image loads with image null', () {
      final s = ConversationSettings.fromJson(
        jsonDecode(
              '{"systemPrompt": "x", "generation": {"temperature": 0.2}, '
              '"contextLength": 4096}',
            )
            as Map<String, dynamic>,
      );
      expect(s.image, isNull);
      expect(s.systemPrompt, 'x');
      expect(s.generation?.temperature, 0.2);
    });

    test('AppSettings JSON without image fields gets defaults', () {
      final s = AppSettings.fromJson(
        jsonDecode(
              '{"api": {"baseUrl": "http://x/v1"}, "generation": {}, '
              '"defaultSystemPrompt": "", "mcpServers": []}',
            )
            as Map<String, dynamic>,
      );
      expect(s.image, const ImageSettings());
    });

    test('a stale knownImageModels key in stored JSON is ignored', () {
      // Older builds persisted the server's image-model descriptions
      // inside the settings blob; it now lives in the model catalog store.
      final s = AppSettings.fromJson(
        jsonDecode(
              '{"api": {}, "generation": {}, "defaultSystemPrompt": "", '
              '"mcpServers": [], "knownImageModels": {"x": {"backend": "b"}}}',
            )
            as Map<String, dynamic>,
      );
      expect(s, const AppSettings());
    });
  });

  group('ImageSettings.normalised', () {
    const defaults = ImageDefaults();

    test('folds values equal to the server default back to null', () {
      const s = ImageSettings(
        mode: ImageMode.auto,
        baseSize: 1024,
        steps: 20,
        guidance: 1.004,
        negativePrompt: '',
        transparent: false,
      );
      expect(s.normalised(defaults), const ImageSettings());
      expect(s.normalised(defaults).isDefault, isTrue);
    });

    test('keeps real overrides', () {
      const s = ImageSettings(
        mode: ImageMode.edit,
        baseSize: 1536,
        aspectRatio: '16:9',
        steps: 30,
        seed: 7,
        guidance: 2.5,
        negativePrompt: 'blurry',
        transparent: true,
      );
      expect(s.normalised(defaults), s);
    });
  });
}
