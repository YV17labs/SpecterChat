import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../../application/chat/chat_session.dart';
import '../../../application/images/annotation_prompt.dart';
import '../../../application/images/outgoing_images.dart';
import '../../../application/images/pending_image.dart';
import '../../../core/image_mime.dart';
import '../../../domain/models/annotation.dart';
import '../../../domain/models/message.dart' show OutgoingImage;
import '../../../domain/models/photo_metadata.dart';
import '../../../domain/services/i_image_io.dart' show ImageFileSource;
import '../../providers/chat_input_provider.dart';
import '../../providers/composer_provider.dart';
import '../../providers/image_providers.dart';
import '../../providers/image_reuse_provider.dart';
import 'annotation/annotation_editor.dart';
import 'chat_input_area.dart';

final _log = Logger('ChatComposer');

/// The message being written: text field, pending images and every way
/// an image gets in (attach dialog, paste, drop, "annotate & reuse").
///
/// Owns the text controller and focus; the pending images live in
/// `composerProvider` so they survive rebuilds and can be driven by the
/// drop zone around the whole panel ([attachFiles]). Sending expands the
/// annotations and hands the message to [session].
class ChatComposer extends ConsumerStatefulWidget {
  final String conversationId;
  final ChatSession session;
  final bool isGenerating;

  /// Fired after a send is accepted, so the list can jump to the bottom.
  final VoidCallback onSent;

  const ChatComposer({
    super.key,
    required this.conversationId,
    required this.session,
    required this.isGenerating,
    required this.onSent,
  });

  @override
  ConsumerState<ChatComposer> createState() => ChatComposerState();
}

class ChatComposerState extends ConsumerState<ChatComposer> {
  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();

  ComposerNotifier get _composer =>
      ref.read(composerProvider(widget.conversationId).notifier);

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  // --- Text ------------------------------------------------------------

  void _appendToInput(String text) {
    final current = _inputController.text;
    final separator = current.isEmpty || current.endsWith('\n') ? '' : '\n';
    _inputController.text = '$current$separator$text';
    _inputController.selection = TextSelection.collapsed(
      offset: _inputController.text.length,
    );
    _inputFocusNode.requestFocus();
  }

  void _insertAtCaret(String text) {
    final value = _inputController.value;
    final sel = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = sel.start.clamp(0, value.text.length);
    final end = sel.end.clamp(start, value.text.length);
    _inputController.value = TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  // --- Sending ---------------------------------------------------------

  void _send() {
    final text = _inputController.text.trim();
    final images = _composer.take();
    if (text.isEmpty && images.isEmpty) return;
    _inputController.clear();
    widget.onSent();
    unawaited(_expandAndSend(text, images));
  }

  /// Renders annotated copies / masks (an async engine round-trip), then
  /// hands the message to the session. The composer was already cleared so
  /// the user can keep typing; on a rendering failure the draft comes back.
  Future<void> _expandAndSend(String text, List<PendingImage> images) async {
    List<OutgoingImage> outgoing;
    try {
      outgoing = await expandPendingImages(
        images,
        renderer: ref.read(annotationRendererProvider),
      );
    } catch (e, st) {
      _log.warning('Failed to render annotated images', e, st);
      if (!mounted) return;
      _composer.restore(images);
      _inputController.text = text;
      _notify('Could not render the annotated image');
      return;
    }
    // Not awaited: the turn can run for minutes and nothing here needs
    // its end, so the frame (and the draft it holds) is released now.
    unawaited(widget.session.sendMessage(text, images: outgoing));
  }

  // --- Images ----------------------------------------------------------

  /// Queue [bytes], telling the user when the composer refused them.
  /// Returns the new pending image's id, or `null`.
  Future<String?> _attach(
    Uint8List bytes, {
    required String name,
    PhotoMetadata? metadata,
  }) async {
    final result = await _composer.attach(
      bytes,
      name: name,
      metadata: metadata,
    );
    if (!mounted) return null;
    switch (result) {
      case Attached(:final id):
        _inputFocusNode.requestFocus();
        return id;
      case NoRoomForImage():
        _notify('At most $kMaxPendingImages images per message');
      case UnsupportedImage():
        _notifyUnsupported(name);
    }
    return null;
  }

  void _notifyUnsupported(String name) => _notify('Not an image: $name');

  /// Attach every file in [files]. Used by the attach dialog and by the
  /// drop zone in `ChatView`. The extension check is only a guard against
  /// reading something huge that was never an image (a dropped video); the
  /// normaliser's magic-byte check is what decides.
  Future<void> attachFiles(Iterable<ImageFileSource> files) async {
    for (final file in files) {
      final ext = file.name.split('.').last.toLowerCase();
      if (file.name.contains('.') && !kImageExtensions.contains(ext)) {
        _notifyUnsupported(file.name);
        continue;
      }
      try {
        await _attach(await file.read(), name: file.name);
      } catch (e) {
        _log.warning('Failed to read ${file.name}', e);
        _notify('Could not read ${file.name}');
      }
      if (!mounted) return;
    }
  }

  Future<void> _pickImages() async {
    final files = await ref.read(imageIoProvider).pickImages();
    if (!mounted) return;
    await attachFiles(files);
  }

  /// Cmd/Ctrl+V: an image on the clipboard is attached; otherwise the
  /// text is inserted at the caret (the key event was consumed, so the
  /// field's own paste no longer runs).
  Future<void> _pasteFromClipboard() async {
    Uint8List? image;
    try {
      image = await ref.read(imageIoProvider).readClipboardImage();
    } catch (e) {
      _log.fine('Clipboard image read failed', e);
    }
    if (!mounted) return;
    if (image != null) {
      await _attach(image, name: 'Pasted image');
      return;
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted || text == null || text.isEmpty) return;
    _insertAtCaret(text);
  }

  /// Opens the annotation editor on a pending image and stores the result
  /// on it (rendering happens at send time, see [_expandAndSend]).
  Future<void> _editImage(String id) async {
    final composer = _composer;
    final image = composer.find(id);
    if (image == null) return;
    final applied = image.annotation;
    final result = await showAnnotationEditor(
      context,
      imageBytes: image.bytes,
      initial: applied?.annotation ?? Annotation.empty,
      includeMask: applied?.includeMask ?? false,
      keepOriginal: applied?.keepOriginal ?? false,
      freeSlots: composer.freeSlotsFor(id),
      title: image.name,
    );
    if (!mounted || result == null) return;
    composer.applyAnnotation(id, result);
    if (_inputController.text.trim().isEmpty) {
      final template = annotationPromptTemplate(result.annotation);
      if (template.isNotEmpty) _inputController.text = template;
    }
    _inputFocusNode.requestFocus();
  }

  /// "Annotate & reuse" on an image in the conversation: attach a copy and
  /// open the editor on it.
  Future<void> _reuseImage(ImageReuseRequest request) async {
    final id = await _attach(
      request.bytes,
      name: 'Reused image',
      metadata: request.metadata,
    );
    if (!mounted || id == null) return;
    await _editImage(id);
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(chatInputInjectionProvider, (_, next) {
      if (next == null || next.isEmpty) return;
      _appendToInput(next);
      ref.read(chatInputInjectionProvider.notifier).consume();
    });
    ref.listen<ImageReuseRequest?>(imageReuseProvider, (_, next) {
      if (next == null) return;
      ref.read(imageReuseProvider.notifier).consume();
      unawaited(_reuseImage(next));
    });
    final pendingImages = ref.watch(composerProvider(widget.conversationId));
    return ChatInputArea(
      controller: _inputController,
      focusNode: _inputFocusNode,
      isGenerating: widget.isGenerating,
      pendingImages: pendingImages,
      onSend: _send,
      onStop: () => widget.session.stop().ignore(),
      onAttach: () => unawaited(_pickImages()),
      onRemoveImage: _composer.remove,
      onEditImage: (id) => unawaited(_editImage(id)),
      onPaste: () => unawaited(_pasteFromClipboard()),
    );
  }
}
