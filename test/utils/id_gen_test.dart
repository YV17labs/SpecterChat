import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/utils/id_gen.dart';

void main() {
  group('generateId (UUIDv7)', () {
    test('returns RFC 4122 UUIDv7 shape', () {
      final id = generateId();
      expect(
        id,
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });

    test('ids are globally unique', () {
      final ids = {for (var i = 0; i < 1000; i++) generateId()};
      expect(ids.length, 1000);
    });

    test('ids generated in distinct milliseconds sort lexicographically',
        () async {
      // The RFC permits random tail within one ms (no intra-ms counter in
      // this implementation), so strict ordering only holds across ms
      // boundaries. That matches how this app assigns ids: an assistant's
      // streaming-message id is minted at stream start, its tool-result
      // ids are minted later after tool execution — always on a later ms.
      final first = generateId();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final second = generateId();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final third = generateId();
      expect(second.compareTo(first), greaterThan(0));
      expect(third.compareTo(second), greaterThan(0));
    });
  });
}
