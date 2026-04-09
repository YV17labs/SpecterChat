import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// Color palette extracted from the Zed editor "One Dark" theme.
///
/// These constants are kept private to the theme layer. UI code should
/// reach for `Theme.of(context).colorScheme` rather than referencing them
/// directly, so swapping themes later only requires editing this file.
class _OneDark {
  // Backgrounds (from darkest to lightest)
  static const titleBar = Color(0xFF1D2025);
  static const panel = Color(0xFF21252B);
  static const editor = Color(0xFF282C34);
  static const elevated = Color(0xFF2C313A);
  static const elevatedHigh = Color(0xFF323842);
  static const border = Color(0xFF3E4451);

  // Foregrounds
  static const text = Color(0xFFABB2BF);
  static const textMuted = Color(0xFF828997);
  static const textDim = Color(0xFF5C6370);

  // Syntax accents
  static const purple = Color(0xFFC678DD); // keywords
  static const blue = Color(0xFF61AFEF); // functions
  static const yellow = Color(0xFFE5C07B); // strings
  static const red = Color(0xFFE06C75); // error
}

/// App-specific styles that don't fit into Material's `ColorScheme`.
///
/// Centralised so widgets never hard-code colors or decorations.
/// Access via `context.specterStyles`.
@immutable
class SpecterStyles extends ThemeExtension<SpecterStyles> {
  final BoxDecoration toolResultGroupDecoration;
  final BoxDecoration expandableBlockDecoration;
  final BoxDecoration thinkingBlockDecoration;
  final BoxDecoration blockquoteDecoration;
  final TextStyle blockquoteTextStyle;
  final EdgeInsetsGeometry blockquotePadding;
  final BorderSide sidebarBorderSide;
  final MarkdownStyleSheet markdownStyleSheet;

  const SpecterStyles({
    required this.toolResultGroupDecoration,
    required this.expandableBlockDecoration,
    required this.thinkingBlockDecoration,
    required this.blockquoteDecoration,
    required this.blockquoteTextStyle,
    required this.blockquotePadding,
    required this.sidebarBorderSide,
    required this.markdownStyleSheet,
  });

  @override
  SpecterStyles copyWith({
    BoxDecoration? toolResultGroupDecoration,
    BoxDecoration? expandableBlockDecoration,
    BoxDecoration? thinkingBlockDecoration,
    BoxDecoration? blockquoteDecoration,
    TextStyle? blockquoteTextStyle,
    EdgeInsetsGeometry? blockquotePadding,
    BorderSide? sidebarBorderSide,
    MarkdownStyleSheet? markdownStyleSheet,
  }) {
    return SpecterStyles(
      toolResultGroupDecoration:
          toolResultGroupDecoration ?? this.toolResultGroupDecoration,
      expandableBlockDecoration:
          expandableBlockDecoration ?? this.expandableBlockDecoration,
      thinkingBlockDecoration:
          thinkingBlockDecoration ?? this.thinkingBlockDecoration,
      blockquoteDecoration:
          blockquoteDecoration ?? this.blockquoteDecoration,
      blockquoteTextStyle: blockquoteTextStyle ?? this.blockquoteTextStyle,
      blockquotePadding: blockquotePadding ?? this.blockquotePadding,
      sidebarBorderSide: sidebarBorderSide ?? this.sidebarBorderSide,
      markdownStyleSheet: markdownStyleSheet ?? this.markdownStyleSheet,
    );
  }

  @override
  SpecterStyles lerp(ThemeExtension<SpecterStyles>? other, double t) {
    if (other is! SpecterStyles) return this;
    return SpecterStyles(
      toolResultGroupDecoration: BoxDecoration.lerp(
              toolResultGroupDecoration, other.toolResultGroupDecoration, t) ??
          toolResultGroupDecoration,
      expandableBlockDecoration: BoxDecoration.lerp(
              expandableBlockDecoration, other.expandableBlockDecoration, t) ??
          expandableBlockDecoration,
      thinkingBlockDecoration: BoxDecoration.lerp(
              thinkingBlockDecoration, other.thinkingBlockDecoration, t) ??
          thinkingBlockDecoration,
      blockquoteDecoration: BoxDecoration.lerp(
              blockquoteDecoration, other.blockquoteDecoration, t) ??
          blockquoteDecoration,
      blockquoteTextStyle:
          TextStyle.lerp(blockquoteTextStyle, other.blockquoteTextStyle, t) ??
              blockquoteTextStyle,
      blockquotePadding:
          EdgeInsetsGeometry.lerp(blockquotePadding, other.blockquotePadding, t) ??
              blockquotePadding,
      sidebarBorderSide:
          BorderSide.lerp(sidebarBorderSide, other.sidebarBorderSide, t),
      markdownStyleSheet: t < 0.5 ? markdownStyleSheet : other.markdownStyleSheet,
    );
  }
}

/// Ergonomic accessor: `context.specterStyles.toolResultGroupDecoration`.
extension SpecterStylesX on BuildContext {
  SpecterStyles get specterStyles =>
      Theme.of(this).extension<SpecterStyles>()!;
}

class SpecterTheme {
  /// Default dark theme — Zed "One Dark" palette.
  static ThemeData get darkTheme {
    const colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: _OneDark.purple,
      onPrimary: Color(0xFF1D2025),
      primaryContainer: Color(0xFF4A2D55),
      onPrimaryContainer: Color(0xFFE8C8F0),
      secondary: _OneDark.blue,
      onSecondary: Color(0xFF1D2025),
      secondaryContainer: Color(0xFF1F3A52),
      onSecondaryContainer: Color(0xFFC5E2F7),
      tertiary: _OneDark.yellow,
      onTertiary: Color(0xFF1D2025),
      tertiaryContainer: Color(0xFF504218),
      onTertiaryContainer: Color(0xFFF5E1B0),
      error: _OneDark.red,
      onError: Color(0xFF1D2025),
      errorContainer: Color(0xFF5C2A2E),
      onErrorContainer: Color(0xFFF5C5C8),
      surface: _OneDark.editor,
      onSurface: _OneDark.text,
      surfaceDim: _OneDark.titleBar,
      surfaceBright: _OneDark.elevatedHigh,
      surfaceContainerLowest: _OneDark.titleBar,
      surfaceContainerLow: _OneDark.panel,
      surfaceContainer: _OneDark.panel,
      surfaceContainerHigh: _OneDark.elevated,
      surfaceContainerHighest: _OneDark.elevatedHigh,
      onSurfaceVariant: _OneDark.textMuted,
      outline: _OneDark.border,
      outlineVariant: Color(0xFF2F353F),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: _OneDark.text,
      onInverseSurface: _OneDark.editor,
      inversePrimary: Color(0xFF7B3F8C),
    );

    final baseTheme = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      canvasColor: colorScheme.surface,
      fontFamily: 'Inter',
      textTheme: const TextTheme(
        bodyLarge: TextStyle(fontSize: 14, color: _OneDark.text),
        bodyMedium: TextStyle(fontSize: 14, color: _OneDark.text),
        bodySmall: TextStyle(fontSize: 12, color: _OneDark.textMuted),
        labelLarge: TextStyle(fontSize: 13, color: _OneDark.text),
        labelMedium: TextStyle(fontSize: 12, color: _OneDark.text),
        labelSmall: TextStyle(fontSize: 11, color: _OneDark.textMuted),
        titleLarge: TextStyle(fontSize: 16, color: _OneDark.text),
        titleMedium: TextStyle(fontSize: 14, color: _OneDark.text),
        titleSmall: TextStyle(fontSize: 13, color: _OneDark.text),
      ),
      iconTheme: const IconThemeData(color: _OneDark.text, size: 18),
      appBarTheme: const AppBarTheme(
        backgroundColor: _OneDark.titleBar,
        foregroundColor: _OneDark.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _OneDark.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _OneDark.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _OneDark.blue, width: 1.5),
        ),
        filled: true,
        fillColor: _OneDark.elevatedHigh,
        hintStyle: const TextStyle(color: _OneDark.textDim),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      cardTheme: CardThemeData(
        color: _OneDark.elevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: _OneDark.border),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF2F353F),
        thickness: 1,
        space: 1,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor:
            WidgetStateProperty.all(_OneDark.border.withValues(alpha: 0.8)),
        radius: const Radius.circular(4),
        thickness: WidgetStateProperty.all(6),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _OneDark.purple,
          foregroundColor: const Color(0xFF1D2025),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: _OneDark.blue),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _OneDark.text,
          side: const BorderSide(color: _OneDark.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: _OneDark.titleBar,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: _OneDark.border),
        ),
        textStyle: const TextStyle(color: _OneDark.text, fontSize: 12),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: _OneDark.textMuted,
        textColor: _OneDark.text,
        selectedColor: _OneDark.purple,
        selectedTileColor: Color(0xFF2C313A),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: _OneDark.elevated,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: _OneDark.border),
        ),
        textStyle: const TextStyle(color: _OneDark.text, fontSize: 13),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: _OneDark.editor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: _OneDark.border),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: _OneDark.elevatedHigh,
        contentTextStyle: TextStyle(color: _OneDark.text),
        behavior: SnackBarBehavior.floating,
      ),
    );

    final outlineSubtle = colorScheme.outline.withValues(alpha: 0.3);
    const blockquotePadding =
        EdgeInsets.symmetric(horizontal: 12, vertical: 8);

    final blockquoteDecoration = BoxDecoration(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
      border: Border(
        left: BorderSide(
          color: colorScheme.secondary.withValues(alpha: 0.6),
          width: 3,
        ),
      ),
    );

    final blockquoteTextStyle = TextStyle(
      fontSize: 14,
      color: colorScheme.onSurface.withValues(alpha: 0.75),
      fontStyle: FontStyle.italic,
    );

    final markdownStyleSheet =
        MarkdownStyleSheet.fromTheme(baseTheme).copyWith(
      p: baseTheme.textTheme.bodyMedium,
      code: baseTheme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            backgroundColor: colorScheme.surfaceContainerHighest,
          ),
      codeblockDecoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      blockquote: blockquoteTextStyle,
      blockquoteDecoration: blockquoteDecoration,
      blockquotePadding: blockquotePadding,
    );

    final specterStyles = SpecterStyles(
      toolResultGroupDecoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: outlineSubtle),
      ),
      expandableBlockDecoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: outlineSubtle),
      ),
      thinkingBlockDecoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      blockquoteDecoration: blockquoteDecoration,
      blockquoteTextStyle: blockquoteTextStyle,
      blockquotePadding: blockquotePadding,
      sidebarBorderSide:
          BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
      markdownStyleSheet: markdownStyleSheet,
    );

    return baseTheme.copyWith(extensions: [specterStyles]);
  }
}
