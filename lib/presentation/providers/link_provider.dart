import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/links/link_follower.dart';
import '../../domain/services/i_link_opener.dart';
import '../../infrastructure/links/system_link_opener.dart';

/// Opens any link in the system. Override in tests to record what was
/// opened; the UI uses [linkFollowerProvider].
final linkOpenerProvider = Provider<ILinkOpener>(
  (_) => const SystemLinkOpener(),
);

/// Opens the links the app may follow, in the system's browser.
final linkFollowerProvider = Provider<LinkFollower>(
  (ref) => LinkFollower(ref.watch(linkOpenerProvider)),
);
