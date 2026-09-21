/// Lets queued microtasks and zero-delay timers run — enough for a
/// provider's `build` to finish its async fill-in.
Future<void> settle() => Future<void>.delayed(Duration.zero);
