import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// UUIDv7 — the lexicographic id order equals insertion order. The app
/// relies on this as the canonical message/attachment ordering key.
String generateId() => _uuid.v7();
