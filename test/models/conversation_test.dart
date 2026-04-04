import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/models/conversation.dart';

void main() {
  group('Conversation', () {
    test('creates with all required fields', () {
      final now = DateTime.now();
      final conv = Conversation(
        id: 'conv-1',
        title: 'Test Chat',
        createdAt: now,
        updatedAt: now,
      );
      expect(conv.id, 'conv-1');
      expect(conv.title, 'Test Chat');
      expect(conv.systemPrompt, isNull);
    });

    test('supports optional systemPrompt', () {
      final now = DateTime.now();
      final conv = Conversation(
        id: 'conv-1',
        title: 'Test',
        createdAt: now,
        updatedAt: now,
        systemPrompt: 'You are helpful',
      );
      expect(conv.systemPrompt, 'You are helpful');
    });

    test('roundtrips through JSON', () {
      final now = DateTime.now();
      final conv = Conversation(
        id: 'conv-1',
        title: 'Test',
        createdAt: now,
        updatedAt: now,
        systemPrompt: 'Be concise',
      );
      final json = conv.toJson();
      final restored = Conversation.fromJson(json);
      expect(restored.id, conv.id);
      expect(restored.title, conv.title);
      expect(restored.systemPrompt, conv.systemPrompt);
    });

    test('copyWith works', () {
      final now = DateTime.now();
      final conv = Conversation(
        id: 'conv-1',
        title: 'Old Title',
        createdAt: now,
        updatedAt: now,
      );
      final renamed = conv.copyWith(title: 'New Title');
      expect(renamed.title, 'New Title');
      expect(renamed.id, 'conv-1');
    });

    test('equality works', () {
      final now = DateTime(2024, 1, 1);
      final a = Conversation(
        id: 'conv-1',
        title: 'Test',
        createdAt: now,
        updatedAt: now,
      );
      final b = Conversation(
        id: 'conv-1',
        title: 'Test',
        createdAt: now,
        updatedAt: now,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
