import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/core/id_gen.dart';

void main() {
  group('generateId (UUIDv7)', () {
    test('returns RFC 9562 UUIDv7 shape', () {
      expect(
        generateId(),
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('ids are globally unique', () {
      final ids = {for (var i = 0; i < 5000; i++) generateId()};
      expect(ids.length, 5000);
    });

    test('ids minted back-to-back sort in creation order', () {
      // Thousands in a row necessarily share milliseconds — the counter in
      // `rand_a` is what keeps them ordered. `ORDER BY id` everywhere in
      // the app depends on this.
      final ids = List.generate(5000, (_) => generateId());
      for (var i = 1; i < ids.length; i++) {
        expect(
          ids[i].compareTo(ids[i - 1]),
          greaterThan(0),
          reason: 'id #$i must sort after id #${i - 1}',
        );
      }
    });

    test(
      'ids generated in distinct milliseconds sort lexicographically',
      () async {
        final first = generateId();
        await Future<void>.delayed(const Duration(milliseconds: 2));
        final second = generateId();
        expect(second.compareTo(first), greaterThan(0));
      },
    );
  });

  group('MonotonicUuidV7', () {
    test('survives a 12-bit counter overflow within one millisecond', () {
      final gen = MonotonicUuidV7();
      final ids = List.generate(0x1000 + 10, (_) => gen.next());
      expect(ids.toSet().length, ids.length);
      for (var i = 1; i < ids.length; i++) {
        expect(ids[i].compareTo(ids[i - 1]), greaterThan(0));
      }
    });
  });
}
