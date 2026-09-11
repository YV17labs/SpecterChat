import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/repositories/i_attachment_repository.dart';
import '../../domain/repositories/i_conversation_repository.dart';
import '../../domain/repositories/i_message_repository.dart';
import '../../infrastructure/persistence/attachment_repository.dart';
import '../../infrastructure/persistence/conversation_repository.dart';
import '../../infrastructure/persistence/database.dart';
import '../../infrastructure/persistence/message_repository.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final conversationRepositoryProvider = Provider<IConversationRepository>(
  (ref) => ConversationRepository(ref.watch(databaseProvider)),
);

final messageRepositoryProvider = Provider<IMessageRepository>(
  (ref) => MessageRepository(ref.watch(databaseProvider)),
);

final attachmentRepositoryProvider = Provider<IAttachmentRepository>(
  (ref) => AttachmentRepository(ref.watch(databaseProvider)),
);
