import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../l10n/app_strings.dart';
import '../models/rain_route.dart';
import '../models/sensor.dart';
import '../services/api_service.dart';
import '../services/user_location_service.dart';
import '../theme/app_theme.dart';
import '../widgets/dashboard_widgets.dart';
import '../widgets/rain_route_panel.dart';
import '../widgets/station_map.dart';
import '../widgets/weather_panel.dart';
import 'station_detail_screen.dart';

enum _StationFilter { all, online, warning }

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    this.api,
    this.autoRefresh = true,
    this.loadMapTiles = true,
    this.mapTileProvider,
  });
  final ApiService? api;
  final bool autoRefresh, loadMapTiles;
  final TileProvider? mapTileProvider;
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  late ApiService _api;
  late bool _ownsApi;
  Timer? _timer;
  StreamSubscription<Reading>? _alertSub;
  Timer? _sseRetryTimer;
  List<Station> _stations = [];
  final _stationsSignal = ValueNotifier<List<Station>>([]);
  List<Reading> _alerts = [];
  String? _error, _alertError, _selectedId;
  String _query = '';
  _StationFilter _filter = _StationFilter.all;
  final _searchController = TextEditingController();
  int _tab = 1, _revision = 0;
  bool _loading = true, _refreshing = false, _active = true;
  DateTime? _syncedAt;
  final _locations = UserLocationService();
  UserPosition? _userPosition;
  LocationOutcome? _locationOutcome;
  RainPlan? _rainPlan;
  String? _selectedRouteId;
  final _routeMapKey = GlobalKey();
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? ApiService();
    _ownsApi = widget.api == null;
    WidgetsBinding.instance.addObserver(this);
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_locate(automatic: true));
    });
    if (widget.autoRefresh) {
      _timer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (_active) _load();
      });
      _connectAlertStream();
    }
  }

  void _connectAlertStream() {
    if (!widget.autoRefresh || !mounted) return;
    _sseRetryTimer?.cancel();
    _alertSub?.cancel();
    _alertSub = _api.alertStream().listen(
      _onRealtimeAlert,
      onError: (_) => _scheduleSseReconnect(),
      onDone: _scheduleSseReconnect,
    );
  }

  void _scheduleSseReconnect() {
    if (!mounted || !widget.autoRefresh) return;
    _sseRetryTimer?.cancel();
    _sseRetryTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _active) _connectAlertStream();
    });
  }

  void _onRealtimeAlert(Reading reading) {
    if (!mounted) return;
    final key = '${reading.deviceId}|${reading.createdAt?.toIso8601String()}';
    setState(() {
      final filtered = _alerts
          .where(
            (a) => '${a.deviceId}|${a.createdAt?.toIso8601String()}' != key,
          )
          .toList();
      _alerts = [reading, ...filtered].take(100).toList();
      _alertError = null;
    });
    final s = AppStrings.of(context);
    final isDanger = reading.level == 2;
    final hiText = reading.heatIndex != null
        ? '${reading.heatIndex!.toStringAsFixed(1)}°C'
        : '—';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: isDanger
              ? const Color(0xFFDC2626)
              : const Color(0xFFD97706),
          duration: const Duration(seconds: 6),
          content: Text(
            s.isVi
                ? '${isDanger ? "⚠ Nguy hiểm" : "△ Cảnh báo nóng"} · ${reading.deviceId}: $hiText'
                : '${isDanger ? "⚠ Danger" : "△ Heat Advisory"} · ${reading.deviceId}: $hiText',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          action: SnackBarAction(
            label: s.isVi ? 'Xem' : 'View',
            textColor: Colors.white,
            onPressed: () {
              if (mounted) setState(() => _tab = 2);
            },
          ),
        ),
      );
    unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) {
      _load();
      if (widget.autoRefresh) _connectAlertStream();
    }
  }

  @override
  void dispose() {
    _revision++;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _sseRetryTimer?.cancel();
    _alertSub?.cancel();
    _stationsSignal.dispose();
    _searchController.dispose();
    if (_ownsApi) _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    if (_refreshing) return;
    final revision = ++_revision;
    setState(() => _refreshing = true);
    final api = _api;
    // Cảnh báo lỗi độc lập để điểm đo vẫn dùng được khi một API gặp lỗi.
    final results = await Future.wait<Object>([
      api.devices().then<Object>((value) => value).catchError((Object e) => e),
      api.alerts().then<Object>((value) => value).catchError((Object e) => e),
    ]);
    if (!mounted || revision != _revision) return;
    setState(() {
      if (results[0] is List<Station>) {
        _stations = results[0] as List<Station>;
        _stationsSignal.value = _stations;
        _error = null;
        _syncedAt = DateTime.now();
      } else {
        _error = '${results[0]}';
      }
      if (results[1] is List<Reading>) {
        _alerts = results[1] as List<Reading>;
        _alertError = null;
      } else {
        _alertError = '${results[1]}';
      }
      _loading = false;
      _refreshing = false;
    });
  }

  Future<UserPosition?> _locate({bool automatic = false}) async {
    if (_locating) return null;
    setState(() => _locating = true);
    final outcome = await _locations.locate(automatic: automatic);
    if (!mounted) return null;
    setState(() {
      _locating = false;
      if (outcome.position != null) _userPosition = outcome.position;
      _locationOutcome = outcome.status == 'unsupported' && automatic
          ? null
          : outcome;
    });
    return outcome.position;
  }

  Future<void> _settings() async {
    final s = AppStrings.of(context);
    var inputUrl = _api.baseUrl;
    final formKey = GlobalKey<FormState>();
    final newUrl = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.serverSettingsTitle),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(s.serverSettingsSubtitle),
              const SizedBox(height: 16),
              TextFormField(
                initialValue: inputUrl,
                onChanged: (value) => inputUrl = value,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: s.serverUrlLabel,
                  hintText: 'http://192.168.1.10:5000',
                ),
                validator: (value) {
                  try {
                    ApiService.normalizeUrl(value ?? '');
                    return null;
                  } catch (error) {
                    return '$error';
                  }
                },
              ),
              const SizedBox(height: 12),
              Text(s.serverSessionHint, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context, ApiService.normalizeUrl(inputUrl));
              }
            },
            child: Text(s.connect),
          ),
        ],
      ),
    );
    // Dialog route finishes its closing animation after the future resolves.
    if (!mounted || newUrl == null || newUrl == _api.baseUrl) return;
    _revision++;
    if (_ownsApi) _api.close();
    setState(() {
      _api = ApiService(baseUrl: newUrl);
      _ownsApi = true;
      _stations = [];
      _alerts = [];
      _error = null;
      _alertError = null;
      _syncedAt = null;
      _loading = true;
      _refreshing = false;
      _rainPlan = null;
      _selectedRouteId = null;
    });
    await _load();
  }

  Future<void> _openStation(Station station) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => StationDetailScreen(
          station: station,
          api: _api,
          autoRefresh: widget.autoRefresh,
        ),
      ),
    );
  }

  Future<void> _previewStation(Station station) async {
    setState(() => _selectedId = station.id);
    final chosen = await showModalBottomSheet<Station>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .76,
        minChildSize: .45,
        maxChildSize: .94,
        builder: (_, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
          child: ValueListenableBuilder<List<Station>>(
            valueListenable: _stationsSignal,
            builder: (_, devices, _) {
              final matches = devices.where((e) => e.id == station.id);
              final current = matches.isEmpty ? station : matches.first;
              return StationQuickView(
                station: current,
                onDetails: () => Navigator.pop(sheetContext, current),
              );
            },
          ),
        ),
      ),
    );
    if (mounted && chosen != null) await _openStation(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final hw = HeatWatchColors.of(context);
    final settings = AppScope.maybeOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final online = _stations.where((e) => e.online).length;
    final hot = _stations.where((e) => (e.latest?.level ?? -1) > 0).length;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 14,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [hw.blue, hw.turquoise],
                ),
                borderRadius: BorderRadius.circular(11),
                boxShadow: [
                  BoxShadow(
                    color: hw.blue.withValues(alpha: 0.28),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: const Icon(
                Icons.wb_sunny_outlined,
                color: Colors.white,
                size: 19,
              ),
            ),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                'HeatWatch',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                  color: hw.ink,
                ),
              ),
            ),
          ],
        ),
        actions: [
          Tooltip(
            message: s.languageToggleTooltip,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: settings?.toggleLanguage,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: hw.cardSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: hw.cardBorder),
                ),
                child: Text(
                  s.isVi ? 'VI' : 'EN',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: hw.blue,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
            onPressed: () => settings?.setThemeMode(
              isDark ? ThemeMode.light : ThemeMode.dark,
            ),
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 20,
            ),
            tooltip: s.themeModeTooltip,
          ),
          IconButton(
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
            onPressed: _refreshing ? null : _load,
            icon: const Icon(Icons.refresh, size: 21),
            tooltip: s.refreshDataTooltip,
          ),
          IconButton(
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
            onPressed: _settings,
            icon: const Icon(Icons.tune, size: 20),
            tooltip: s.serverSettingsTooltip,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SkyBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              if (_refreshing && !_loading)
                const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1000),
                          child: AnimatedSwitcher(
                            duration: disableAnimations
                                ? Duration.zero
                                : const Duration(milliseconds: 220),
                            switchInCurve: Curves.easeOutCubic,
                            child: Column(
                              key: ValueKey(_tab),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  s.headingForTab(_tab),
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(fontSize: 26),
                                ),
                                const SizedBox(height: 4),
                                if (_tab != 3)
                                  Text(
                                    s.subtitleForTab(_tab),
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: hw.muted,
                                    ),
                                  ),
                                const SizedBox(height: 18),
                                if (_tab == 3)
                                  WeatherPanel(
                                    key: ValueKey(_api.baseUrl),
                                    api: _api,
                                    stations: _stations,
                                    onLocate: () async =>
                                        _userPosition ?? await _locate(),
                                    autoRefresh: widget.autoRefresh,
                                  )
                                else if (_tab == 1)
                                  _mapSummary(hw, s, online, hot)
                                else
                                  _summary(hw, s, online, hot),
                                if (_syncedAt != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.sync,
                                          size: 13,
                                          color: hw.muted,
                                        ),
                                        const SizedBox(width: 5),
                                        Expanded(
                                          child: Text(
                                            s.syncedLabel(
                                              _syncedAt,
                                              _error != null,
                                            ),
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: hw.muted,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (_error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 14),
                                    child: MessageCard(
                                      title: s.serverConnectFailedTitle,
                                      message: _error!,
                                      onRetry: _load,
                                    ),
                                  ),
                                if (_tab == 3)
                                  const SizedBox.shrink()
                                else if (_loading)
                                  const Padding(
                                    padding: EdgeInsets.all(48),
                                    child: Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  )
                                else if (_tab == 0)
                                  ..._stationList(hw, s)
                                else if (_tab == 1)
                                  ..._mapContent(hw, s)
                                else
                                  ..._alertContent(hw, s),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: hw.cardBorder)),
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (value) => setState(() => _tab = value),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.sensors_outlined),
              selectedIcon: const Icon(Icons.sensors),
              label: s.tabStations,
            ),
            NavigationDestination(
              icon: const Icon(Icons.map_outlined),
              selectedIcon: const Icon(Icons.map),
              label: s.tabMap,
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: _alerts.isNotEmpty || hot > 0,
                label: Text('${hot > 0 ? hot : _alerts.length}'),
                child: const Icon(Icons.notifications_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: _alerts.isNotEmpty || hot > 0,
                label: Text('${hot > 0 ? hot : _alerts.length}'),
                child: const Icon(Icons.notifications),
              ),
              label: s.tabAlerts,
            ),
            NavigationDestination(
              icon: const Icon(Icons.wb_cloudy_outlined),
              selectedIcon: const Icon(Icons.wb_cloudy),
              label: s.tabWeather,
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary(
    HeatWatchColors hw,
    AppStrings s,
    int online,
    int hot,
  ) => Container(
    padding: const EdgeInsets.all(22),
    decoration: skyPanelDecoration(hw),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.hub_outlined,
                color: Color(0xFF99F6E4),
                size: 18,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                s.networkBannerLabel(_loading, _error != null),
                style: const TextStyle(
                  color: Color(0xFFE5F0FF),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          s.stationCountHeadline(
            _stations.length,
            _loading,
            _error != null && _stations.isEmpty,
          ),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 40,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.4,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            _heroChip('●  ${s.activeCountText(online)}', const Color(0xFF99F6E4)),
            _heroChip('●  ${s.warningCountText(hot)}', const Color(0xFFFDE68A)),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          s.autoSyncNote,
          style: const TextStyle(color: Color(0xFFD5E9FF), fontSize: 11),
        ),
      ],
    ),
  );

  Widget _heroChip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
    ),
  );

  Widget _mapSummary(
    HeatWatchColors hw,
    AppStrings s,
    int online,
    int hot,
  ) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      Chip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(Icons.memory, size: 16, color: hw.blue),
        label: Text(s.devicesCountChip(_stations.length, _loading)),
      ),
      Chip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(Icons.wifi, size: 16, color: hw.safe),
        label: Text(s.onlineChip(online)),
      ),
      if (hot > 0)
        Chip(
          visualDensity: VisualDensity.compact,
          avatar: Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: hw.caution,
          ),
          label: Text(s.warningCountText(hot)),
        ),
    ],
  );

  List<Widget> _stationList(HeatWatchColors hw, AppStrings s) {
    final filtered = _stations.where((e) {
      final matchesQuery = '${e.name} ${e.id}'.toLowerCase().contains(
        _query.toLowerCase(),
      );
      final matchesFilter = switch (_filter) {
        _StationFilter.all => true,
        _StationFilter.online => e.online,
        _StationFilter.warning => (e.latest?.level ?? -1) > 0,
      };
      return matchesQuery && matchesFilter;
    }).toList();
    return [
      SectionTitle(s.stationListTitle, subtitle: s.stationListSubtitle),
      TextField(
        controller: _searchController,
        onChanged: (value) => setState(() => _query = value),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          labelText: s.searchStationsLabel,
          suffixIcon: _query.isNotEmpty
              ? IconButton(
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                  icon: const Icon(Icons.close, size: 18),
                )
              : null,
        ),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          ChoiceChip(
            label: Text(s.filterAll),
            selected: _filter == _StationFilter.all,
            onSelected: (_) => setState(() => _filter = _StationFilter.all),
          ),
          ChoiceChip(
            label: Text(s.filterOnline),
            selected: _filter == _StationFilter.online,
            onSelected: (_) => setState(() => _filter = _StationFilter.online),
          ),
          ChoiceChip(
            label: Text(s.filterWarning),
            selected: _filter == _StationFilter.warning,
            onSelected: (_) => setState(() => _filter = _StationFilter.warning),
          ),
        ],
      ),
      const SizedBox(height: 14),
      if (filtered.isEmpty)
        MessageCard(
          title: _stations.isEmpty ? s.noStationsTitle : s.noSearchResultsTitle,
          message: _stations.isEmpty
              ? s.noStationsMessage
              : s.noSearchResultsMessage,
        ),
      for (final station in filtered)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _stationCard(hw, s, station),
        ),
    ];
  }

  Widget _stationCard(HeatWatchColors hw, AppStrings s, Station station) {
    final level = station.latest?.level ?? -1;
    final accent = adaptiveLevelColor(context, level);
    return Container(
      decoration: elevatedCardDecoration(hw, radius: 20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openStation(station),
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: accent, width: 4)),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: hw.turquoise.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.sensors, color: hw.turquoise, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          station.name,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          station.id,
                          style: TextStyle(fontSize: 12, color: hw.muted),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: hw.muted),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.heatIndexLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: hw.muted,
                        ),
                      ),
                      Text(
                        measurement(station.latest?.heatIndex),
                        style: TextStyle(
                          color: hw.ink,
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  StatusBadge(level: level),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _miniPill(
                    hw,
                    Icons.thermostat,
                    '${s.temperatureLabel} ${measurement(station.latest?.temperature)}',
                    const Color(0xFFF59E0B),
                  ),
                  _miniPill(
                    hw,
                    Icons.water_drop_outlined,
                    '${s.humidityLabel} ${measurement(station.latest?.humidity, '%')}',
                    hw.turquoise,
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  Text(
                    station.online
                        ? '● ${s.stationOnline}'
                        : '● ${s.stationOfflineSignal}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: station.online ? hw.safe : hw.muted,
                    ),
                  ),
                  Text(
                    s.relativeUpdateText(
                      station.latest?.createdAt ?? station.lastSeen,
                    ),
                    style: TextStyle(fontSize: 11, color: hw.muted),
                  ),
                ],
              ),
              if (station.hasLocation)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${station.mapLatitude!.toStringAsFixed(4)}, ${station.mapLongitude!.toStringAsFixed(4)}',
                    style: TextStyle(fontSize: 11, color: hw.muted),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  s.stationLocationDescription(station),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: station.locationSource == 'lbs'
                        ? hw.caution
                        : hw.blue,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniPill(
    HeatWatchColors hw,
    IconData icon,
    String text,
    Color iconColor,
  ) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: hw.subtleSurface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: hw.cardBorder),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: iconColor),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: hw.ink,
          ),
        ),
      ],
    ),
  );

  List<Widget> _mapContent(HeatWatchColors hw, AppStrings s) => [
    const SizedBox(height: 12),
    StationMap(
      key: _routeMapKey,
      stations: _stations,
      selectedId: _selectedId,
      loadTiles: widget.loadMapTiles,
      tileProvider: widget.mapTileProvider,
      onSelect: _previewStation,
      userPosition: _userPosition,
      routePlan: _rainPlan,
      selectedRouteId: _selectedRouteId,
      locating: _locating,
      onLocate: () {
        unawaited(_locate());
      },
    ),
    if (_locating || _locationOutcome != null)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: hw.subtleSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: hw.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _locating
                    ? s.locatingStatus
                    : s.locationOutcomeMessage(_locationOutcome!),
                style: TextStyle(fontSize: 12, color: hw.ink),
              ),
              if (_locationOutcome?.status == 'permission_denied_forever')
                TextButton(
                  onPressed: _locations.openSettings,
                  child: Text(s.openLocationSettings),
                ),
            ],
          ),
        ),
      ),
    const SizedBox(height: 12),
    RainRoutePanel(
      key: ValueKey(_api.baseUrl),
      api: _api,
      defaultOrigin: _userPosition,
      onPlan: (plan) => setState(() {
        _rainPlan = plan;
        _selectedRouteId = null;
      }),
      onRouteSelected: (route) {
        setState(() => _selectedRouteId = route.id);
        final mapContext = _routeMapKey.currentContext;
        if (mapContext != null) {
          unawaited(
            Scrollable.ensureVisible(
              mapContext,
              duration: const Duration(milliseconds: 300),
              alignment: .1,
            ),
          );
        }
      },
      onUseLocation: () async => _userPosition ?? await _locate(),
    ),
    Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        s.mapLegendSummary,
        style: TextStyle(fontSize: 11, color: hw.muted),
      ),
    ),
    SectionTitle(s.devicesOnMapTitle, subtitle: s.devicesOnMapSubtitle),
    if (_stations.isEmpty)
      MessageCard(
        title: s.noStationsOnMapTitle,
        message: s.noStationsOnMapSubtitle,
      ),
    for (final station in _stations)
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          decoration: elevatedCardDecoration(hw, radius: 18),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 6,
            ),
            leading: CircleAvatar(
              backgroundColor: adaptiveLevelColor(
                context,
                station.latest?.level ?? -1,
              ).withValues(alpha: 0.14),
              child: Icon(
                Icons.place_outlined,
                color: adaptiveLevelColor(
                  context,
                  station.latest?.level ?? -1,
                ),
              ),
            ),
            title: Text(
              station.id,
              style: TextStyle(fontWeight: FontWeight.w700, color: hw.ink),
            ),
            subtitle: Text(
              '${station.name}\n${s.stationLocationDescription(station)}\n${measurement(station.latest?.heatIndex)} · '
              '${station.hasLocation ? (station.online ? s.stationConnected : s.stationLostSignal) : s.stationAwaitingCoords}',
              style: TextStyle(fontSize: 12, color: hw.muted),
            ),
            trailing: Icon(Icons.chevron_right, color: hw.muted),
            onTap: () {
              if (station.hasLocation) setState(() => _selectedId = station.id);
              _openStation(station);
            },
          ),
        ),
      ),
  ];

  List<Widget> _alertContent(HeatWatchColors hw, AppStrings s) => [
    Container(
      padding: const EdgeInsets.all(14),
      decoration: elevatedCardDecoration(hw, radius: 16),
      child: Row(
        children: [
          _scaleItem(hw.safe, s.thresholdScaleSafe),
          const SizedBox(width: 8),
          _scaleItem(hw.caution, s.thresholdScaleCaution),
          const SizedBox(width: 8),
          _scaleItem(hw.danger, s.thresholdScaleDanger),
        ],
      ),
    ),
    SectionTitle(s.alertLogTitle, subtitle: s.alertLogSubtitle),
    if (_alertError != null)
      MessageCard(
        title: s.alertLoadErrorTitle,
        message: _alertError!,
        onRetry: _load,
      ),
    if (_alerts.isEmpty && _alertError == null)
      MessageCard(
        title: s.noAlertsTitle,
        message: s.noAlertsMessage,
        icon: Icons.check_circle_outline,
      ),
    if (_alertError != null && _alerts.isNotEmpty)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(s.cachedAlertsNotice, style: TextStyle(color: hw.muted)),
      ),
    for (final alert in _alerts)
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          decoration: elevatedCardDecoration(hw, radius: 18),
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: adaptiveLevelColor(context, alert.level),
                  width: 4,
                ),
              ),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: adaptiveLevelColor(
                          context,
                          alert.level,
                        ).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.warning_amber_rounded,
                        color: adaptiveLevelColor(context, alert.level),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _stationName(alert.deviceId),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      measurement(alert.heatIndex),
                      style: TextStyle(
                        color: adaptiveLevelColor(context, alert.level),
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusBadge(level: alert.level),
                    if (alert.temperature != null)
                      _miniPill(
                        hw,
                        Icons.thermostat,
                        measurement(alert.temperature),
                        const Color(0xFFF59E0B),
                      ),
                    if (alert.humidity != null)
                      _miniPill(
                        hw,
                        Icons.water_drop_outlined,
                        measurement(alert.humidity, '%'),
                        hw.turquoise,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  displayTime(alert.createdAt),
                  style: TextStyle(fontSize: 12, color: hw.muted),
                ),
              ],
            ),
          ),
        ),
      ),
  ];

  Widget _scaleItem(Color color, String label) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border(top: BorderSide(color: color, width: 3)),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    ),
  );

  String _stationName(String id) {
    final match = _stations.where((e) => e.id == id);
    return match.isEmpty ? id : match.first.name;
  }
}
