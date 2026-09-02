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

## Project Structure
```
lib/
  main.dart              — App entry point, window config
  models/                — Freezed data classes (message, conversation, settings)
  database/              — Drift database (SQLite), repository pattern
  services/              — LLM API, MCP client, tool executor, chat logic
  providers/             — Riverpod state management
  ui/
    app_shell.dart       — 3-panel layout
    sidebar_left/        — Conversation list
    chat/                — Chat view, message input
    sidebar_right/       — Settings panel, model selector, MCP server tile
    widgets/             — Reusable widgets (message bubble, content blocks,
                           expandable block, settings fields)
  utils/                 — Theme, helpers
```

## Build & Run
```bash
flutter pub get
dart run build_runner build
# Drift migration-test helpers are gitignored — generate once after cloning,
# or `flutter analyze` / `flutter test` fail on test/database/migration_test.dart
dart run drift_dev schema generate --data-classes --companions \
  drift_schemas/ test/database/generated_migrations/
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
(`schemaVersion` in `lib/database/database.dart`).

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
1. Change the table definition in `lib/database/database.dart`
2. Increment `schemaVersion`
3. Decide what `onUpgrade` should do. Keeping the current wipe means
   existing users lose their data; preserving it means writing real
   per-version steps (`if (from < 9) await m.addColumn(...)`) and dropping
   the blanket `deleteTable` calls
4. Update `onCreate` too if new installs need the change
5. Regenerate: `dart run build_runner build`
6. Export the schema snapshot:
```bash
dart run drift_dev schema dump lib/database/database.dart drift_schemas/
```
7. Regenerate the migration test helpers:
```bash
dart run drift_dev schema generate --data-classes --companions drift_schemas/ test/database/generated_migrations/
```
8. Add a migration test in `test/database/migration_test.dart`
9. Run tests: `flutter test test/database/`

### Schema snapshots
Snapshots live in `drift_schemas/` as JSON; test helpers are generated into
`test/database/generated_migrations/`, which is gitignored — step 7 must be
run once on a fresh clone or `flutter analyze` and `flutter test` fail.

Only **v1, v2, v6, v7 and v8** have snapshots. v3, v4 and v5 were never
exported, so no test covers those transitions.

### Runtime safety
- `PRAGMA foreign_keys = ON` is enforced in `beforeOpen`
- `beforeOpen` also clears any `is_streaming` flag left set by a crash
- Indices are created in both `onCreate` and `onUpgrade`

## Key Architecture Decisions
- OpenAI-compatible API only — no Anthropic/Claude API
- MCP via Streamable HTTP transport only (no stdio)
- Image handling is critical: MCP ImageContent must be displayed AND
  forwarded to the model as base64 image_url content blocks
- Dark theme by default
- All state in Riverpod providers, persistence via Drift/SQLite
