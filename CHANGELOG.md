# Changelog

All notable changes to SpecterChat are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version is below `1.0.0`, the **minor** number carries breaking
changes.

> Versions before `0.5.0` were reconstructed from the git history: they were
> `pubspec.yaml` bumps, not published releases. Only `v0.2.0` was ever tagged,
> and no binaries were distributed before `0.5.0`. Dates are the dates of the
> version bump.

## [0.5.0] - 2026-09-01

First release with prebuilt installers for macOS, Windows, and Linux.

### Breaking

- **macOS 11 and earlier are no longer supported.** The minimum is now
  macOS 12 (Monterey). Flutter 3.47 dropped support for older releases and
  raised the deployment target from 10.15 to 12.0, so this is imposed
  upstream rather than chosen. Users on Big Sur or older must stay on a
  previous build.
- The Flutter SDK floor moved to **3.47**, and the Dart SDK floor to **3.8**.
  Contributors on older SDKs will fail at `flutter pub get`.

### Added

- Cross-platform release pipeline producing a macOS `.dmg`, a Windows
  installer, and a Linux `.AppImage` plus `.deb`, published to GitHub
  Releases from a `v*` tag.
- Per-platform build instructions and an application screenshot in the
  README.

### Changed

- Upgraded to Flutter 3.47.2 across the release workflow, the DevContainer,
  and the documentation.
- Upgraded 81 packages, including Drift 2.34, Riverpod 3.4, mcp_dart 2.4,
  and Dio 5.11.
- The macOS build is a universal binary (Intel and Apple Silicon); the disk
  image is named accordingly.
- Linux artifacts are built on Ubuntu 22.04 so they remain usable on
  Debian 12 and Ubuntu 22.04, rather than only on newer distributions.
- Relicensed to MIT, with copyright attributed to Yoann Vanitou (YV17labs).
- Neutralized the Qwen hallucination-correction prompt.

### Fixed

- Thinking and reasoning content is now detected across the differing
  formats emitted by llama.cpp, mlx_vlm, and OpenAI-compatible servers.
- The Linux packaging step no longer fails for a missing
  `desktop-file-validate`, and fetches `appimagetool` from its maintained
  repository.
- A fresh clone can now run `flutter analyze` and `flutter test`: the Drift
  migration-test helpers are generated, not committed, and the step to
  generate them was undocumented.
- The DevContainer no longer runs `flutter create`, which rewrote the Linux
  application id and broke the desktop-entry window class match.

## [0.4.1] - 2026-05-01

### Fixed

- Tool results are persisted atomically, fixing an "Image unavailable" race
  when a result was read before its write completed.

## [0.4.0] - 2026-05-01

### Added

- A "Tell me more" selection menu, and the ability to fork a conversation
  from any message.

## [0.3.0] - 2026-04-23

### Added

- Image attachments are stored as blobs, with identifiers switched to
  UUIDv7.
- Stalled LLM streams are detected through per-model hooks, with Qwen3
  wired into stall recovery.

### Changed

- Streaming text renders through `MarkdownBody` directly.
- Chat memory is bounded by message pagination and provider auto-disposal.
- Flutter's image cache is capped and the MCP icon cache is bounded.
- Image bytes are cached across tool-loop iterations.

## [0.2.0] - 2026-04-21

### Added

- A status dot indicator on the MCP server icon.

### Changed

- Streaming text fades in per word with progressive markdown and a trailing
  brightness ramp.
- Blocks animate on fade-in, expand and collapse, and bubble height changes.

## [0.1.0] - 2026-04-19

Initial working client.

### Added

- Three-panel layout: conversation list, chat area, settings sidebar.
- Streaming responses against any OpenAI-compatible API, with a stop button
  and live token display.
- MCP integration over Streamable HTTP: multiple servers, tool discovery and
  execution, prompts, resources, icons, and tool annotations, with optional
  Bearer token authentication.
- Tool results rendered as ordered content blocks, with the call and its
  result merged into a single expandable block. MCP images are displayed
  inline and forwarded back to the model.
- Per-conversation settings with MCP server scoping, conversation
  duplication, and persisted context token counts.
- SQLite persistence through Drift, with a versioned migration strategy.
- Markdown rendering with syntax-highlighted code blocks, collapsible
  thinking blocks, and typewriter streaming.
- Dark theme based on the Zed One Dark palette, centralized through a
  `SpecterStyles` theme extension.
- Hallucinated tool-call XML is detected and corrected through an LLM hook
  system.
- Structured logging and global error handlers.
