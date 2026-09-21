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

## [Unreleased]

## [0.7.3] - 2026-09-21

Photos keep their metadata through image edits. Everything happens in the
app: the server plays no part and needs no update. Images attached before
this version carry no metadata; attach the photo again to use the feature.

### Added

- **Edited photos keep their metadata when saved.** When you attach a
  photo, everything its file carries is kept with it, verbatim: camera and
  lens, exposure, date taken, GPS position, the rest of the EXIF (maker
  notes and unknown tags included), XMP in any namespace, IPTC, comments
  and PNG text. Every image the model makes from that photo inherits it,
  through any number of edits ("make it blue", then "add a hat"), and
  "Save as…" writes it into the saved file without re-encoding the pixels.
  What describes the file rather than the photo stays the saved file's
  own: orientation, pixel size and colour profile. The old embedded
  thumbnail, a small copy of the original picture, is dropped. An image
  generated from the prompt alone inherits nothing.
- **A "Photo Metadata" section in the settings panel**, with two global
  switches, both on by default:
  - **Keep the original metadata.** Off, saved images carry none.
  - **Mark generated images as AI.** Writes the IPTC "digital source type"
    that photo apps read to flag AI images. When the photo already declares
    one (Apple Photos does after Clean Up), it is updated rather than
    duplicated.
- **Each image records how the model made it**, when the model returns it:
  edited from a picture you sent (a photo, a screenshot, an earlier
  result) or drawn from the prompt alone. The AI mark declares exactly
  that, "edited" or "generated", even for an edited screenshot that
  carries no metadata. A result you annotate and send again keeps it.
  Images generated before this version are marked from where they appear
  in the conversation.
- **You can see what a photo carries.**
  - Thumbnails in the composer get a camera badge.
  - On hover, images in the conversation show the camera model; its tooltip
    adds exposure, date and place, the date in your system's language
    ("5 juil. 2026, 19:41" on a Mac set to French). The rest of the app
    stays in English.
  - After "Save as…", a message says whether the original metadata and the
    AI mark went into the file.

### Changed

- **"Annotate & reuse" carries the image's metadata** to the new draft, so
  an edit of an edit still has the original photo's metadata.
- **"Save as…" asks where first**, then prepares the file: cancelling the
  dialog costs nothing.
- **Metadata stays out of the way of the chat.** A message keeps only what
  is shown (camera, date, place); the metadata itself is stored beside the
  image and read only to save or reuse it, so a large XMP from Lightroom
  or a ComfyUI workflow embedded in a PNG does not slow the conversation
  down. Each image made from a photo has its own copy, so deleting a
  message never takes another image's metadata with it. No schema change:
  the chat history is kept.
- **Metadata handling is a domain contract** (`IPhotoMetadataCodec`) with a
  pure-Dart implementation: same behaviour on macOS, Windows and Linux.
  Dates are formatted with `intl` (new dependency, date formats only).
  Test suite grew from 406 to 467.

### Known limitations

- Metadata is written into PNG and JPEG files. WebP and GIF are saved as
  they are.
- In a saved PNG, IPTC fields that have no XMP equivalent (IPTC date and
  time created, for instance) are in the file but not shown by macOS
  Preview, which reads no IPTC from PNG files; exiftool shows them.
- "Copy image" carries no metadata: the macOS clipboard keeps only the
  pixels. Pasting a photo into the composer loses its metadata for the same
  reason; attach it with the paperclip or by drag-and-drop instead.
- Photos no larger than 2048 px on a side are still sent to the server
  untouched, their EXIF (GPS included) with them. Removing it on send is
  not done yet.

## [0.7.2] - 2026-09-20

Image generation and local image editing, on top of the text chat. Needs a
**Pictor ≥ 0.3.0** server for the image features; text-LLM servers are
unaffected. Existing settings and chat history are read as-is.

### Added

- **Image generation with a Pictor server.** Pick an image model in the
  model list (they are marked with an icon) and the settings panel swaps the
  text-LLM sections for an **Image** section: mode (auto / generate / edit /
  chat), aspect ratio, size, steps, seed (with a dice for a random one),
  guidance, negative prompt, transparent background — each greyed out when
  the backend cannot do it, each overridable per conversation with a reset.
  The bubble shows the server's progress bar ("generating 12/40") instead of
  the typing dots; the result is stored like any attachment and displayed
  inline. A generated image is re-sent on the next turn, so "now make it
  blue" edits it.
- **Images go into messages.** Attach with the paperclip (native file
  dialog), drop files anywhere on the chat panel, or Cmd/Ctrl+V an image
  from the clipboard. PNG, JPEG, WebP and GIF are recognised by content, not
  extension; anything larger than 2048 px on a side is downscaled first; up
  to 10 images per message, shown as a thumbnail strip before sending. A
  message may be an image with no text.
- **An annotation editor for local edits.** Open any pending image (or hit
  "Annotate & reuse" on an image already in the conversation) and draw the
  region to change: pen, ellipse or rectangle in one of five colours and
  three widths, a mask brush, an eraser, undo / redo (⌘Z / ⇧⌘Z) and a mask
  preview. On send the annotated copy goes to the model, optionally with a
  black-and-white mask and the untouched original; an empty composer is
  pre-filled with "In the red area: …" naming the colours used. The
  original is never modified — the editor reopens on it.
- **Images in the conversation gain "Save as…" and "Copy"** on hover, next
  to the new annotate action.
- **The app remembers which models are image models** between launches, so
  the Image section is right at startup, before the model list has been
  fetched.

### Changed

- **Protocol 0.3.0.** The image extension object is named `generation` in
  requests and in the model list (it was `specterforge`); a server that
  still tags its models with the old key is recognised, but image options
  are only honoured by Pictor ≥ 0.3.0.
- **Fewer round-trips to the server.** The model list is fetched at
  startup, when the base URL or API key change (once you stop typing) and
  on refresh — no longer every time a model is picked or a slider moves.
  Sampling and image options now travel with each request instead of
  rebuilding the HTTP client on every change.
- **Composer, editor and model catalogue logic moved out of the widgets**
  into testable units (`ComposerNotifier`, `DrawingSession`,
  `ModelCatalogNotifier`), behind domain contracts for image
  normalisation, rendering, file dialogs and the clipboard; widgets no
  longer touch platform plugins directly. Enforced by the architecture
  test. Test suite grew from 254 to 406.
- **Dependencies brought up to date.** Markdown is rendered by
  `flutter_markdown_plus`, the maintained successor of the discontinued
  `flutter_markdown` (same rendering); `flutter_highlight`, `highlight` and
  `collection` were declared but never used and are gone. Every other
  dependency is at its latest version.

### Fixed

- **A server error in the middle of a stream is reported.** Some servers
  send the OpenAI error envelope as a stream event rather than an HTTP
  status; it was skipped as an unknown chunk and the turn hung until the
  connection closed. It now ends the turn with the error banner.
- **Multi-byte characters split across two network packets** (accents,
  CJK, emoji) were decoded as replacement glyphs; the stream is now decoded
  as a whole.
- **A multi-megabyte stream line** (a base64 image) no longer gets re-split
  on every packet, which made large images arrive slowly.

## [0.5.2] - 2026-09-11

### Fixed

- **Nested tool parameters reach the tool as objects.** A tool schema that
  describes a nested type through `$defs` + `$ref` (rmcp, pydantic) is now
  inlined before it is sent to the model. Some runtimes read a parameter's
  type off the property without following the reference — Ollama's Qwen3
  parser among them — and handed the tool a JSON string where it expected
  an object. Runtimes that already resolved references (llama.cpp) see the
  same schema, spelled out.

## [0.5.1] - 2026-09-11

Maintenance release: no new features, no breaking changes. Existing
settings and chat history are read as-is.

### Changed

- **Codebase reorganised into explicit layers** — `core/`, `domain/`,
  `application/`, `infrastructure/`, `presentation/` — with the dependency
  direction enforced by an architecture test. Domain contracts now live
  next to their consumers; the OpenAI wire format is confined to one codec;
  `ChatSession` is split into an accumulator, a persister and the session
  itself; every conversation action (create / fork / rename / delete) goes
  through one controller; MCP runtime state (connection, tools, prompts)
  is no longer stored in the persisted server config. No user-facing
  behaviour change beyond the fixes below.
- **Stricter static analysis.** `strict-casts`, `strict-inference`,
  `strict-raw-types` and ~50 additional lint rules; the whole tree is
  `dart format`ted.
- **Test suite grew from 164 to 254 tests**, now covering the streaming
  pipeline end to end (`ChatSession`, `ChatSessionManager`,
  `ToolExecutor`), providers and the main widgets.

- **Outbound HTTP requests now identify the client.** Every request to the
  LLM API and to MCP servers carries
  `User-Agent: SpecterChat/<version> (<os>) Dart/<runtime>` instead of
  Dart's default `Dart/3.x (dart:io)`, so server-side logs can tell
  SpecterChat apart from other clients and which version is talking. A
  `User-Agent` set in a server's custom headers still takes precedence.
- **The MCP `clientInfo` reports the real app version.** It was pinned to
  `0.1.0` regardless of the build; it now follows `pubspec.yaml`, like the
  About section.

### Fixed

- **Stop really stops.** Pressing Stop while the model had already emitted a
  complete tool call used to execute that tool and start another model
  turn: the transport reported a cancelled request the same way as a
  finished one. Cancellation is now its own stream event; a stopped turn
  keeps its partial text and never runs tools or retries.
- **Deleting a conversation tears down its streaming session first**, so an
  in-flight stream can no longer keep writing to rows that are gone.
- **Message ids are strictly monotonic.** `ORDER BY id` is the canonical
  message order, but UUIDv7 ids minted within the same millisecond (parallel
  tool results, a fast local model) carried random low bits and could sort
  out of creation order. The generator now uses the 12-bit `rand_a` field
  as an intra-millisecond counter.
- **A conversation created while the session cap was reached could be
  handed to the UI already disposed** — the LRU pass no longer evicts the
  session it is creating.
- **Conversations created within the same second now keep a stable order**
  in the sidebar (`updated_at` has one-second precision; ties break on id).
- **Per-conversation settings edits are no longer lost when switching
  conversations** during the 500 ms save debounce.
- **A tool call no longer fails for good once the server has dropped the MCP
  session.** Streamable HTTP servers evict idle sessions (rmcp does after
  5 minutes without a request) and answer every later call carrying the old
  `mcp-session-id` with `404 Session not found`. The client used to surface
  that as a generic `Error POSTing to endpoint (HTTP 404)` to the model,
  retry the dead id on its SSE stream, and stay marked connected; the only
  way out was a manual reconnect. The transport now treats that 404 for what
  the spec says it is — the session is gone — forgets the id and stops the
  reconnection loop, and `McpService` opens a new session and replays the
  call once, so a pause in the conversation is invisible to the model.

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
