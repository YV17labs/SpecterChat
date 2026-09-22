/// How a measure is written short, in the one place they are written:
/// the stats line under a reply, the context gauge, a tool result's
/// weight. The exact figure belongs in the tooltip next to them.
library;

/// Tokens: exact below a thousand, in thousands above it.
String formatTokens(int tokens) {
  if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(1)}K';
  return tokens.toString();
}

/// A weight, in the units a file manager uses (1 KB = 1000 B), so what
/// the app says of an image matches what the Finder says of the file.
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000000) return '${(bytes / 1000).round()} KB';
  return '${(bytes / 1000000).toStringAsFixed(1)} MB';
}

/// A duration, to a tenth of a second.
String formatSeconds(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';
