import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/models/app_settings.dart';

void main() {
  group('ApiSettings', () {
    test('has sensible defaults', () {
      const settings = ApiSettings();
      expect(settings.baseUrl, 'http://localhost:1234/v1');
      expect(settings.apiKey, '');
      expect(settings.selectedModel, '');
    });

    test('roundtrips through JSON', () {
      const settings = ApiSettings(
        baseUrl: 'http://example.com/v1',
        apiKey: 'sk-test',
        selectedModel: 'gpt-4',
      );
      final json = settings.toJson();
      final restored = ApiSettings.fromJson(json);
      expect(restored, settings);
    });

    test('copyWith works', () {
      const settings = ApiSettings();
      final updated = settings.copyWith(apiKey: 'sk-new');
      expect(updated.apiKey, 'sk-new');
      expect(updated.baseUrl, settings.baseUrl);
    });
  });

  group('GenerationSettings', () {
    test('has sensible defaults', () {
      const settings = GenerationSettings();
      expect(settings.temperature, 0.7);
      expect(settings.topP, 1.0);
      expect(settings.topK, 0);
      expect(settings.maxTokens, 4096);
      expect(settings.repeatPenalty, 1.0);
      expect(settings.frequencyPenalty, 0.0);
      expect(settings.presencePenalty, 0.0);
    });

    test('roundtrips through JSON', () {
      const settings = GenerationSettings(
        temperature: 0.5,
        maxTokens: 2048,
      );
      final json = settings.toJson();
      final restored = GenerationSettings.fromJson(json);
      expect(restored, settings);
    });
  });

  group('McpServerConfig', () {
    test('has correct defaults', () {
      const config = McpServerConfig(
        id: 'srv-1',
        name: 'Test',
        url: 'http://localhost:3000',
      );
      expect(config.enabled, true);
      expect(config.connected, false);
      expect(config.tools, isEmpty);
    });

    test('roundtrips through JSON', () {
      const config = McpServerConfig(
        id: 'srv-1',
        name: 'Test',
        url: 'http://localhost:3000',
        enabled: true,
        connected: true,
        tools: [
          McpToolInfo(
            name: 'search',
            description: 'Search the web',
            inputSchema: {'type': 'object'},
          ),
        ],
      );
      final json = jsonDecode(jsonEncode(config.toJson()))
          as Map<String, dynamic>;
      final restored = McpServerConfig.fromJson(json);
      expect(restored.id, config.id);
      expect(restored.tools.length, 1);
      expect(restored.tools.first.name, 'search');
    });
  });

  group('McpToolInfo', () {
    test('enabled defaults to true', () {
      const tool = McpToolInfo(
        name: 'test',
        description: 'desc',
        inputSchema: {},
      );
      expect(tool.enabled, true);
    });

    test('roundtrips through JSON', () {
      const tool = McpToolInfo(
        name: 'search',
        description: 'Search tool',
        inputSchema: {
          'type': 'object',
          'properties': {
            'q': {'type': 'string'},
          },
        },
        enabled: false,
      );
      final json = tool.toJson();
      final restored = McpToolInfo.fromJson(json);
      expect(restored, tool);
    });
  });

  group('AppSettings', () {
    test('has sensible defaults', () {
      const settings = AppSettings();
      expect(settings.api, const ApiSettings());
      expect(settings.generation, const GenerationSettings());
      expect(settings.defaultSystemPrompt, '');
      expect(settings.mcpServers, isEmpty);
    });

    test('roundtrips through JSON', () {
      const settings = AppSettings(
        api: ApiSettings(apiKey: 'sk-test'),
        defaultSystemPrompt: 'You are helpful',
        mcpServers: [
          McpServerConfig(
            id: 'srv-1',
            name: 'Test',
            url: 'http://localhost:3000',
          ),
        ],
      );
      final json = jsonDecode(jsonEncode(settings.toJson()))
          as Map<String, dynamic>;
      final restored = AppSettings.fromJson(json);
      expect(restored.api.apiKey, 'sk-test');
      expect(restored.defaultSystemPrompt, 'You are helpful');
      expect(restored.mcpServers.length, 1);
    });

    test('copyWith preserves unmodified fields', () {
      const settings = AppSettings(
        api: ApiSettings(apiKey: 'sk-1'),
        defaultSystemPrompt: 'prompt',
      );
      final updated = settings.copyWith(
        defaultSystemPrompt: 'new prompt',
      );
      expect(updated.api.apiKey, 'sk-1');
      expect(updated.defaultSystemPrompt, 'new prompt');
    });
  });
}
