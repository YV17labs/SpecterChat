# SpecterChat - Development Guide

## Project Overview
SpecterChat is a lightweight cross-platform MCP chat client built with Flutter/Dart.
Desktop only — **macOS first**, then Windows and Linux.

## Tech Stack
- **UI**: Flutter 3.47+ with Material 3
- **State management**: Riverpod (StateNotifier pattern)
- **HTTP**: Dio
- **Database**: Drift (SQLite)
- **Models**: Freezed + json_serializable
- **Markdown**: flutter_markdown

## Architecture

Layered, dependency direction strictly inward. Enforced by
`test/architecture_test.dart` (import rules) — run it before moving code.

```
lib/
  main.dart            — App entry point, window config
  core/                — Theme, logging, app identity, id generation, HTTP
                         User-Agent client. Depends on no other layer.
  domain/              — Pure Dart. Freezed models, repository and service
                         contracts (I*Repository, ILlmService, IMcpService,
                         LlmHook), ChatSessionState, CancellationToken.
                         No Flutter widgets, Dio, Drift, Riverpod, mcp_dart.
    models/            — app_settings, mcp_server_state (runtime, not
                         persisted), conversation, conversation_settings,
                         effective_settings, message
    repositories/      — i_conversation_repository, i_message_repository,
                         i_attachment_repository, i_settings_store
    services/          — i_llm_service (StreamEvent), i_mcp_service,
                         llm_hook, cancellation_token
  application/         — Use cases. Depends on core + domain only.
    chat/              — ChatSession (streaming worker), ChatSessionManager
                         (LRU registry), ChatSessionDeps, ChatLogic (pure),
                         StreamAccumulator, StreamingPersister, ToolExecutor
    conversations/     — ConversationActions (create / fork / rename / delete)
    mcp/               — ActiveMcpServer + findServerForTool, content → text
    llm_hooks/         — LlmHookRegistry + per-model hooks (qwen3)
  infrastructure/      — Implementations of domain contracts.
    llm/               — LlmService (Dio), OpenAiCodec (wire format),
                         SseThinkSplitter
    mcp/               — McpService (mcp_dart), vendored transport
    persistence/       — AppDatabase (schema + migrations only),
                         ConversationRepository, MessageRepository,
                         AttachmentRepository, SharedPreferencesSettingsStore
  presentation/        — Riverpod + Flutter.
    providers/         — One file per concern. Controllers live here:
                         ConversationController (selection + actions),
                         McpConnectionController (runtime MCP state),
                         ConversationSettingsNotifier (optimistic mirror;
                         the debounced write lives in ConversationActions)
    ui/                — app_shell, chat/, sidebar_left/, sidebar_right/
                         (mcp/ sub-folder), widgets/. UI never imports
                         infrastructure; business rules go through
                         application/ or a provider.
```

Rules that keep it that way:

- **Domain contracts live with their consumers**, not their
  implementations. New service? Interface in `domain/services`, class in
  `infrastructure/`, provider in `presentation/providers`.
- **Widgets do not call repositories.** They call a controller/notifier or
  the `ChatSession` handle. Create/fork/delete a conversation only via
  `conversationControllerProvider`.
- **`McpServerConfig` is persisted, `McpServerState` is not.** Never add
  runtime fields (connection, tool lists) to the config model.
- **`ORDER BY id` is the canonical message order.** `generateId()` is a
  monotonic UUIDv7 (`core/id_gen.dart`); never mint ids any other way.
- **Cancellation is a domain concept** (`CancellationToken`,
  `StreamCancelled`). Transports map it to their own primitive; the chat
  pipeline must treat a cancelled turn differently from a finished one
  (no tool round, no retry).
- Text styles: use `context.specterStyles` tokens (`caption`, `small`,
  `smallMuted`, `monospace`, `sectionLabel`, `textMuted/Faint/Subtle`)
  rather than inline `TextStyle(... withValues(alpha: …))`.

## Tests

```
test/
  architecture_test.dart   — layer import rules
  support/                 — in-memory fakes (repos, LLM, MCP, settings
                             store) and `pumpApp` widget harness
  core/ domain/ application/ infrastructure/ presentation/
                           — mirror lib/; widget tests in presentation/ui
```

`ChatSession` is fully covered with fakes (stop mid tool-call, cancel after
done, hallucination retry, errors, dispose). Keep it that way when touching
the pipeline.

## Build & Run
```bash
flutter pub get
dart run build_runner build
# Drift migration-test helpers are gitignored — generate once after cloning,
# or `flutter analyze` / `flutter test` fail on
# test/infrastructure/persistence/migration_test.dart
dart run drift_dev schema generate --data-classes --companions \
  drift_schemas/ test/infrastructure/persistence/generated_migrations/
flutter run -d macos       # macOS (primary)
flutter run -d linux       # Linux (DevContainer)
```

## Code Generation
After modifying any Freezed model or Drift database:
```bash
dart run build_runner build
```

## Database Migrations (Drift)
The database uses Drift. Current schema version: **8**
(`schemaVersion` in `lib/infrastructure/persistence/database.dart`).

### Schema version history
- **v1** — Initial schema: `conversations` + `messages` tables
- **v2** — Index `idx_messages_conversation_id` on `messages.conversation_id`
- **v3** — `completion_tokens` + `duration_ms` columns on `messages`
- **v4** — `settings` JSON column on `conversations`
- **v5** — `last_prompt_tokens` column on `conversations`
- **v6** — `is_streaming` + `updated_at` on `messages`, for incremental
  streaming persistence across conversation switches and restarts
- **v7** — `attachments` table; image bytes move out of message content JSON
- **v8** — Ids standardised to UUIDv7 so `ORDER BY id` is a strict total
  order. Every row read and write depends on this invariant.

### The migration is destructive — read this before changing it
`onUpgrade` does **not** migrate data. It drops `messages` and
`conversations` (plus `attachments` when coming from v7 or later), then
recreates everything from scratch:

```dart
onUpgrade: (Migrator m, int from, int to) async {
  await m.deleteTable(messages.actualTableName);
  await m.deleteTable(conversations.actualTableName);
  if (from >= 7) {
    await m.deleteTable(attachments.actualTableName);
  }
  await m.createAll();
  // + recreate both indices
},
```

This was deliberate at v8: pre-UUIDv7 ids could not guarantee the ordering
invariant, so the old rows were discarded rather than backfilled. The
consequence is that **any schema bump wipes the user's chat history**. If
that is no longer acceptable, the strategy has to be replaced with
incremental steps before the next bump — not patched around.

### How to add a migration
1. Change the table definition in
   `lib/infrastructure/persistence/database.dart` (schema + migrations
   only — queries live in the repositories next to it)
2. Increment `schemaVersion`
3. Decide what `onUpgrade` should do. Keeping the current wipe means
   existing users lose their data; preserving it means writing real
   per-version steps (`if (from < 9) await m.addColumn(...)`) and dropping
   the blanket `deleteTable` calls
4. Update `onCreate` too if new installs need the change
5. Regenerate: `dart run build_runner build`
6. Export the schema snapshot:
```bash
dart run drift_dev schema dump lib/infrastructure/persistence/database.dart drift_schemas/
```
7. Regenerate the migration test helpers:
```bash
dart run drift_dev schema generate --data-classes --companions drift_schemas/ test/infrastructure/persistence/generated_migrations/
```
8. Add a migration test in `test/infrastructure/persistence/migration_test.dart`
9. Run tests: `flutter test test/infrastructure/persistence/`

### Schema snapshots
Snapshots live in `drift_schemas/` as JSON; test helpers are generated into
`test/infrastructure/persistence/generated_migrations/`, which is gitignored —
step 7 must be run once on a fresh clone or `flutter analyze` and
`flutter test` fail.

Only **v1, v2, v6, v7 and v8** have snapshots. v3, v4 and v5 were never
exported, so no test covers those transitions.

### Runtime safety
- `PRAGMA foreign_keys = ON` is enforced in `beforeOpen`
- `beforeOpen` also clears any `is_streaming` flag left set by a crash
- Indices are created in both `onCreate` and `onUpgrade`
- `DateTime` columns are stored with one-second precision; recency
  ordering breaks ties on `id` (UUIDv7)

## Key Architecture Decisions
- OpenAI-compatible API only — no Anthropic/Claude API. The wire format is
  confined to `infrastructure/llm/openai_codec.dart`; `ILlmService` takes
  domain `Message`s
- MCP via Streamable HTTP transport only (no stdio)
- Image handling is critical: MCP ImageContent must be displayed AND
  forwarded to the model as base64 image_url content blocks
- Dark theme by default
- All state in Riverpod providers, persistence via Drift/SQLite
- Lints: `analysis_options.yaml` enables strict casts/inference/raw types
  and a broad rule set; `flutter analyze` must stay at zero issues. The
  vendored MCP transport is the only file with `ignore_for_file`
