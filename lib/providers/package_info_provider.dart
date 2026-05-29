import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Exposes the running app's bundle metadata (name, version, build number).
///
/// Read from the platform bundle at runtime, which is populated from the
/// `version` field in `pubspec.yaml` at build time — so the About section
/// always reflects the current version without any manual edits.
final packageInfoProvider = FutureProvider<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
});
