import '../models/app_settings.dart';
import '../database/i_conversation_repository.dart';
import '../services/i_llm_service.dart';
import '../services/i_mcp_service.dart';

/// Immutable snapshot of everything a [ChatSession] needs to stream one
/// response. Resolved fresh at each `sendMessage` by the session manager
/// so that in-flight sessions are unaffected by settings changes that
/// happen after they started — a new send picks up the new values,
/// current sends keep the snapshot they were given.
class ChatSessionDeps {
  final ILlmService llm;
  final IMcpService mcpService;
  final IConversationRepository repo;
  final List<Map<String, dynamic>> mcpTools;
  final List<McpServerConfig> mcpServers;
  final AppSettings settings;
  final String effectiveSystemPrompt;
  final String mcpInstructions;

  const ChatSessionDeps({
    required this.llm,
    required this.mcpService,
    required this.repo,
    required this.mcpTools,
    required this.mcpServers,
    required this.settings,
    required this.effectiveSystemPrompt,
    required this.mcpInstructions,
  });

  /// System prompt merged with MCP instructions. Empty string when neither
  /// is set.
  String get mergedSystemPrompt {
    if (mcpInstructions.isEmpty) return effectiveSystemPrompt;
    if (effectiveSystemPrompt.isEmpty) return mcpInstructions;
    return '$effectiveSystemPrompt\n\n$mcpInstructions';
  }
}

/// Resolves a fresh [ChatSessionDeps] snapshot at the moment a message
/// is sent. Injected into [ChatSessionManager] so the manager stays free
/// of Riverpod concerns while still seeing up-to-date settings.
typedef ChatSessionDepsResolver = ChatSessionDeps Function();
