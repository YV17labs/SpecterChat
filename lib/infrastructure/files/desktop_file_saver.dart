import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import '../../domain/services/i_file_saver.dart';

/// [IFileSaver] on `file_selector`. macOS needs the
/// `files.user-selected.read-write` entitlement.
class DesktopFileSaver implements IFileSaver {
  const DesktopFileSaver();

  @override
  Future<bool> save({
    required String suggestedName,
    required String typeLabel,
    required String extension,
    required String mimeType,
    required Future<Uint8List> Function() contents,
  }) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: [
        XTypeGroup(label: typeLabel, extensions: [extension]),
      ],
    );
    if (location == null) return false;
    await XFile.fromData(
      await contents(),
      mimeType: mimeType,
    ).saveTo(location.path);
    return true;
  }
}
