import '../../domain/services/i_link_opener.dart';

/// The link behind [href] if the app should open it, else `null`.
///
/// What a conversation shows was written by a model or returned by an MCP
/// server, neither of which the user vouches for: a `file:` link or an
/// application's own scheme would open, or run, something on this computer
/// the user never asked for. So only a web page or an address.
Uri? followableLink(String? href) {
  final uri = Uri.tryParse(href?.trim() ?? '');
  return switch (uri) {
    Uri(scheme: 'http' || 'https', host: String(isNotEmpty: true)) ||
    Uri(scheme: 'mailto', path: String(isNotEmpty: true)) => uri,
    _ => null,
  };
}

/// Opens a link through [ILinkOpener] when [followableLink] lets it: the
/// one way the UI opens a link.
class LinkFollower {
  final ILinkOpener _opener;

  const LinkFollower(this._opener);

  Future<void> follow(String? href) async {
    if (followableLink(href) case final uri?) await _opener.open(uri);
  }
}
