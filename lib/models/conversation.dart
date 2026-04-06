import 'package:freezed_annotation/freezed_annotation.dart';

import 'conversation_settings.dart';

part 'conversation.freezed.dart';
part 'conversation.g.dart';

const kDefaultConversationTitle = 'New Chat';

@freezed
abstract class Conversation with _$Conversation {
  const factory Conversation({
    required String id,
    required String title,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? systemPrompt,
    ConversationSettings? settings,
  }) = _Conversation;

  factory Conversation.fromJson(Map<String, dynamic> json) =>
      _$ConversationFromJson(json);
}
