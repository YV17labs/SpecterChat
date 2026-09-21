import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/images/annotation_prompt.dart';
import 'package:specterchat/domain/models/annotation.dart';

void main() {
  test('annotationPromptTemplate names the colours used, in order', () {
    expect(annotationPromptTemplate(Annotation.empty), '');
    const one = Annotation(
      shapes: [
        AnnotationShape.rectangle(
          rect: NRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75),
          color: AnnotationColor.red,
        ),
      ],
    );
    expect(annotationPromptTemplate(one), 'In the red area: ');
    const two = Annotation(
      shapes: [
        AnnotationShape.freehand(
          points: [NPoint(0, 0)],
          color: AnnotationColor.green,
        ),
        AnnotationShape.ellipse(
          rect: NRect(left: 0, top: 0, right: 1, bottom: 1),
          color: AnnotationColor.blue,
        ),
        // A second green shape does not repeat the colour.
        AnnotationShape.freehand(
          points: [NPoint(1, 1)],
          color: AnnotationColor.green,
        ),
        AnnotationShape.mask(points: [NPoint(0, 0)]),
      ],
    );
    expect(
      annotationPromptTemplate(two),
      'In the green area: \nIn the blue area: ',
    );
  });

  test('a mask-only annotation refers to the masked area', () {
    const maskOnly = Annotation(
      shapes: [
        AnnotationShape.mask(points: [NPoint(0, 0)]),
      ],
    );
    expect(annotationPromptTemplate(maskOnly), 'In the masked area: ');
  });
}
