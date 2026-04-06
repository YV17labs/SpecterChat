# SpecterChat - Development Guide

## Project Overview
SpecterChat is a lightweight cross-platform MCP chat client built with Flutter/Dart.
Desktop only — **macOS first**, then Windows and Linux.

## Tech Stack
- **UI**: Flutter 3.29+ with Material 3
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
dart run build_runner build --delete-conflicting-outputs
flutter run -d macos       # macOS (primary)
flutter run -d linux       # Linux (DevContainer)
```

## Code Generation
After modifying any Freezed model or Drift database:
```bash
dart run build_runner build --delete-conflicting-outputs
```

## Database Migrations (Drift)
The database uses Drift with a versioned migration strategy.
Current schema version: **3**.

### Schema version history
- **v1** — Initial schema: `conversations` + `messages` tables
- **v2** — Add index `idx_messages_conversation_id` on `messages.conversation_id`
- **v3** — Add `completion_tokens` + `duration_ms` columns to `messages`

### How to add a migration
1. Make your schema change in the table definition (`database.dart`)
2. Increment `schemaVersion`
3. Add a migration step in `onUpgrade`:
```dart
onUpgrade: (Migrator m, int from, int to) async {
  if (from < 2) { /* ... */ }
  if (from < 3) {
    // Your new migration here
    await m.addColumn(messages, messages.newColumn);
  }
},
```
4. If `onCreate` also needs the change (new installs), update it too
5. Regenerate: `dart run build_runner build --delete-conflicting-outputs`
6. Export the new schema version:
```bash
dart run drift_dev schema dump lib/database/database.dart drift_schemas/
```
7. Regenerate migration test helpers:
```bash
dart run drift_dev schema generate --data-classes --companions drift_schemas/ test/database/generated_migrations/
```
8. Add a migration test in `test/database/migration_test.dart`
9. Run tests: `flutter test test/database/`

### Schema versioning
Schema snapshots are stored as JSON in `drift_schemas/` and test helpers
are generated into `test/database/generated_migrations/`. This enables
automated testing that:
- Each schema version can be created from scratch
- Migrations produce a valid schema
- Data is preserved across upgrades

### Runtime safety
- `PRAGMA foreign_keys = ON` is enforced in `beforeOpen`
- Indices are created in both `onCreate` and `onUpgrade`

## Key Architecture Decisions
- OpenAI-compatible API only — no Anthropic/Claude API
- MCP via Streamable HTTP transport only (no stdio)
- Image handling is critical: MCP ImageContent must be displayed AND
  forwarded to the model as base64 image_url content blocks
- Dark theme by default
- All state in Riverpod providers, persistence via Drift/SQLite
