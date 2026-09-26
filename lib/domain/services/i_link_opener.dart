/// Hands a link to the system — whatever application takes its scheme —
/// rather than opening anything in the app. It opens any link as it is:
/// the UI goes through `LinkFollower`, which decides what may be opened.
abstract interface class ILinkOpener {
  Future<void> open(Uri uri);
}
