import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// Process-wide app identity (name, version) resolved once at startup.
///
/// [init] must be awaited in `main()` before `runApp` so every consumer —
/// the `User-Agent` header, the MCP `clientInfo`, the About section — reads
/// the real bundle version. Before [init] (e.g. in unit tests) the accessors
/// fall back to a placeholder version rather than throwing.
class AppInfo {
  AppInfo._();

  static const name = 'SpecterChat';

  static PackageInfo? _info;

  static Future<void> init() async {
    _info = await PackageInfo.fromPlatform();
  }

  /// Semantic version from `pubspec.yaml` (without the build number).
  static String get version => _info?.version ?? 'dev';

  /// Build number from `pubspec.yaml`, or an empty string before [init].
  static String get buildNumber => _info?.buildNumber ?? '';

  /// Human-readable version for the About section and license page.
  static String get versionLabel => '$version (build $buildNumber)';

  /// `User-Agent` sent on every outbound HTTP request, e.g.
  /// `SpecterChat/0.5.0 (macos) Dart/3.13.0`.
  static String get userAgent {
    final dartVersion = Platform.version.split(' ').first;
    return '$name/$version (${Platform.operatingSystem}) Dart/$dartVersion';
  }
}
