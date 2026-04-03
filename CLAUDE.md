# Specter Chat - Development Guide

## Project Overview
Specter is a lightweight cross-platform MCP chat client built with Flutter/Dart.
Desktop only (macOS, Windows, Linux).

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
  database/              — Drift database (SQLite)
  services/              — LLM API service, MCP client
  providers/             — Riverpod state management
  ui/
    app_shell.dart       — 3-panel layout
    sidebar_left/        — Conversation list
    chat/                — Chat view, message input
    sidebar_right/       — Settings panel
    widgets/             — Reusable widgets (message bubbles, etc.)
  utils/                 — Theme, helpers
```

## Build & Run
```bash
# Inside DevContainer:
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d linux
```

## Code Generation
After modifying any Freezed model or Drift database:
```bash
dart run build_runner build --delete-conflicting-outputs
```

## Key Architecture Decisions
- OpenAI-compatible API only — no Anthropic/Claude API
- MCP via Streamable HTTP transport only (no stdio)
- Image handling is critical: MCP ImageContent must be displayed AND
  forwarded to the model as base64 image_url content blocks
- Dark theme by default
- All state in Riverpod providers, persistence via Drift/SQLite
