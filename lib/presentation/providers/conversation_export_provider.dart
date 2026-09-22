import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/conversations/conversation_export.dart';
import '../../core/app_info.dart';
import '../../domain/services/i_file_saver.dart';
import '../../infrastructure/files/desktop_file_saver.dart';
import 'database_provider.dart';

/// "Save as…" for files that are not images. Override in tests to script
/// where the user saves.
final fileSaverProvider = Provider<IFileSaver>((_) => const DesktopFileSaver());

/// A conversation's JSON export, written where the user says.
final conversationExporterProvider = Provider<ConversationExporter>(
  (ref) => ConversationExporter(
    conversations: ref.watch(conversationRepositoryProvider),
    messages: ref.watch(messageRepositoryProvider),
    attachments: ref.watch(attachmentRepositoryProvider),
    files: ref.watch(fileSaverProvider),
    app: {
      'name': AppInfo.name,
      'version': AppInfo.versionLabel,
      'userAgent': AppInfo.userAgent,
    },
  ),
);
