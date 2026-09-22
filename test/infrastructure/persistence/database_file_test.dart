import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/infrastructure/persistence/database.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('specter-db');
    file = File('${dir.path}/specter.db');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  List<String> names() =>
      [for (final e in dir.listSync()) e.path.split('/').last]..sort();

  /// Stamps the file the way a build of that schema would have left it.
  Future<void> stamp(int version) async {
    final handle = await file.open(mode: FileMode.append);
    await handle.setPosition(60);
    await handle.writeFrom(
      Uint8List(4)..buffer.asByteData().setUint32(0, version),
    );
    await handle.close();
  }

  /// A database holding one conversation, left at [version].
  Future<void> write(int version) async {
    final db = AppDatabase.forTesting(NativeDatabase(file));
    await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: 'c',
            title: 'Kept chat',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        );
    await db.close();
    await stamp(version);
  }

  test('no file, or one this build already knows, is left alone', () async {
    await prepareDatabaseFile(file);
    expect(file.existsSync(), isFalse);

    await write(kSchemaVersion);
    await prepareDatabaseFile(file);
    expect(names(), ['specter.db']);
  });

  test('a file this build would migrate is copied first', () async {
    await write(8);
    await prepareDatabaseFile(file);

    final backup = File('${file.path}.v8.backup');
    expect(names(), ['specter.db', 'specter.db.v8.backup']);
    expect(backup.readAsBytesSync(), file.readAsBytesSync());
    expect(await databaseFileVersion(backup), 8);
  });

  test('the copy of a version is made once', () async {
    await write(8);
    await prepareDatabaseFile(file);
    final backup = File('${file.path}.v8.backup');
    final first = backup.lastModifiedSync();

    // Opened again before it could be migrated: the copy stays the one
    // taken from the untouched file.
    await stamp(8);
    await prepareDatabaseFile(file);
    expect(backup.lastModifiedSync(), first);
  });

  test('a file from a later build is set aside, not rewritten', () async {
    await write(kSchemaVersion + 1);
    await prepareDatabaseFile(file);

    expect(file.existsSync(), isFalse, reason: 'the app starts on a new one');
    final aside = File('${file.path}.v${kSchemaVersion + 1}.newer');
    expect(await databaseFileVersion(aside), kSchemaVersion + 1);

    // Its rows are untouched: nothing rewrote the history it did not know.
    final kept = AppDatabase.forTesting(NativeDatabase(aside));
    final conversation = await kept.select(kept.conversations).getSingle();
    expect(conversation.title, 'Kept chat');
    await kept.close();
  });
}
