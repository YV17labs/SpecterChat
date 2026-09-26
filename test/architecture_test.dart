import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Layer rules, enforced on imports:
///
///   core            → nothing app-specific
///   domain          → core
///   application     → core, domain
///   infrastructure  → core, domain, application
///   presentation    → everything
///
/// Plus: `domain` and `application` never import Dio, Drift, Riverpod,
/// SharedPreferences or Flutter widgets — nor `dart:ui`, which is the
/// engine (`flutter/foundation` is tolerated for `ValueNotifier`). Inside
/// presentation, `rendering/` is `dart:ui` code with no
/// widgets, `providers/` never reaches into `ui/`, and `ui/` never touches
/// infrastructure or the desktop plugins directly. Generated files are
/// skipped.
void main() {
  final lib = Directory('lib');

  Iterable<File> dartFiles(String layer) => Directory('lib/$layer')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.endsWith('.g.dart'))
      .where((f) => !f.path.endsWith('.freezed.dart'));

  final importLine = RegExp(r'''^(?:import|export)\s+'([^']+)'\s*;''');

  /// Resolves a relative import to a `lib/`-relative path.
  String resolve(File from, String uri) {
    if (uri.startsWith('package:specterchat/')) {
      return uri.substring('package:specterchat/'.length);
    }
    if (uri.startsWith('package:') || uri.startsWith('dart:')) return uri;
    final dir = from.parent.path.substring(lib.path.length + 1);
    final parts = [...dir.split('/'), ...uri.split('/')];
    final out = <String>[];
    for (final p in parts) {
      if (p == '..') {
        out.removeLast();
      } else if (p != '.' && p.isNotEmpty) {
        out.add(p);
      }
    }
    return out.join('/');
  }

  Map<File, List<String>> imports(String layer) => {
    for (final f in dartFiles(layer))
      f: [
        for (final line in f.readAsLinesSync())
          if (importLine.firstMatch(line) case final m?) resolve(f, m[1]!),
      ],
  };

  void forbid(String layer, bool Function(String import) isForbidden) {
    final violations = <String>[];
    imports(layer).forEach((file, deps) {
      for (final d in deps) {
        if (isForbidden(d)) violations.add('${file.path} → $d');
      }
    });
    expect(violations, isEmpty);
  }

  bool inLayer(String import, String layer) => import.startsWith('$layer/');

  test('core depends on no other layer', () {
    forbid(
      'core',
      (i) => [
        'domain',
        'application',
        'infrastructure',
        'presentation',
      ].any((l) => inLayer(i, l)),
    );
  });

  test('domain depends only on core', () {
    forbid(
      'domain',
      (i) => [
        'application',
        'infrastructure',
        'presentation',
      ].any((l) => inLayer(i, l)),
    );
  });

  test('application depends only on core and domain', () {
    forbid(
      'application',
      (i) => ['infrastructure', 'presentation'].any((l) => inLayer(i, l)),
    );
  });

  test('infrastructure never imports presentation', () {
    forbid('infrastructure', (i) => inLayer(i, 'presentation'));
  });

  test('domain and application are framework-free', () {
    const banned = [
      'package:dio/',
      'package:drift/',
      'package:flutter_riverpod/',
      'package:riverpod',
      'package:shared_preferences/',
      'package:flutter/material.dart',
      'package:flutter/widgets.dart',
      'package:flutter/cupertino.dart',
      'package:flutter/rendering.dart',
      'package:flutter/painting.dart',
      'package:flutter/services.dart',
      'package:mcp_dart/',
      'package:http/',
      'dart:ui',
    ];
    for (final layer in ['domain', 'application']) {
      forbid(layer, (i) => banned.any(i.startsWith));
    }
  });

  test('presentation reaches services only through domain contracts', () {
    // Widgets and providers may build infrastructure objects in providers,
    // but UI code itself must not import infrastructure.
    forbid('presentation/ui', (i) => inLayer(i, 'infrastructure'));
  });

  test('UI never talks to the desktop plugins directly', () {
    // File dialogs and the clipboard go through `IImageIo`, links through
    // `LinkFollower`; the only widget-level plugin is the drop target.
    const plugins = [
      'package:file_selector/',
      'package:pasteboard/',
      'package:url_launcher/',
    ];
    forbid('presentation/ui', (i) => plugins.any(i.startsWith));
  });

  test('presentation/rendering is dart:ui only, no widgets', () {
    forbid(
      'presentation/rendering',
      (i) =>
          i.startsWith('package:flutter/') ||
          i.startsWith('package:flutter_riverpod/') ||
          inLayer(i, 'presentation/ui') ||
          inLayer(i, 'presentation/providers'),
    );
  });

  test('providers never import widgets from ui/', () {
    forbid('presentation/providers', (i) => inLayer(i, 'presentation/ui'));
  });
}
