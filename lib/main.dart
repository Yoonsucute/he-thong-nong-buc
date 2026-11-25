import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'l10n/app_strings.dart';
import 'screens/dashboard_screen.dart';
import 'services/api_service.dart';
import 'theme/app_theme.dart';

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    this.api,
    this.autoRefresh = true,
    this.loadMapTiles = true,
    this.mapTileProvider,
    this.initialThemeMode = ThemeMode.system,
    this.initialLanguage = AppLanguage.vi,
  });

  final ApiService? api;
  final bool autoRefresh;
  final bool loadMapTiles;
  final TileProvider? mapTileProvider;
  final ThemeMode initialThemeMode;
  final AppLanguage initialLanguage;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final AppSettingsController _settings;

  @override
  void initState() {
    super.initState();
    _settings = AppSettingsController(
      themeMode: widget.initialThemeMode,
      language: widget.initialLanguage,
    );
  }

  @override
  void didUpdateWidget(covariant MyApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialThemeMode != oldWidget.initialThemeMode) {
      _settings.setThemeMode(widget.initialThemeMode);
    }
    if (widget.initialLanguage != oldWidget.initialLanguage) {
      _settings.setLanguage(widget.initialLanguage);
    }
  }

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppScope(
    controller: _settings,
    child: AnimatedBuilder(
      animation: _settings,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'HeatWatch · Giám sát nóng bức',
        themeMode: _settings.themeMode,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeAnimationDuration: const Duration(milliseconds: 260),
        home: DashboardScreen(
          api: widget.api,
          autoRefresh: widget.autoRefresh,
          loadMapTiles: widget.loadMapTiles,
          mapTileProvider: widget.mapTileProvider,
        ),
      ),
    ),
  );
}
