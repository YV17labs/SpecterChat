import '../../domain/models/annotation.dart';

/// Linear undo/redo over immutable [Annotation] snapshots.
///
/// Every mutation goes through [push], which records the previous state
/// and drops any redo branch — the usual editor semantics. The class is a
/// value: operations return a new history rather than mutating in place,
/// so a widget can hold it in state and compare instances.
class AnnotationHistory {
  final List<Annotation> _past;
  final Annotation present;
  final List<Annotation> _future;

  /// Upper bound on remembered undo steps; older snapshots fall off.
  static const int maxDepth = 200;

  const AnnotationHistory._(this._past, this.present, this._future);

  const AnnotationHistory.initial([Annotation start = Annotation.empty])
    : this._(const [], start, const []);

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  /// Records [next] as the current state. A no-op when [next] equals the
  /// present state, so accidental empty edits do not pollute the stack.
  AnnotationHistory push(Annotation next) {
    if (next == present) return this;
    final past = [..._past, present];
    if (past.length > maxDepth) past.removeAt(0);
    return AnnotationHistory._(past, next, const []);
  }

  AnnotationHistory undo() {
    if (!canUndo) return this;
    return AnnotationHistory._(_past.sublist(0, _past.length - 1), _past.last, [
      present,
      ..._future,
    ]);
  }

  AnnotationHistory redo() {
    if (!canRedo) return this;
    return AnnotationHistory._(
      [..._past, present],
      _future.first,
      _future.sublist(1),
    );
  }
}
