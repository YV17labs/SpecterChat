import 'dart:math';

import 'package:uuid/data.dart';
import 'package:uuid/uuid.dart';

/// UUIDv7 with a monotonic intra-millisecond counter.
///
/// The app uses `ORDER BY id` as the canonical message/attachment order,
/// so ids minted within the same millisecond (parallel tool results, a
/// user message and its placeholder on a fast machine) must still sort in
/// creation order. `package:uuid` fills the 12-bit `rand_a` field with
/// random bits; this generator uses it as a sequence counter instead, as
/// RFC 9562 §6.2 method 1 allows.
class MonotonicUuidV7 {
  MonotonicUuidV7({Random? random}) : _random = random ?? Random();

  static const _uuid = Uuid();
  final Random _random;
  int _lastMs = 0;
  int _seq = 0;

  String next() {
    var now = DateTime.timestamp().millisecondsSinceEpoch;
    if (now > _lastMs) {
      _lastMs = now;
      _seq = 0;
    } else {
      // Same millisecond, or the wall clock moved backwards: keep the
      // previous timestamp and bump the counter. On overflow, borrow one
      // millisecond — still unique and still ordered.
      _seq++;
      if (_seq > 0xFFF) {
        _lastMs++;
        _seq = 0;
      }
      now = _lastMs;
    }
    final bytes = List<int>.generate(10, (_) => _random.nextInt(256));
    // Bytes 0-1 become `rand_a`; the package overlays the version nibble
    // on the high 4 bits of byte 0, leaving 12 bits for the counter.
    bytes[0] = (_seq >> 8) & 0x0F;
    bytes[1] = _seq & 0xFF;
    return _uuid.v7(config: V7Options(now, bytes));
  }
}

final _generator = MonotonicUuidV7();

/// Process-wide id generator. Lexicographic order equals creation order.
String generateId() => _generator.next();
