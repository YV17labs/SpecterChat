import 'package:url_launcher/url_launcher.dart';

import '../../domain/services/i_link_opener.dart';

/// [ILinkOpener] on `url_launcher`, always outside the app: the default
/// browser or mail client. Needs no entitlement in the macOS sandbox.
class SystemLinkOpener implements ILinkOpener {
  const SystemLinkOpener();

  @override
  Future<void> open(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}
