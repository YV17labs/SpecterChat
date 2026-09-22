import 'dart:async';
import 'dart:typed_data';

import 'package:specterchat/application/chat/chat_session_deps.dart';
import 'package:specterchat/application/chat/message_writes.dart';
import 'package:specterchat/application/llm_hooks/llm_hook_registry.dart';
import 'package:specterchat/application/mcp/active_mcp_server.dart';
import 'package:specterchat/core/id_gen.dart';
import 'package:specterchat/core/image_mime.dart';
import 'package:specterchat/domain/models/annotation.dart';
import 'package:specterchat/domain/models/app_settings.dart';
import 'package:specterchat/domain/models/conversation.dart';
import 'package:specterchat/domain/models/conversation_settings.dart';
import 'package:specterchat/domain/models/mcp_server_state.dart';
import 'package:specterchat/domain/models/message.dart';
import 'package:specterchat/domain/models/message_stats.dart';
import 'package:specterchat/domain/models/model_info.dart';
import 'package:specterchat/domain/models/photo_metadata.dart';
import 'package:specterchat/domain/models/request_context.dart';
import 'package:specterchat/domain/models/request_profile.dart';
import 'package:specterchat/domain/repositories/i_attachment_repository.dart';
import 'package:specterchat/domain/repositories/i_conversation_repository.dart';
import 'package:specterchat/domain/repositories/i_message_repository.dart';
import 'package:specterchat/domain/repositories/i_model_catalog_store.dart';
import 'package:specterchat/domain/repositories/i_settings_store.dart';
import 'package:specterchat/domain/services/cancellation_token.dart';
import 'package:specterchat/domain/services/i_annotation_renderer.dart';
import 'package:specterchat/domain/services/i_file_saver.dart';
import 'package:specterchat/domain/services/i_image_io.dart';
import 'package:specterchat/domain/services/i_image_normalizer.dart';
import 'package:specterchat/domain/services/i_llm_service.dart';
import 'package:specterchat/domain/services/i_mcp_service.dart';

import 'exif_fixtures.dart';

/// In-memory [IConversationRepository].
class InMemoryConversationRepository implements IConversationRepository {
  final Map<String, Conversation> rows = {};
  final _controller = StreamController<List<Conversation>>.broadcast();

  List<Conversation> get _sorted =>
      rows.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  void _emit() => _controller.add(_sorted);

  @override
  Stream<List<Conversation>> watchAllConversations() async* {
    yield _sorted;
    yield* _controller.stream;
  }

  @override
  Future<Conversation?> getConversation(String id) async => rows[id];

  @override
  Future<String> createConversation({
    String? systemPrompt,
    ConversationSettings? settings,
  }) async {
    final id = generateId();
    final now = DateTime.now();
    rows[id] = Conversation(
      id: id,
      title: kDefaultConversationTitle,
      createdAt: now,
      updatedAt: now,
      systemPrompt: systemPrompt,
      settings: settings,
    );
    _emit();
    return id;
  }

  @override
  Future<void> renameConversation(String id, String title) async {
    rows.update(id, (c) => c.copyWith(title: title));
    _emit();
  }

  @override
  Future<void> updateConversationSettings(
    String id,
    ConversationSettings? settings,
  ) async {
    rows.update(id, (c) => c.copyWith(settings: settings));
    _emit();
  }

  @override
  Future<void> updateLastPromptTokens(String id, int tokens) async {
    rows.update(id, (c) => c.copyWith(lastPromptTokens: tokens));
  }

  @override
  Future<void> deleteConversation(String id) async {
    rows.remove(id);
    requestContexts.remove(id);
    _emit();
  }

  /// Request contexts by conversation, then by id.
  final Map<String, Map<String, RequestContext>> requestContexts = {};

  @override
  Future<String> saveRequestContext(
    String conversationId,
    RequestContext context,
  ) async {
    final stored = requestContexts[conversationId] ??= {};
    for (final MapEntry(:key, :value) in stored.entries) {
      if (value == context) return key;
    }
    final id = 'ctx-${stored.length + 1}';
    stored[id] = context;
    return id;
  }

  @override
  Future<Map<String, RequestContext>> getRequestContexts(
    String conversationId,
  ) async => {...?requestContexts[conversationId]};
}

/// In-memory [IMessageRepository]. Reactive like the Drift one: every
/// write re-emits on the watch streams. Records every call for assertions.
class InMemoryMessageRepository implements IMessageRepository {
  final Map<String, Message> rows = {};
  final List<String> calls = [];
  final _changes = StreamController<void>.broadcast();

  List<Message> messagesFor(String conversationId) =>
      rows.values.where((m) => m.conversationId == conversationId).toList()
        ..sort((a, b) => a.id.compareTo(b.id));

  void _changed() => _changes.add(null);

  @override
  Stream<List<Message>> watchMessages(String conversationId, {int? limit}) {
    List<Message> window() {
      final all = messagesFor(conversationId);
      if (limit == null || limit <= 0 || all.length <= limit) return all;
      return all.sublist(all.length - limit);
    }

    Stream<List<Message>> generate() async* {
      yield window();
      await for (final _ in _changes.stream) {
        yield window();
      }
    }

    return generate();
  }

  @override
  Future<List<Message>> getMessages(String conversationId) async =>
      messagesFor(conversationId);

  @override
  Stream<int> watchMessageCount(String conversationId) =>
      watchMessages(conversationId).map((l) => l.length).distinct();

  @override
  Future<void> saveMessage(Message message) async {
    calls.add('save:${message.role.name}');
    rows[message.id] = message;
    _changed();
  }

  @override
  Future<void> upsertStreamingMessage(Message message) async {
    calls.add('upsert');
    rows[message.id] = message.copyWith(isStreaming: true);
    _changed();
  }

  @override
  Future<void> finalizeStreamingMessage(String messageId) async {
    calls.add('finalize');
    rows.update(messageId, (m) => m.copyWith(isStreaming: false));
    _changed();
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    calls.add('delete');
    rows.remove(messageId);
    _changed();
  }

  @override
  Future<T> runInTransaction<T>(Future<T> Function() action) => action();
}

/// In-memory [IAttachmentRepository]. Like the Drift one, never hands out
/// photo metadata as an image. Records which message owns each blob.
class InMemoryAttachmentRepository implements IAttachmentRepository {
  final Map<String, ImageBytes> rows = {};
  final Map<String, String> owners = {};
  int metadataLoads = 0;

  /// The photo metadata attachments, decoded.
  Map<String, PhotoMetadataBlocks> get photoMetadata => {
    for (final MapEntry(:key, :value) in rows.entries)
      if (value.mimeType == PhotoMetadataBlocks.mimeType)
        key: PhotoMetadataBlocks.decode(value.bytes)!,
  };

  ImageBytes? _image(String id) => switch (rows[id]) {
    final row? when row.mimeType != PhotoMetadataBlocks.mimeType => row,
    _ => null,
  };

  @override
  Future<String> storeBytes({
    String? attachmentId,
    required String messageId,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final id = attachmentId ?? generateId();
    rows[id] = (bytes: bytes, mimeType: mimeType);
    owners[id] = messageId;
    return id;
  }

  @override
  Future<bool> copy({
    required String sourceId,
    required String attachmentId,
    required String messageId,
  }) async {
    final source = rows[sourceId];
    if (source == null) return false;
    rows[attachmentId] = source;
    owners[attachmentId] = messageId;
    return true;
  }

  @override
  Future<Uint8List?> loadBytes(String attachmentId) async =>
      _image(attachmentId)?.bytes;

  @override
  Future<ImageBytesMap> loadMany(Iterable<String> attachmentIds) async => {
    for (final id in attachmentIds) id: ?_image(id),
  };

  @override
  Future<PhotoMetadataBlocks?> loadPhotoMetadata(String attachmentId) async {
    metadataLoads++;
    return photoMetadata[attachmentId];
  }
}

class InMemorySettingsStore implements ISettingsStore {
  AppSettings? stored;
  int saves = 0;

  InMemorySettingsStore([this.stored]);

  @override
  Future<AppSettings?> load() async => stored;

  @override
  Future<void> save(AppSettings settings) async {
    stored = settings;
    saves++;
  }
}

class InMemoryModelCatalogStore implements IModelCatalogStore {
  Map<String, ImageModelInfo> stored;
  int saves = 0;

  InMemoryModelCatalogStore([this.stored = const {}]);

  @override
  Future<Map<String, ImageModelInfo>> load() async => stored;

  @override
  Future<void> save(Map<String, ImageModelInfo> imageModels) async {
    stored = imageModels;
    saves++;
  }
}

/// Accepts anything that sniffs as an image, untouched. The real one
/// decodes on the engine, which stalls widget tests.
class PassThroughImageNormalizer implements IImageNormalizer {
  const PassThroughImageNormalizer();

  @override
  Future<ImageBytes?> normalize(Uint8List bytes) async {
    final mime = sniffImageMime(bytes);
    return mime == null ? null : (bytes: bytes, mimeType: mime);
  }
}

/// Marks its outputs instead of drawing: the annotated copy is the
/// original with `0xA5` appended, the mask is `[0xFF]`. Enough to assert
/// what went out, in which order.
class FakeAnnotationRenderer implements IAnnotationRenderer {
  final List<Annotation> rendered = [];
  Exception? failWith;

  static const int annotatedMarker = 0xA5;
  static final Uint8List maskBytes = Uint8List.fromList([0xFF]);

  @override
  Future<AnnotationRender> render(
    Uint8List original,
    Annotation annotation, {
    bool includeMask = false,
  }) async {
    if (failWith case final error?) throw error;
    rendered.add(annotation);
    return (
      annotated: Uint8List.fromList([...original, annotatedMarker]),
      mask: includeMask ? maskBytes : null,
    );
  }
}

/// Scripted dialogs and clipboard.
class FakeImageIo implements IImageIo {
  /// What the next [pickImages] returns.
  List<ImageFileSource> picked = const [];

  /// What the clipboard holds, if anything.
  Uint8List? clipboardImage;

  /// The user cancels the next save dialogs.
  bool cancelSave = false;
  int saveDialogs = 0;

  final List<ImageBytes> saved = [];
  final List<Uint8List> copied = [];

  /// Script a picked file from in-memory bytes.
  static ImageFileSource pickedFile(String name, Uint8List bytes) =>
      (name: name, read: () async => bytes);

  @override
  Future<List<ImageFileSource>> pickImages() async => picked;

  @override
  Future<bool> saveImage({
    required String mimeType,
    required Future<Uint8List> Function() contents,
  }) async {
    saveDialogs++;
    if (cancelSave) return false;
    saved.add((bytes: await contents(), mimeType: mimeType));
    return true;
  }

  @override
  Future<Uint8List?> readClipboardImage() async => clipboardImage;

  @override
  Future<void> writeClipboardImage(Uint8List bytes) async => copied.add(bytes);
}

/// What the iPhone photo of the fixtures ([fakeJpegPhoto]) shows about
/// itself.
final kPhotoSummary = PhotoSummary(
  camera: const CameraInfo(
    make: 'Apple',
    model: 'iPhone 17',
    focalLength: 5.96,
    fNumber: 1.6,
    exposureTime: 1 / 4329,
    iso: 40,
  ),
  captured: CaptureTime(
    local: DateTime(2026, 7, 5, 19, 41, 50),
    offset: '+02:00',
  ),
  location: const GeoLocation(latitude: 42.56858, longitude: 8.75145),
);

/// A JPEG carrying an iPhone's EXIF ([iphoneTiff], shown as
/// [kPhotoSummary]): well-formed for the MIME sniffer and the metadata
/// codec, no decodable pixels. Pair with [PassThroughImageNormalizer].
Uint8List fakeJpegPhoto() => jpeg(exif: iphoneTiff());

/// Photo metadata blocks, for tests that only need some.
const kPhotoBlocks = PhotoMetadataBlocks(exif: 'TU0AKg==', xmp: '<x:xmpmeta/>');

/// Stores [blocks] as the photo metadata attachment [id] of [messageId],
/// the way a sent message does.
Future<void> storePhotoMetadata(
  IAttachmentRepository attachments,
  String id, {
  String messageId = 'm',
  PhotoMetadataBlocks blocks = kPhotoBlocks,
}) => attachments.store(
  PendingAttachment.photoMetadata(attachmentId: id, blocks: blocks),
  messageId: messageId,
);

/// A minimal valid PNG header — enough for the MIME sniffer, not a
/// decodable image. Pair with [PassThroughImageNormalizer].
Uint8List fakePngBytes([int tag = 0]) =>
    Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, tag]);

/// [IFileSaver] that "saves" into [saved] without a dialog, or cancels
/// when [cancel] is set.
class FakeFileSaver implements IFileSaver {
  bool cancel = false;
  final List<({String name, Uint8List bytes})> saved = [];

  @override
  Future<bool> save({
    required String suggestedName,
    required String typeLabel,
    required String extension,
    required String mimeType,
    required Future<Uint8List> Function() contents,
  }) async {
    if (cancel) return false;
    saved.add((name: suggestedName, bytes: await contents()));
    return true;
  }
}

/// Scripted [ILlmService]: each call to [streamChatCompletion] plays the
/// next script in [scripts]. A script is a list of events, or a function
/// building the stream (to model cancellation mid-stream).
class FakeLlmService implements ILlmService {
  final List<Stream<StreamEvent> Function(CancellationToken?)> scripts;
  final List<List<Message>> receivedHistories = [];
  final List<List<McpToolInfo>> receivedTools = [];
  final List<RequestProfile> receivedProfiles = [];
  int calls = 0;

  @override
  String model = 'fake-model';

  @override
  String endpoint = 'http://fake.local/v1';

  FakeLlmService(this.scripts);

  /// Convenience: play [events] verbatim. Uses an `async*` generator like
  /// the production service — `Stream.fromIterable` has different
  /// cancellation timing under `FakeAsync` and stalls widget tests.
  FakeLlmService.events(List<List<StreamEvent>> turns)
    : scripts = [for (final events in turns) (_) => _replay(events)];

  static Stream<StreamEvent> _replay(List<StreamEvent> events) async* {
    for (final e in events) {
      yield e;
    }
  }

  /// What [fetchModels] reports; tests set an image model here to drive
  /// the settings panel into image mode.
  List<ModelInfo> models = const [ModelInfo(id: 'fake-model')];

  /// When set, [fetchModels] throws it instead.
  Exception? fetchModelsError;
  int fetchModelsCalls = 0;

  @override
  Future<List<ModelInfo>> fetchModels() async {
    fetchModelsCalls++;
    if (fetchModelsError case final e?) throw e;
    return models;
  }

  @override
  Stream<StreamEvent> streamChatCompletion({
    required List<Message> history,
    required String systemPrompt,
    RequestProfile profile = const TextRequestProfile(),
    ImageBytesMap imageBytes = const {},
    List<McpToolInfo> tools = const [],
    CancellationToken? cancellationToken,
  }) {
    receivedHistories.add(history);
    receivedTools.add(tools);
    receivedProfiles.add(profile);
    if (calls >= scripts.length) {
      throw StateError('FakeLlmService: no script for call #$calls');
    }
    return scripts[calls++](cancellationToken);
  }
}

class FakeMcpService implements IMcpService {
  final Map<String, McpToolResult Function(Map<String, dynamic> args)> handlers;
  final List<(String server, String tool, Map<String, dynamic> args)> calls =
      [];

  FakeMcpService([this.handlers = const {}]);

  @override
  Future<McpToolResult> callTool(
    String serverId,
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    calls.add((serverId, toolName, arguments));
    final handler = handlers[toolName];
    if (handler == null) throw McpException('no handler for $toolName');
    return handler(arguments);
  }

  @override
  Future<McpConnectResult> connect(McpServerConfig config) async =>
      McpConnectResult(tools: const []);

  @override
  void disconnect(String serverId) {}

  @override
  void disconnectAll() {}

  @override
  Future<McpPromptResult> getPrompt(
    String serverId,
    String name, {
    Map<String, String> arguments = const {},
  }) async => McpPromptResult(messages: const []);

  @override
  Future<McpResourceResult> readResource(String serverId, String uri) async =>
      McpResourceResult(contents: const []);
}

/// A connected server exposing [tools], for building [ChatSessionDeps].
ActiveMcpServer activeServer({
  String id = 'srv',
  List<McpToolInfo> tools = const [],
  String instructions = '',
}) => ActiveMcpServer(
  config: McpServerConfig(id: id, name: id, url: 'http://$id'),
  state: McpServerState(
    status: McpConnectionStatus.connected,
    tools: tools,
    instructions: instructions,
  ),
);

McpToolInfo tool(String name) =>
    McpToolInfo(name: name, description: name, inputSchema: const {});

/// A message fixture with sensible defaults; only what the test cares
/// about needs to be passed. Its token count and duration default to
/// those of its [stats], as the chat pipeline writes them.
Message testMessage(
  MessageRole role,
  List<ContentBlock> content, {
  String id = 'm',
  String conversationId = 'c',
  bool isStreaming = false,
  int? completionTokens,
  int? durationMs,
  MessageStats? stats,
  DateTime? createdAt,
}) => Message(
  id: id,
  conversationId: conversationId,
  role: role,
  content: content,
  createdAt: createdAt ?? DateTime(2024),
  isStreaming: isStreaming,
  completionTokens:
      completionTokens ??
      (stats is GenerationStats ? stats.completionTokens : null) ??
      0,
  durationMs: durationMs ?? stats?.durationMs ?? 0,
  stats: stats,
);

/// A measured assistant turn: 25184 prompt tokens, first token after
/// 1.7 s, answer from 9 s, 354 tokens in 15.7 s. Only what the test cares
/// about needs to be passed.
GenerationStats testGenerationStats({
  String model = 'qwen3.8:27b-mlx',
  DateTime? startedAt,
  int durationMs = 15700,
  int? firstTokenMs = 1700,
  int? firstAnswerMs = 9000,
  int? promptTokens = 25184,
  int? completionTokens = 354,
  GenerationOutcome outcome = GenerationOutcome.completed,
}) => GenerationStats(
  model: model,
  endpoint: 'http://localhost:11434/v1',
  generation: const GenerationSettings(temperature: 0.6, topK: 20),
  startedAt: startedAt ?? DateTime.utc(2026, 9, 22, 10),
  durationMs: durationMs,
  firstTokenMs: firstTokenMs,
  firstAnswerMs: firstAnswerMs,
  promptTokens: promptTokens,
  completionTokens: completionTokens,
  outcome: outcome,
  server: const {'finish_reason': 'tool_calls'},
);

ChatSessionDeps depsWith({
  required ILlmService llm,
  required IMessageRepository messages,
  required IConversationRepository conversations,
  IAttachmentRepository? attachments,
  IMcpService? mcpService,
  List<ActiveMcpServer> activeServers = const [],
  String modelName = 'fake-model',
  String systemPrompt = '',
  RequestProfile profile = const TextRequestProfile(),
  LlmHookRegistry hooks = const LlmHookRegistry.none(),
}) => ChatSessionDeps(
  llm: llm,
  mcpService: mcpService ?? FakeMcpService(),
  conversations: conversations,
  messages: messages,
  attachments: attachments ?? InMemoryAttachmentRepository(),
  activeServers: activeServers,
  modelName: modelName,
  effectiveSystemPrompt: systemPrompt,
  profile: profile,
  hooks: hooks,
);
