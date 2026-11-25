import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/sensor.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/dashboard_widgets.dart';

class StationDetailScreen extends StatefulWidget {
  const StationDetailScreen({
    super.key,
    required this.station,
    required this.api,
    this.autoRefresh = true,
  });
  final Station station;
  final ApiService api;
  final bool autoRefresh;
  @override
  State<StationDetailScreen> createState() => _StationDetailScreenState();
}

class _StationDetailScreenState extends State<StationDetailScreen>
    with WidgetsBindingObserver {
  Timer? _timer;
  late Station _station;
  List<Reading> _history = [];
  Forecast? _forecast;
  String? _historyError, _forecastError, _currentError;
  bool _loading = true, _busy = false, _active = true;
  int _hours = 24, _revision = 0;

  @override
  void initState() {
    super.initState();
    _station = widget.station;
    WidgetsBinding.instance.addObserver(this);
    _load();
    if (widget.autoRefresh) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (_active) _load();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) _load();
  }

  @override
  void dispose() {
    _revision++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    final revision = ++_revision;
    setState(() => _busy = true);
    final results = await Future.wait<Object>([
      widget.api.devices().then<Object>((e) => e).catchError((Object e) => e),
      widget.api
          .history(_station.id, hours: _hours)
          .then<Object>((e) => e)
          .catchError((Object e) => e),
      widget.api
          .forecast(_station.id)
          .then<Object>((e) => e)
          .catchError((Object e) => e),
    ]);
    if (!mounted || revision != _revision) return;
    setState(() {
      if (results[0] is List<Station>) {
        final match = (results[0] as List<Station>).where(
          (e) => e.id == _station.id,
        );
        if (match.isNotEmpty) {
          _station = match.first;
          _currentError = null;
        } else {
          _currentError = AppStrings.of(context).stationRemovedNotice;
        }
      } else {
        _currentError = '${results[0]}';
      }
      if (results[1] is List<Reading>) {
        _history = results[1] as List<Reading>;
        _historyError = null;
      } else {
        _historyError = '${results[1]}';
      }
      if (results[2] is Forecast) {
        _forecast = results[2] as Forecast;
        _forecastError = null;
      } else {
        _forecastError = '${results[2]}';
        _forecast = null;
      }
      _loading = false;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final hw = HeatWatchColors.of(context);
    final onlineColor = _station.online ? hw.safe : hw.muted;
    return Scaffold(
      appBar: AppBar(
        title: Text(_station.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: s.refreshStationTooltip,
          ),
        ],
      ),
      body: SkyBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              if (_busy && !_loading)
                const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(18),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 900),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: onlineColor.withValues(alpha: 0.13),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      _station.online
                                          ? '● ${s.stationOnline}'
                                          : '● ${s.stationOfflineSignal}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: onlineColor,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: hw.cardSurface,
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(color: hw.cardBorder),
                                    ),
                                    child: Text(
                                      _station.id,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: hw.muted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Metrics(reading: _station.latest),
                              const SizedBox(height: 14),
                              _metadataCard(hw, s),
                              if (_currentError != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 14),
                                  child: MessageCard(
                                    title: s.currentDataStaleTitle,
                                    message: _currentError!,
                                    onRetry: _load,
                                  ),
                                ),
                              if (!_station.online && _station.latest != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Text(
                                    s.offlineReadingNotice,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: hw.muted,
                                    ),
                                  ),
                                ),
                              SectionTitle(
                                s.forecast5hTitle,
                                subtitle: s.forecast5hSubtitle,
                              ),
                              if (_loading)
                                const Padding(
                                  padding: EdgeInsets.all(20),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              else if (_forecastError != null)
                                MessageCard(
                                  title: s.forecastUnavailableTitle,
                                  message: _forecastError!,
                                  onRetry: _load,
                                )
                              else if (_forecast == null ||
                                  _forecast!.values.isEmpty)
                                MessageCard(
                                  title: s.forecastUnavailableTitle,
                                  message: s.forecastEmptyMessage,
                                )
                              else
                                _forecastCard(hw, s),
                              SectionTitle(
                                s.historyTitle,
                                subtitle: s.historySubtitle,
                                trailing: PopupMenuButton<int>(
                                  tooltip: s.timeframeTooltip,
                                  enabled: !_busy,
                                  onSelected: (value) {
                                    setState(() {
                                      _hours = value;
                                      _history = [];
                                    });
                                    _load();
                                  },
                                  itemBuilder: (_) => [
                                    PopupMenuItem(
                                      value: 24,
                                      child: Text(s.hours24),
                                    ),
                                    PopupMenuItem(
                                      value: 168,
                                      child: Text(s.days7),
                                    ),
                                  ],
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 11,
                                      vertical: 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: hw.cardSurface,
                                      borderRadius: BorderRadius.circular(11),
                                      border: Border.all(color: hw.cardBorder),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _hours == 24 ? s.hours24 : s.days7,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: hw.blue,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Icon(
                                          Icons.expand_more,
                                          size: 16,
                                          color: hw.blue,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if (_historyError != null)
                                MessageCard(
                                  title: s.historyLoadErrorTitle,
                                  message: _historyError!,
                                  onRetry: _load,
                                )
                              else if (!_loading && _history.isEmpty)
                                MessageCard(
                                  title: s.historyEmptyTitle,
                                  message: s.historyEmptyMessage,
                                ),
                              if (_history.isNotEmpty) _historyCard(hw, s),
                              const SizedBox(height: 20),
                              Text(
                                s.thresholdFootnote,
                                style: TextStyle(fontSize: 11, color: hw.muted),
                              ),
                              const SizedBox(height: 20),
                            ],
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
    );
  }

  Widget _metadataCard(HeatWatchColors hw, AppStrings s) => Container(
    padding: const EdgeInsets.all(15),
    decoration: elevatedCardDecoration(hw, radius: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.schedule, size: 16, color: hw.blue),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${s.relativeUpdateText(_station.latest?.createdAt ?? _station.lastSeen)}\n'
                '${s.measurementTimeLabel(_station.latest?.createdAt ?? _station.lastSeen)}',
                style: TextStyle(fontSize: 12, color: hw.ink, height: 1.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (!_station.hasLocation)
          Row(
            children: [
              Icon(Icons.gps_not_fixed, size: 16, color: hw.caution),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.locatingDetailMessage,
                  style: TextStyle(fontSize: 12, color: hw.caution),
                ),
              ),
            ],
          )
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _station.locationSource == 'gps'
                    ? Icons.gps_fixed
                    : Icons.cell_tower,
                size: 16,
                color: _station.locationSource == 'lbs'
                    ? hw.caution
                    : hw.turquoise,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.coordinatesLabel(
                        _station.mapLatitude!,
                        _station.mapLongitude!,
                      ),
                      style: TextStyle(fontSize: 12, color: hw.ink),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      s.stationLocationDescription(_station),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _station.locationSource == 'lbs'
                            ? hw.caution
                            : hw.blue,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      s.locationUpdatedLabel(_station.locationUpdatedAt),
                      style: TextStyle(fontSize: 11, color: hw.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );

  Widget _forecastCard(HeatWatchColors hw, AppStrings s) {
    final forecast = _forecast!;
    final peakVal = forecast.values.reduce(math.max);
    final peakIndex = forecast.values.indexOf(peakVal);
    return Container(
      decoration: elevatedCardDecoration(hw),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TrendChart(
            values: forecast.values,
            forecast: true,
            labels: List.generate(
              forecast.values.length,
              (i) => i < forecast.times.length && forecast.times[i] != null
                  ? displayTime(forecast.times[i], date: false)
                  : '+${i + 1}h',
            ),
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (i, value) in forecast.values.indexed)
                  () {
                    final level = warningLevel(value);
                    final color = adaptiveLevelColor(context, level);
                    final isPeak = i == peakIndex;
                    return Container(
                      width: 84,
                      margin: EdgeInsets.only(
                        right: i == forecast.values.length - 1 ? 0 : 8,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: isPeak
                            ? color.withValues(alpha: 0.14)
                            : hw.subtleSurface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isPeak
                              ? color
                              : color.withValues(alpha: 0.3),
                          width: isPeak ? 1.6 : 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            s.isVi ? '+${i + 1} giờ' : '+${i + 1}h',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isPeak
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: isPeak ? color : hw.muted,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            measurement(value),
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(height: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              isPeak
                                  ? (s.isVi ? 'Đỉnh điểm' : 'Peak')
                                  : (level == 2
                                        ? (s.isVi ? 'Nguy hiểm' : 'Danger')
                                        : level == 1
                                        ? (s.isVi ? 'Cảnh báo' : 'Caution')
                                        : (s.isVi ? 'An toàn' : 'Safe')),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: color,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }(),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            s.forecastGeneratedAt(forecast.generatedAt),
            style: TextStyle(fontSize: 11, color: hw.muted),
          ),
          if (forecast.modelStatus == 'experimental' ||
              forecast.modelNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: hw.caution.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  forecast.modelNote.isEmpty
                      ? s.forecastExperimentalFallback
                      : forecast.modelNote,
                  style: TextStyle(fontSize: 11, color: hw.caution),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _historyCard(HeatWatchColors hw, AppStrings s) {
    final numeric = _history.where((e) => e.heatIndex != null).toList();
    final values = numeric.map((e) => e.heatIndex!).toList();
    return Container(
      decoration: elevatedCardDecoration(hw),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (values.isNotEmpty) ...[
            Row(
              children: [
                _statPill(
                  hw,
                  s.statsMin,
                  measurement(values.reduce(math.min)),
                  hw.safe,
                ),
                const SizedBox(width: 8),
                _statPill(
                  hw,
                  s.statsAvg,
                  measurement(values.reduce((a, b) => a + b) / values.length),
                  hw.blue,
                ),
                const SizedBox(width: 8),
                _statPill(
                  hw,
                  s.statsMax,
                  measurement(values.reduce(math.max)),
                  adaptiveLevelColor(
                    context,
                    warningLevel(values.reduce(math.max)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TrendChart(
              values: values,
              labels: [
                displayTime(numeric.first.createdAt, date: false),
                displayTime(numeric.last.createdAt, date: false),
              ],
            ),
            const SizedBox(height: 18),
          ],
          for (final row in _history.reversed.take(30))
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: hw.subtleSurface,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: hw.cardBorder),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayTime(row.createdAt),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: hw.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${s.tableTemp}: ${measurement(row.temperature)}  ·  ${s.tableHumidity}: ${measurement(row.humidity, '%')}',
                          style: TextStyle(fontSize: 11, color: hw.muted),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        measurement(row.heatIndex),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: adaptiveLevelColor(context, row.level),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        s.warningLabel(row.level),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: adaptiveLevelColor(context, row.level),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Text(
            s.historyTableNote,
            style: TextStyle(fontSize: 11, color: hw.muted),
          ),
        ],
      ),
    );
  }

  Widget _statPill(
    HeatWatchColors hw,
    String label,
    String value,
    Color color,
  ) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
      decoration: BoxDecoration(
        color: hw.subtleSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: hw.cardBorder),
      ),
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: hw.muted)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
