import '../../domain/models/request_profile.dart';
import '../../domain/repositories/i_attachment_repository.dart';
import '../../domain/repositories/i_conversation_repository.dart';
import '../../domain/repositories/i_message_repository.dart';
import '../../domain/services/i_llm_service.dart';
import '../../domain/services/i_mcp_service.dart';
import '../../domain/services/llm_hook.dart';
import '../llm_hooks/llm_hook_registry.dart';
import '../mcp/active_mcp_server.dart';

/// Immutable snapshot of everything a [ChatSession] needs to stream one
/// response. Resolved fresh at each `sendMessage` by the session manager
/// so that in-flight sessions are unaffected by settings changes that
/// happen after they started — a new send picks up the new values,
/// current sends keep the snapshot they were given.
class ChatSessionDeps {
  final ILlmService llm;
  final IMcpService mcpService;
  final IConversationRepository conversations;
  final IMessageRepository messages;
  final IAttachmentRepository attachments;
  final List<ActiveMcpServer> activeServers;
  final LlmHookRegistry hooks;

  /// Selected model name — only used to pick a model-specific hook.
  final String modelName;
  final String effectiveSystemPrompt;

  /// Sampling parameters (text model) or image options (image model) for
  /// this send. Part of the snapshot for the same reason as the rest.
  final RequestProfile profile;

  const ChatSessionDeps({
    required this.llm,
    required this.mcpService,
    required this.conversations,
    required this.messages,
    required this.attachments,
    required this.activeServers,
    required this.modelName,
    required this.effectiveSystemPrompt,
    this.profile = const TextRequestProfile(),
    this.hooks = const LlmHookRegistry.none(),
  });

  /// Model-specific quirks for the selected model, if any.
  LlmHook? get hook => hooks.hookFor(modelName);

  /// System prompt merged with MCP instructions. Empty string when neither
  /// is set.
  String get mergedSystemPrompt {
    final mcpInstructions = mergedInstructionsOf(activeServers);
    if (mcpInstructions.isEmpty) return effectiveSystemPrompt;
    if (effectiveSystemPrompt.isEmpty) return mcpInstructions;
    return '$effectiveSystemPrompt\n\n$mcpInstructions';
  }
}

/// Resolves a fresh [ChatSessionDeps] snapshot at the moment a message
/// is sent. Injected into `ChatSessionManager` so the manager stays free
/// of Riverpod concerns while still seeing up-to-date settings.
typedef ChatSessionDepsResolver = ChatSessionDeps Function();
