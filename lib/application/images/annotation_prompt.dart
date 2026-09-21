import '../../domain/models/annotation.dart';

/// The sentence offered in an empty composer after an annotation is
/// applied, naming every colour actually used so the user only has to fill
/// in what should happen in each region. Empty when there is nothing to
/// refer to.
String annotationPromptTemplate(Annotation annotation) {
  final colours = annotation.usedColors;
  if (colours.isEmpty) {
    return annotation.hasMask ? 'In the masked area: ' : '';
  }
  return colours.map((c) => 'In the ${c.label} area: ').join('\n');
}
