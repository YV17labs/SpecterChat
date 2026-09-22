/// Tokens as the UI writes them, in the one place that writes them: short
/// enough for a caption line or the context gauge, exact below a thousand
/// and in thousands above it. The figure itself stays in the tooltip.
String formatTokens(int tokens) {
  if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(1)}K';
  return tokens.toString();
}
