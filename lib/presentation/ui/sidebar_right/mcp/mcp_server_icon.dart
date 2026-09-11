import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme.dart';
import '../../../../domain/models/app_settings.dart';

/// Server icon with a connection-status dot. Falls back to a generic
/// server glyph when the server ships no usable icon.
class McpServerIcon extends StatelessWidget {
  final List<McpIcon> icons;
  final bool connected;
  final bool connecting;

  const McpServerIcon({
    super.key,
    required this.icons,
    required this.connected,
    this.connecting = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconWidget = _resolveIconWidget(context, icons);
    final base = iconWidget != null
        ? SizedBox.square(dimension: 20, child: iconWidget)
        : Icon(
            Icons.dns_outlined,
            size: 18,
            color: context.specterStyles.textMuted,
          );

    return Tooltip(
      message: connecting
          ? 'Connecting…'
          : connected
          ? 'Connected'
          : 'Disconnected',
      child: SizedBox(
        width: 22,
        height: 22,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: Center(child: base)),
            Positioned(
              right: -2,
              bottom: -2,
              child: connecting
                  ? const SizedBox.square(
                      dimension: 9,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  : _StatusDot(connected: connected),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool connected;

  const _StatusDot({required this.connected});

  @override
  Widget build(BuildContext context) {
    final color = connected ? const Color(0xFF22C55E) : const Color(0xFF6B7280);
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.surface,
          width: 1.5,
        ),
        boxShadow: connected
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.6),
                  blurRadius: 4,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
    );
  }
}

/// Picks the icon whose `theme` matches the current brightness, else the
/// first one, and returns a renderable widget — or `null` if none is
/// usable.
Widget? _resolveIconWidget(BuildContext context, List<McpIcon> icons) {
  if (icons.isEmpty) return null;
  final wantedTheme = Theme.of(context).brightness == Brightness.dark
      ? 'dark'
      : 'light';
  final match = icons.firstWhere(
    (i) => i.theme == wantedTheme,
    orElse: () => icons.first,
  );
  return _widgetFromIcon(match);
}

/// Branches on mimeType because Flutter's core `Image` widget decodes only
/// raster formats (PNG/JPEG/WebP/BMP). SVG data URIs must go through
/// `flutter_svg` or they crash the image pipeline.
Widget? _widgetFromIcon(McpIcon icon) {
  final src = icon.src;

  if (src.startsWith('data:')) {
    final cached = _DecodedIconCache.instance.get(src);
    if (cached == null) return null;
    final mime = (icon.mimeType ?? cached.mimeType).toLowerCase();
    if (mime.contains('svg')) {
      return SvgPicture.memory(
        cached.bytes,
        placeholderBuilder: (_) => const SizedBox.shrink(),
      );
    }
    return Image.memory(
      cached.bytes,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }

  if (src.startsWith('http://') || src.startsWith('https://')) {
    final mime = (icon.mimeType ?? '').toLowerCase();
    final isSvg = mime.contains('svg') || src.toLowerCase().endsWith('.svg');
    if (isSvg) {
      return SvgPicture.network(
        src,
        placeholderBuilder: (_) => const SizedBox.shrink(),
      );
    }
    return Image.network(
      src,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
  return null;
}

class _DecodedIcon {
  final Uint8List bytes;
  final String mimeType;

  const _DecodedIcon(this.bytes, this.mimeType);
}

/// Bounded LRU cache for decoded icon data URIs. Without a cap, a
/// long-running app that connects to many MCP servers would hold every
/// icon forever. `LinkedHashMap` keeps insertion order; on each hit the
/// entry is re-inserted to move it to the "most recent" slot.
class _DecodedIconCache {
  static final instance = _DecodedIconCache();
  static const _maxEntries = 64;

  final _entries = <String, _DecodedIcon>{};

  _DecodedIcon? get(String src) {
    final hit = _entries.remove(src);
    if (hit != null) {
      _entries[src] = hit;
      return hit;
    }
    final decoded = _decode(src);
    if (decoded == null) return null;
    _entries[src] = decoded;
    if (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return decoded;
  }

  static _DecodedIcon? _decode(String src) {
    try {
      final data = UriData.parse(src);
      return _DecodedIcon(data.contentAsBytes(), data.mimeType);
    } on FormatException {
      return null;
    }
  }
}
