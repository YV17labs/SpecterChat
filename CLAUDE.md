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
- **Markdown**: flutter_markdown_plus
- **Dates**: intl, formats only (the UI is not localised: no
  flutter_localizations)

## Architecture

Layered, dependency direction strictly inward. Enforced by
`test/architecture_test.dart` (import rules) — run it before moving code.

```
lib/
  main.dart            — App entry point, window config
  core/                — Theme, logging, app identity, id generation, HTTP
                         User-Agent client. Depends on no other layer.
  core/                — … plus image_mime (magic-byte sniffer, accepted
                         formats).
  domain/              — Pure Dart. Freezed models, repository and service
                         contracts (I*Repository, ILlmService, IMcpService,
                         LlmHook), ChatSessionState, CancellationToken.
                         No Flutter widgets, Dio, Drift, Riverpod, mcp_dart,
                         dart:ui.
    models/            — app_settings, mcp_server_state (runtime, not
                         persisted), conversation, conversation_settings,
                         effective_settings, message, image_settings,
                         model_info, annotation, request_profile (what a
                         request carries: text sampling vs image options),
                         photo_metadata (PhotoMetadata = PhotoSummary +
                         the verbatim PhotoMetadataBlocks; the
                         PhotoMetadataRef an image block keeps; AiOrigin),
                         message_stats (GenerationStats / ToolCallStats:
                         what a message was produced with and measured at),
                         request_context (the system prompt as sent and the
                         tool definitions a request carried)
    repositories/      — i_conversation_repository, i_message_repository,
                         i_attachment_repository, i_settings_store,
                         i_model_catalog_store
    services/          — i_llm_service (StreamEvent), i_mcp_service,
                         llm_hook, cancellation_token, i_image_normalizer,
                         i_annotation_renderer, i_image_io (dialogs +
                         clipboard), i_photo_metadata_codec, i_file_saver
                         (non-image "Save as…")
  application/         — Use cases. Depends on core + domain only.
    chat/              — ChatSession (streaming worker), ChatSessionManager
                         (LRU registry), ChatSessionDeps, ChatLogic (pure),
                         StreamAccumulator, GenerationRecorder (a turn's
                         stats), StreamingPersister, ToolExecutor,
                         message_writes (the one transactional "row + blobs"
                         write every message with images goes through)
    conversations/     — ConversationActions (create / fork / rename / delete),
                         ConversationExporter (JSON export), runsOf (the
                         one split of a history into runs)
    mcp/               — ActiveMcpServer + findServerForTool, content → text
    llm_hooks/         — LlmHookRegistry + per-model hooks (qwen3)
    images/            — PendingImage (composer draft entry + slot maths),
                         DrawingSession (editor state machine), Annotation
                         History/Geometry, expandPendingImages (outgoing
                         bytes via IAnnotationRenderer), annotation prompt
                         template, ImageExporter ("Save as…" with the
                         photo metadata the user keeps),
                         stored_photo_metadata (load / copy the blocks
                         attachment behind a PhotoMetadataRef; a stored
                         block as a DescribedImage)
  infrastructure/      — Implementations of domain contracts.
    llm/               — LlmService (Dio), OpenAiCodec (wire format incl.
                         the per-profile request body), SseThinkSplitter
    mcp/               — McpService (mcp_dart), vendored transport
    persistence/       — AppDatabase (schema + migrations only),
                         ConversationRepository, MessageRepository,
                         AttachmentRepository, SharedPreferencesSettingsStore,
                         SharedPreferencesModelCatalogStore
    images/            — UiImageNormalizer (dart:ui decode/downscale),
                         DesktopImageIo (file_selector + pasteboard),
                         ExifPhotoMetadataCodec (pure-Dart EXIF read/write)
    files/             — DesktopFileSaver (file_selector save dialog)
  presentation/        — Riverpod + Flutter.
    providers/         — One file per concern. Controllers live here:
                         ConversationController (selection + actions),
                         McpConnectionController (runtime MCP state),
                         ConversationSettingsNotifier (optimistic mirror;
                         the debounced write lives in ConversationActions),
                         ModelCatalogNotifier (owns the /models fetch and
                         the persisted image-model cache), ComposerNotifier
                         (pending images per conversation), image service
                         providers, requestProfileProvider,
                         conversationExporterProvider
    rendering/         — dart:ui code that is not a widget: AnnotationPainting
                         (shared by the editor's CustomPainter and the PNG
                         export), UiAnnotationRenderer, decode helpers. No
                         Flutter widgets, no providers.
    ui/                — app_shell, chat/ (ChatView = list + drop zone,
                         ChatComposer = text + images), sidebar_left/,
                         sidebar_right/ (mcp/ sub-folder), widgets/. UI never
                         imports infrastructure nor the desktop plugins;
                         business rules go through application/ or a provider.
```

Rules that keep it that way:

- **Domain contracts live with their consumers**, not their
  implementations. New service? Interface in `domain/services`, class in
  `infrastructure/`, provider in `presentation/providers`. One exception,
  on purpose: `UiAnnotationRenderer` lives in `presentation/rendering`
  because it draws with the same `AnnotationPainting` the editor's
  `CustomPainter` uses, and `ui/` may not import infrastructure.
- **Widgets do not call repositories.** They call a controller/notifier or
  the `ChatSession` handle. Create/fork/delete a conversation only via
  `conversationControllerProvider`.
- **Widgets do not call platform plugins.** File dialogs and the image
  clipboard go through `IImageIo` (`imageIoProvider`); the only plugin a
  widget touches is `desktop_drop`'s `DropTarget`. Enforced by
  `architecture_test`.
- **`McpServerConfig` is persisted, `McpServerState` is not.** Never add
  runtime fields (connection, tool lists) to the config model. Same rule
  for what the server reports about its models: that is a cache, kept in
  `IModelCatalogStore` under its own key, never in `AppSettings`.
- **Per-request settings travel with the request.** `LlmService` holds
  only the connection; sampling parameters or image options arrive as a
  `RequestProfile` in `ChatSessionDeps` (resolved by
  `requestProfileProvider`). Moving a slider must not rebuild the HTTP
  client. A new kind of backend is a new profile case in
  `OpenAiCodec.requestBody`, nothing else.
- **Editor and composer logic is not widget state.** `DrawingSession`
  (application) is the annotation editor; `_AnnotationEditorState` only
  maps pixels to normalised points and calls `setState`. `ComposerNotifier`
  owns the pending images; `ChatComposer` owns the text controller and
  turns refusals into snackbars.
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
The database uses Drift. Current schema version: **10**
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
- **v9** — `stats` JSON column on `messages` (`MessageStats`). First step
  that keeps the user's data.
- **v10** — `request_contexts` table: the system prompt as sent and the
  tool definitions, once per change in a conversation

### Migrations keep the data from v8 on
`onUpgrade` has two regimes:

```dart
onUpgrade: (Migrator m, int from, int to) async {
  if (from < 8) {
    // drop messages, conversations (+ attachments from v7), createAll,
    // recreate both indices — then return
  }
  if (from < 9) await m.addColumn(messages, messages.stats);
  if (from < 10) await m.createTable(requestContexts);
},
```

Below v8 the rows are still discarded: pre-UUIDv7 ids could not guarantee
the ordering invariant, and `createAll` builds the current schema
directly. From v8 on every bump is an incremental step that keeps the
user's history — never add a `deleteTable` there. Every released build so
far (0.5.0 → 0.7.3) carries schema v8, so updating from any of them keeps
everything.

`prepareDatabaseFile` runs before the file is opened (it reads the
`user_version` from the header, four bytes at offset 60):

- a file this build would migrate is copied next to itself first
  (`specter.db.v9.backup`, once per source version), so a migration that
  goes wrong still leaves the history somewhere;
- a file written by a **later** build is set aside
  (`specter.db.v11.newer`) and the app starts on a fresh one. Drift calls
  `onUpgrade` whenever the versions differ, in *either* direction
  (`hadUpgrade => versionBefore != versionNow`), and every build up to
  0.7.3 recreated its tables there: opening a newer database with one of
  those empties it. That is how a real conversation history was lost.

### How to add a migration
1. Change the table definition in
   `lib/infrastructure/persistence/database.dart` (schema + migrations
   only — queries live in the repositories next to it)
2. Increment `schemaVersion`
3. Add its step to `onUpgrade` (`if (from < 10) await m.addColumn(...)`),
   after the existing ones; the `from < 8` branch needs nothing
4. Update `onCreate` too if new installs need more than `createAll`
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
   (the v8 → v9 one writes rows with the old schema's helpers and reads
   them back through `MessageRepository`)
9. Run tests: `flutter test test/infrastructure/persistence/`

### Schema snapshots
Snapshots live in `drift_schemas/` as JSON; test helpers are generated into
`test/infrastructure/persistence/generated_migrations/`, which is gitignored —
step 7 must be run once on a fresh clone or `flutter analyze` and
`flutter test` fail.

Only **v1, v2, v6, v7, v8, v9 and v10** have snapshots. v3, v4 and v5
were never exported, so no test covers those transitions.

### Runtime safety
- `PRAGMA foreign_keys = ON` is enforced in `beforeOpen`
- `beforeOpen` also clears any `is_streaming` flag left set by a crash
- Indices are created in both `onCreate` and `onUpgrade`
- `DateTime` columns are stored with one-second precision; recency
  ordering breaks ties on `id` (UUIDv7)

## Images

Both directions are first-class; the wire protocol is the one described in
`../pictor/PROTOCOL.md` (Pictor: OpenAI chat completions + extension
fields). Since protocol 0.3.0 the extension object is named `generation`
everywhere (model entry, request body, `images[]` meta); it was
`specterforge` before, and `parseModelInfo` still accepts that key on read.

**User → model.** `ChatSession.sendMessage(text, images: [...])` takes
`DescribedImage`s (domain: bytes, MIME type, photo metadata, AI origin) and
writes one `ContentBlock.image` per image (`ChatLogic.buildUserMessage`,
which returns the row and its blobs as one `MessageWrite`), bytes in the
`attachments` table, in the same transaction as the message row (same
rule as tool-result images). Input paths, all landing in `ComposerNotifier`
(`composerProvider(conversationId)`, auto-disposed with the view):
- attach button → `IImageIo.pickImages` (`DesktopImageIo` on
  `file_selector`; macOS needs the `files.user-selected.read-write`
  entitlement, present in both `.entitlements` files)
- drag-and-drop → `desktop_drop.DropTarget` around the whole `ChatView`,
  forwarded to `ChatComposerState.attachFiles`
- Cmd/Ctrl+V → `ChatInputArea` consumes the chord and `ChatComposer`
  decides: `IImageIo.readClipboardImage` present → attach, else plain-text
  paste at the caret
- every source goes through `IImageNormalizer` (`UiImageNormalizer`): MIME
  sniffed from magic bytes (`core/image_mime.dart`, png/jpeg/webp/gif only),
  longest side capped at 2048 px (re-encoded as PNG); at most
  `kMaxPendingImages` outgoing images (`PendingImageStrip` shows them)

**Annotation.** A pending image can be annotated (`AnnotationEditor` →
`DrawingSession`); the `Annotation` (normalised coordinates, domain) is kept
on the `PendingImage` and only rendered at send time by
`expandPendingImages` through `IAnnotationRenderer`: annotated copy, then
mask, then original, per the editor's options. A render failure restores
the draft. `annotationPromptTemplate` pre-fills an empty composer with the
colours used. "Annotate & reuse" on a bubble goes through the one-shot
`imageReuseProvider`, like `chatInputInjectionProvider`; its `request`
loads the block's photo metadata (`describeStoredImage`) before handing
the `DescribedImage` over.

**Image models.** `ModelCatalogNotifier` owns the `/models` fetch (at
startup, on base URL / key change, on refresh) and merges the image-model
descriptions into `IModelCatalogStore`; `selectedImageModelProvider` reads
that cache so the panel is right before the first fetch.
`requestProfileProvider` turns the selection into a `TextRequestProfile`
or `ImageRequestProfile`, snapshotted per send in `ChatSessionDeps`.

`OpenAiCodec.contentParts` emits `image_url` data-URL parts for **user and
assistant** messages alike — a generated image is re-sent on the next turn
so "now make it blue" edits it.

**Model → user.** `LlmService._parseChunk` understands two extra fields on
`delta`:
- `progress` → `ProgressDelta(GenerationProgress)`; the session mirrors
  it into `SessionStreaming.progress` (transient, never persisted) and
  `MessageBubble` renders a `GenerationProgressBar` instead of the dots
- `images[]` (OpenRouter shape, `image_url.url` as data URL or a URL fetched
  through the same Dio client) → `ImageDelta`; the session stores the bytes
  as an attachment bound to the streaming placeholder row *before* the next
  upsert references them, and `ChatLogic.buildAssistantMessage` appends the
  image blocks after the text block. An image-only turn counts as
  sendable. A `data: {"error": …}` event mid-stream ends the turn with
  `StreamError`.

The SSE reader decodes through `utf8.decoder` (multi-byte characters may
straddle packets) and only re-scans the buffer when a newline arrives, so a
multi-megabyte image line does not get re-split on every packet.

**Annotations (local editing).** Qwen-Image-2.1 edits a region when the
reference image carries coloured outlines and the prompt names the colour
("in the red area…"); it also accepts a separate black-and-white mask. The
pieces, inward to outward:
- `domain/models/annotation.dart` — `Annotation` (ordered `AnnotationShape`
  list: freehand / ellipse / rectangle in one of five `AnnotationColor`s,
  or a colourless `MaskStroke`), normalised `[0, 1]` coordinates and
  `StrokeWidth` as a fraction of the longest side, so one document renders
  identically on the preview and on the full-size original. Freezed + JSON.
- `application/images/` — `AnnotationHistory` (immutable undo/redo, bounded),
  `AnnotationGeometry` (aspect-aware hit-testing for the eraser) and
  `DrawingSession`: the whole editor as an immutable value (tool, colour,
  width, gesture in progress, options, slot rules). Every transition is a
  unit test; the widget only maps pixels to normalised points.
- `presentation/rendering/` — `annotation_painting.dart` is the single
  painter used by both the editor canvas and the export
  (`UiAnnotationRenderer`, the `IAnnotationRenderer`: annotated copy at the
  original pixel size, mask white-on-black with outlines filled).
- `presentation/ui/chat/annotation/` — `AnnotationEditor` (tools Pen /
  Ellipse / Rectangle / Mask brush / Eraser, swatches, 3 widths,
  undo/redo/clear, mask preview, ⌘Z / ⇧⌘Z / Esc) is opened through
  `showAnnotationEditor`, which decodes the image once and owns its
  lifetime.
- A `PendingImage` (application) keeps the untouched original plus the
  editor's `AnnotationResult` (`annotation`, `includeMask`,
  `keepOriginal`; `null` when nothing is drawn); nothing is rendered until
  send, when `expandPendingImages` produces annotated copy → mask →
  original in that order (each entry counts `outgoingCount` against the
  `kMaxPendingImages` cap). The editor opens from the thumbnail (tap or
  pencil) and from any image in the conversation ("Annotate & reuse" hover
  action → `imageReuseProvider` → `ChatComposer`). Applying into an empty
  composer inserts `annotationPromptTemplate` ("In the red area: …").

**Photo metadata.** Everything a photo's file says about it is kept, not a
list of known fields — the user's requirement is that no metadata is ever
lost, including kinds that do not exist yet. `IPhotoMetadataCodec`
(`ExifPhotoMetadataCodec`, pure Dart) reads, in `ComposerNotifier.attach`
and *before* the normaliser may re-encode it away, a `PhotoMetadata`:
- `blocks` (`PhotoMetadataBlocks`), verbatim: the EXIF TIFF (maker notes
  and unknown tags included; only the IFD1 thumbnail is dropped), the XMP
  packet (padding trimmed), the Photoshop resources holding IPTC
  (thumbnail resources dropped), PNG text chunks and JPEG comments — from
  JPEG, PNG and WebP (`exif` / `iptc` base64, `xmp`, `texts`; ~5 KB for an
  iPhone photo, far more for a Lightroom XMP or a ComfyUI workflow);
- `summary` (`PhotoSummary`: `camera`, `captured` — a wall-clock
  `DateTime` + UTC offset —, `location`), parsed from the EXIF for display
  only. Nothing is ever written from it.

In memory the whole `PhotoMetadata` travels on a `DescribedImage`
(`PendingImage.image` → `expandPendingImages` → `sendMessage`); an
annotation's mask carries none. Once sent it is split
(`ChatLogic.buildUserMessage`): the block keeps a `PhotoMetadataRef`
(summary + `blocksId`), JSON in the message row; the blocks go to an
attachment of the same message, MIME type `PhotoMetadataBlocks.mimeType`,
written in the same transaction (one per message for images sharing them,
an annotated copy and its original). So `watchMessages`, which decodes the
JSON on every streaming emission, never carries them. That attachment is
not an image: `imageAttachmentIds` never lists it, `loadBytes` / `loadMany`
never return it (never drawn, never sent to the model); only
`loadPhotoMetadata` does, at "Save as…" (after the save location is chosen)
and "Annotate & reuse" — through `ImageExporter` and `imageReuseProvider`,
never from a widget (`application/images/stored_photo_metadata.dart`). No
schema bump: JSON column and the existing `attachments` table.
- A block's `aiOrigin` (`AiOrigin.editedPhoto` / `generated`, `null` for a
  photo, screenshot or tool result) says how a model made the image. Set
  once, when the block is written: `ChatLogic.generatedImageOrigin` decides
  it together with the inherited metadata. `ImageDelta.textToImage` is what
  the server says (`generation.mode`: `text_to_image` → generated,
  `reference_edit` → edited, absent → `null`); unsaid, the image is an edit
  whenever there is a reference. The references are the images of the last
  user turn, else the conversation's latest image (the server reuses it for
  "make it blue"); the first with metadata is inherited, so metadata
  follows a chain of edits. An edit is `editedPhoto` even without metadata
  (an edited screenshot); an edit of a text-to-image result is
  `editedPhoto` too.
- An inherited `PhotoMetadataRef` gets its own copy of the blocks
  (`IAttachmentRepository.copy`, an `INSERT … SELECT` in SQLite) bound to
  the streaming placeholder, once per turn and before the upsert that
  references it — the source's message may be deleted, a discarded
  placeholder takes its copy along (FK cascade). "Annotate & reuse" carries
  the metadata (loaded) and the `aiOrigin` to the new blocks.
- Earlier builds, read not written: blocks from b5e996e kept the blocks
  inline and the summary fields at the top level (`PhotoMetadataRef`
  reads both through `readValue`; `inlineBlocks` is used for save, reuse
  and inheritance, which then stores a proper attachment); their EXIF-shaped
  date (`2026:07:05 19:41:50`) still parses. Blocks from the very first
  build hold display fields only and are saved without metadata. Images a
  model made before `aiOrigin` existed get it from their message's role in
  `MessageRepository._withLegacyAiOrigin` — the one place the role still
  decides it.
- Nothing is written into stored bytes. "Save as…" is
  `ImageExporter.save`: `IImageIo.saveImage` asks for a location first and
  only then calls back for the file (`prepare`), so a cancelled dialog
  loads and copies nothing. Two global switches, `AppSettings.photoMetadata`
  (`PhotoMetadataExport`, right panel "Photo Metadata"): keep the original
  metadata and mark generated images as AI, both on by default (the latter
  is `markGeneratedAsAi`; the first version's `markAiEdited: false` is
  ignored on load so the new default applies). The codec splices the
  blocks into a copy — JPEG APP1 / APP13 / COM, PNG `eXIf` / `iTXt` /
  `tEXt "Raw profile type 8bim"` — pixels untouched, every older EXIF /
  XMP / IPTC / text block of the file replaced. What describes the file
  rather than the photo stays the file's: orientation and pixel size are
  patched in place into the copied EXIF (and XMP `tiff:Orientation`); a
  file stored sideways with no EXIF to write gets one holding only its
  orientation (a constant template); the colour profile and any other
  segment or chunk (MPF, Apple `AROT`…) are the file's own and never
  brought from the photo. The AI mark sets `Iptc4xmpExt:DigitalSourceType`
  in the XMP, updating an existing declaration.
- macOS ImageIO reads no IPTC-IIM from a PNG (not even from its own
  conversions): the IIM-only fields are in the file, readable by exiftool,
  but Preview does not show them.
- Dates in tooltips follow the system's language (`photo_metadata_text`
  writes them with `localDate` / `localClock`; `intl` date formats loaded
  in `main` — and in `test/flutter_test_config.dart` for tests). The rest
  of the UI stays English.
- Small images reach the server untouched, EXIF included: stripping
  metadata on send is not done yet.

## Message stats and export

Everything measured while a message is produced is stored with it, once,
in `messages.stats` (`MessageStats`, JSON) — never recomputed, so a turn's
numbers survive restarts and later settings changes.

- `GenerationStats` (assistant turn): model and endpoint as the
  `ILlmService` sends them (`llm.model` / `llm.endpoint`), the sampling
  parameters or image options actually sent (from the `RequestProfile`),
  `requestContextId`, retry number, `startedAt` (UTC, ms), `durationMs`,
  `firstTokenMs`, `firstAnswerMs` (first non-reasoning output),
  `fragments`, `promptTokens` / `completionTokens` (`null` without
  `usage`), `outcome` (`completed` / `cancelled` / `failed` +
  `error` / `interrupted`), and `server`: what the server said besides the
  deltas, verbatim (`usage` with details, `finish_reason`, llama.cpp
  `timings`, the envelope of the first chunk). Derived values
  (`generationMs`, `reasoningMs`, `outputTokensPerSecond`,
  `finishReason`) are getters in `GenerationStatsX`, never stored.
- `GenerationRecorder` (application) measures a turn from the moment the
  request is sent; the `StreamingPersister` writes its `snapshot()` on
  every placeholder upsert (outcome `interrupted`, what stays after a
  crash) and closes it in `commit()` / `commitPartial(outcome)`. The
  message's `completionTokens` / `durationMs` columns mirror it — also for
  a stopped or failed turn — and are what every reader uses.
- `ServerReport` is the stream event behind `server`: `LlmService` emits
  the first chunk's envelope once, then only chunks that say something
  beyond their deltas; `null` values are skipped.
- `RequestContext` (`request_contexts`, `IConversationRepository`): the
  system prompt as sent (`ChatSessionDeps.mergedSystemPrompt`, MCP
  instructions included) and the definitions of the tools offered (icons
  stripped). The row id is the fingerprint of its content (sha256) and
  the primary key is `(conversation_id, id)`, so storing the same context
  again stores nothing and returns the same id — no session state, no
  duplicates after a restart. An image request carries neither, so it
  records none.
- `ToolCallStats` (tool result): `startedAt`, `durationMs` of the MCP
  call (also in the message's `durationMs`), server id and name. The
  result's `rawResponse` is the server's whole answer —
  `structuredContent`, `_meta`, per-item annotations, unknown fields
  (`McpToolResult.extra`, `McpContent.raw`) — with image bytes replaced
  by `"attachment:<attachmentId>"`.
- A tool call is never lost: `StreamAccumulator.toolCalls` is a list in
  arrival order (the server's `index` only maps to the call it
  continues), a call the server gave no id gets one
  (`ToolCallAccumulator.callId`), and a fragment carrying another id than
  the call at its index starts a new call. Each result is written as soon
  as its call returns — a turn whose calls are not all answered is then
  left out of later requests (`OpenAiCodec` skips it with its results,
  like one whose arguments never parsed).
- The stats line under a reply is a row of icons, not words
  (`_Stat` in `message_bubble.dart`): ↑ what the request carried
  (`Message.promptTokens`, the whole context — `null` without a `usage`
  report, and the arrow is then left out), ↓ what came back, the
  duration, the speed, then Σ tokens and Σ time for the run, the outcome
  when it is not `completed`, and the clock. The tooltip spells every one
  of them out in words — it is the legend for the icons — and ends with
  what the run weighs when there is more than this turn in it.
- That line ends with **when it was generated**
  (`Message.generatedAt`: `GenerationStats.startedAt`, else the row's
  `createdAt`), in the computer's time zone and the system's language:
  the clock alone for today, the day added earlier this year, the year
  too before that; the tooltip opens with the whole moment.
  `presentation/ui/widgets/local_time_text.dart` is the one place a date
  is written — `systemLocaleOf` (the platform locale, since
  `Localizations.localeOf` is always English), `intlLocale`, and the
  `DateFormat`s themselves, built once per locale because this line is
  rebuilt on every streaming tick. The photo metadata dates go through
  it too.
- `Message.tokensPerSecond` (`MessageMeasuresX`, next to
  `MessageContentX`)
  is the one speed shown and exported: `outputTokensPerSecond` (tokens
  over the time after the first token) when stats exist,
  `overallTokensPerSecond` for older replies. The bubble's tooltip shows
  the recorded details. `totalsOf` (`application/conversations/
  conversation_runs.dart`) is the one place these sums are written: the
  export's per-run totals and the Σ under a reply
  (`cumulativeRunTotals`, the same fold stopped at each turn) are one
  arithmetic, not two copies of it. Σ ↑ counts the context every turn
  resent — what the run cost, not what its last request carried.
  `formatTokens` (`presentation/ui/widgets/token_text.dart`) is the one
  place a token count is written short (`25.2K`), on the line and on the
  header's context gauge alike; the exact figure stays in the tooltip.

Export: "Export (JSON)" in a conversation's menu (left sidebar) →
`ConversationController.export` → `ConversationExporter` → `IFileSaver`
(`DesktopFileSaver`, which `DesktopImageIo.saveImage` also goes
through). The history is loaded only once a location is chosen and
encoded straight to UTF-8. `buildConversationExport` (pure) writes every
message and block as stored (`toJson`, with the times in UTC,
`runtimeType` renamed `type`, a tool result's `rawResponse` decoded and
an image's bytes as `base64`), each message's `derived` values, a
`summary` (totals, outcomes, per model: turns, tokens, decoding speed,
time to first token), `runs` (one per user message: turns, tool calls,
Σ, tool time, wall clock), the `requestContexts` its turns reference, the
current settings, and a `guide` explaining the app, the tool loop, what
the model is actually sent (keep it in step with
`OpenAiCodec.buildMessages`) and how to read the file — which is meant
for someone, or some model, that knows nothing of SpecterChat. Auto-correction messages are
flagged (`autoCorrection`). Never exported: the API key and MCP server
headers. Messages written before v9 have no stats: only their token count
and duration.

## Image models

The server list (`GET /models`) is parsed into `ModelInfo` by
`OpenAiCodec.parseModelInfo`: an entry whose `generation.kind == "image"`
carries an `ImageModelInfo` (backend, device, `capabilities`, `defaults`,
all with built-in fallbacks); anything else is a text LLM.
`ModelCatalogNotifier.refresh()` runs the fetch (startup, base URL / key
change debounced behind the typing, refresh button — not on model
selection) and merges the image entries into `IModelCatalogStore` (`SharedPreferencesModelCatalogStore`,
its own key); `selectedImageModelProvider` reads that cache — so the
panel is right at startup, before any fetch.

Settings: `ImageSettings` (all fields nullable = server default) lives in
`AppSettings.image` (global default) and `ConversationSettings.image`
(override), merged by `EffectiveSettings.image`; same optimistic-mirror +
debounced write as `generation`. The panel writes plain values and
`ImageSettings.normalised(defaults)` folds anything equal to the server
default back to `null` in one place, so `isDefault` / Reset and the request
payload stay honest. No schema bump: the conversation column is JSON.

Request: `requestProfileProvider` yields an `ImageRequestProfile` for an
image model; `OpenAiCodec.requestBody` then emits
`{model, messages, stream, generation: {...}}` only —
`imageOptionsToApi` gives the overridden fields in snake_case (`mode`
`auto` is omitted); sampling parameters, the system message and tools are
left out. A `TextRequestProfile` is the usual body.

UI: `SettingsPanel` shows `ImageSettingsSection` instead of Generation /
Context Length / System Prompt / MCP Servers for an image model (the
server ignores all of those); API Connection and About stay. Controls:
Mode (Edit greyed when `capabilities.referenceEdit` is false), Aspect
ratio, Size (filtered by `maxSide`), Steps, Seed, Guidance + Negative
prompt, Transparent background (greyed without `rgba`), Reset; the caption
is "backend · device · instruction editing: yes/no · transparency: yes/no".

The server runs a single backend (Qwen's native diffusers pipeline) and
does not rewrite prompts: there is no img2img strength, edit method,
backend picker or prompt-rewriting switch. Unknown keys in `generation`
(older servers, e.g. `pool`, `img2img`, `brain`) and in persisted
`ImageSettings` JSON (`strength`, `enhance`, `editMode`, `backend`) are
ignored on load.

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
