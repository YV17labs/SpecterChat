# Specter Chat

A lightweight, cross-platform desktop chat client with MCP (Model Context Protocol) support. Built with Flutter.

Specter connects to any OpenAI-compatible API (Ollama, LM Studio, vLLM, llama.cpp server, etc.) and lets you interact with MCP servers to extend your model's capabilities with external tools.

## Why Specter?

Existing chat clients fail at one critical thing: when an MCP tool returns an image, they either don't display it or don't forward it to the model. Specter solves this — images from MCP tools are rendered inline **and** sent back to the model as base64 so it can actually see them.

## Features

- **3-panel layout** — conversation list, chat area, and settings sidebar
- **Streaming responses** with real-time token display and stop button
- **Markdown rendering** with syntax-highlighted code blocks
- **Thinking/reasoning display** — collapsible chain-of-thought blocks
- **MCP integration** via Streamable HTTP — connect to multiple servers, discover tools, execute them
- **Image handling** — MCP `ImageContent` displayed inline and forwarded to the model
- **Tool call display** — tool name, arguments (collapsible JSON), and results
- **Full generation controls** — temperature, top-p, top-k, max tokens, penalties
- **Local storage** — chat history and settings persisted in SQLite
- **Dark theme** by default

## Requirements

- Docker (for DevContainer)
- VS Code with the Dev Containers extension

## Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/your-org/specterchat.git
   cd specterchat
   ```

2. Open in VS Code and select **"Reopen in Container"** when prompted.

3. The DevContainer will automatically:
   - Install Flutter 3.41.5 and all dependencies
   - Generate platform files
   - Run code generation (Freezed, Drift)

4. Run the app:
   ```bash
   flutter run -d linux
   ```

## Development Commands

```bash
# Install dependencies
flutter pub get

# Run code generation (after modifying models or database)
dart run build_runner build --delete-conflicting-outputs

# Watch mode for code generation
dart run build_runner watch --delete-conflicting-outputs

# Run tests
flutter test

# Build release
flutter build linux --release
```

## Usage

1. Start your LLM server (Ollama, LM Studio, etc.)
2. In the right sidebar, set the **Base URL** (e.g. `http://localhost:1234/v1`)
3. Click the refresh button to load available models and select one
4. Optionally add MCP servers (name + URL) and connect to them
5. Create a new conversation and start chatting

## License

MIT
