import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/drawing_session.dart';
import 'package:specterchat/application/images/pending_image.dart';
import 'package:specterchat/domain/models/annotation.dart';
import 'package:specterchat/presentation/providers/composer_provider.dart';
import 'package:specterchat/presentation/providers/image_providers.dart';

import '../../support/fakes.dart';

void main() {
  late ProviderContainer container;
  const id = 'conv';

  setUp(() {
    container = ProviderContainer(
      overrides: [
        imageNormalizerProvider.overrideWithValue(
          const PassThroughImageNormalizer(),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  ComposerNotifier notifier() => container.read(composerProvider(id).notifier);
  List<PendingImage> images() => container.read(composerProvider(id));

  test('attach validates, queues and reports the new id', () async {
    final sub = container.listen(composerProvider(id), (_, _) {});
    addTearDown(sub.close);
    final result = await notifier().attach(fakePngBytes(), name: 'a.png');
    expect(result, isA<Attached>());
    final image = images().single;
    expect(image.id, (result as Attached).id);
    expect(image.name, 'a.png');
    expect(image.mimeType, 'image/png');
    expect(image.isAnnotated, isFalse);
  });

  test('attach refuses unsupported bytes', () async {
    final sub = container.listen(composerProvider(id), (_, _) {});
    addTearDown(sub.close);
    final result = await notifier().attach(
      Uint8List.fromList([1, 2, 3]),
      name: 'x.bin',
    );
    expect(result, isA<UnsupportedImage>());
    expect(images(), isEmpty);
  });

  test('attach refuses once the message is full', () async {
    final sub = container.listen(composerProvider(id), (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < kMaxPendingImages; i++) {
      expect(
        await notifier().attach(fakePngBytes(i), name: '$i'),
        isA<Attached>(),
      );
    }
    expect(notifier().freeSlots, 0);
    expect(
      await notifier().attach(fakePngBytes(99), name: 'one too many'),
      isA<NoRoomForImage>(),
    );
    expect(images(), hasLength(kMaxPendingImages));
  });

  test('remove, applyAnnotation, take and restore', () async {
    final sub = container.listen(composerProvider(id), (_, _) {});
    addTearDown(sub.close);
    final a =
        (await notifier().attach(fakePngBytes(1), name: 'a') as Attached).id;
    final b =
        (await notifier().attach(fakePngBytes(2), name: 'b') as Attached).id;

    const annotation = Annotation(
      shapes: [
        AnnotationShape.mask(points: [NPoint(0.5, 0.5)]),
      ],
    );
    notifier().applyAnnotation(
      a,
      const AnnotationResult(
        annotation: annotation,
        includeMask: true,
        keepOriginal: true,
      ),
    );
    expect(images().first.annotation?.annotation, annotation);
    expect(images().first.outgoingCount, 3);
    expect(notifier().freeSlots, kMaxPendingImages - 4);
    // The editor of `a` may re-use the two slots its extras take.
    expect(notifier().freeSlotsFor(a), kMaxPendingImages - 2);
    expect(notifier().freeSlotsFor(b), kMaxPendingImages - 4);
    expect(notifier().freeSlotsFor('missing'), kMaxPendingImages - 4);

    // An empty annotation clears everything back to plain.
    notifier().applyAnnotation(
      a,
      const AnnotationResult(
        annotation: Annotation.empty,
        includeMask: false,
        keepOriginal: false,
      ),
    );
    expect(images().first.isAnnotated, isFalse);
    expect(images().first.annotation, isNull);

    notifier().remove(b);
    expect(images().map((i) => i.id), [a]);

    final taken = notifier().take();
    expect(taken.map((i) => i.id), [a]);
    expect(images(), isEmpty);

    notifier().restore(taken);
    expect(images().map((i) => i.id), [a]);
  });

  test('drafts are per conversation', () async {
    final sub1 = container.listen(composerProvider('one'), (_, _) {});
    final sub2 = container.listen(composerProvider('two'), (_, _) {});
    addTearDown(sub1.close);
    addTearDown(sub2.close);
    await container
        .read(composerProvider('one').notifier)
        .attach(fakePngBytes(), name: 'a');
    expect(container.read(composerProvider('one')), hasLength(1));
    expect(container.read(composerProvider('two')), isEmpty);
  });
}
