import 'package:flutter/material.dart';

class AppTheme {
  static const libraryBackground = Color(0xFF1E1E20);
  static const Color _seed = Color(0xFF7C4DFF);

  static ThemeData dark() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: libraryBackground,
      appBarTheme: AppBarTheme(
        backgroundColor: libraryBackground,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: colorScheme.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: libraryBackground,
        indicatorColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? Colors.white
                : Colors.white54,
            size: 28,
          ),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      searchBarTheme: const SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(Color(0xFF1C1C21)),
        elevation: WidgetStatePropertyAll(0),
        hintStyle: WidgetStatePropertyAll(TextStyle(color: Color(0xFF8A8A93))),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF16161A),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(iconColor: colorScheme.onSurfaceVariant),
      dividerTheme: const DividerThemeData(color: Color(0xFF232329)),
    );
  }
}
