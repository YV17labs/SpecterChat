import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// UUIDv7 — RFC 9562 time-ordered UUIDs. The first 48 bits encode a
/// millisecond-precision Unix timestamp, so lexicographic id ordering is
/// equivalent to insertion order.
///
/// The rest of the codebase relies on this property: message and
/// attachment rows are stored ordered by id (`ORDER BY id`) instead of
/// `createdAt`, avoiding the second-precision tie-break ambiguity of
/// Drift's default DateTime storage.
String generateId() => _uuid.v7();
