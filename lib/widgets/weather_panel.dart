import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_strings.dart';
import '../models/sensor.dart';
import '../models/weather.dart';
import '../services/api_service.dart';
import '../services/user_location_service.dart';
import '../theme/app_theme.dart';
import 'dashboard_widgets.dart';

class WeatherPanel extends StatefulWidget {
  const WeatherPanel({
    super.key,
    required this.api,
    required this.stations,
    required this.onLocate,
    required this.autoRefresh,
  });

  final ApiService api;
  final List<Station> stations;
  final Future<UserPosition?> Function() onLocate;
  final bool autoRefresh;

  @override
  State<WeatherPanel> createState() => _WeatherPanelState();
}

class _WeatherPanelState extends State<WeatherPanel> {
  static const _city = LatLng(10.78, 106.70);
  Timer? _timer;
  LocalWeather? _data;
  String? _stationId, _loadedKey, _error;
  String? _forecastStationId, _forecastError;
  Forecast? _forecast;
  bool _forecastLoading = false;
  int _forecastRevision = 0;
  UserPosition? _user;
  bool _busy = false, _locating = false, _locationFailed = false;
  int _revision = 0;

  Station? get _station =>
      widget.stations
          .where((station) => station.id == _stationId)
          .firstOrNull ??
      widget.stations.firstOrNull;

  LatLng get _point {
    final location = _station?.location;
    return _user?.point ??
        (location == null
            ? _city
            : LatLng(location.latitude, location.longitude));
  }

  String _locationLabel(AppStrings s) {
    if (_user != null) return s.yourArea;
    final station = _station;
    if (station == null || !station.hasLocation) return s.defaultCity;
    if (station.online) return station.name;
    return s.isVi
        ? '${station.name} · vị trí gần nhất'
        : '${station.name} · last known';
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_loadForecast());
    if (widget.autoRefresh) {
      _timer = Timer.periodic(const Duration(minutes: 10), (_) {
        unawaited(_load(force: true));
        unawaited(_loadForecast(force: true));
      });
    }
  }

  @override
  void didUpdateWidget(covariant WeatherPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.stations != oldWidget.stations) {
      unawaited(_load());
      unawaited(_loadForecast());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadForecast({bool force = false}) async {
    final id = _station?.id;
    if (id == _forecastStationId && (!force || _forecastLoading)) return;
    final revision = ++_forecastRevision;
    setState(() {
      _forecastStationId = id;
      _forecastLoading = id != null;
      _forecastError = null;
      _forecast = null;
    });
    if (id == null) return;
    try {
      final forecast = await widget.api.forecast(id);
      if (mounted && revision == _forecastRevision) {
        setState(() {
          _forecast = forecast;
          _forecastLoading = false;
        });
      }
    } catch (error) {
      if (mounted && revision == _forecastRevision) {
        setState(() {
          _forecastError = '$error';
          _forecastLoading = false;
        });
      }
    }
  }

  Future<void> _load({bool force = false}) async {
    final point = _point;
    final key =
        '${point.latitude.toStringAsFixed(2)},${point.longitude.toStringAsFixed(2)}';
    final same = key == _loadedKey;
    if (same && (!force || _busy)) return;
    final revision = ++_revision;
    setState(() {
      if (!same) _data = null;
      _loadedKey = key;
      _busy = true;
      _error = null;
    });
    try {
      final data = await widget.api.weather(point);
      if (mounted && revision == _revision) setState(() => _data = data);
    } catch (error) {
      if (mounted && revision == _revision) setState(() => _error = '$error');
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  Future<void> _useLocation() async {
    setState(() {
      _locating = true;
      _locationFailed = false;
    });
    final position = await widget.onLocate();
    if (!mounted) return;
    setState(() {
      _user = position;
      _locating = false;
      _locationFailed = position == null;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final hw = HeatWatchColors.of(context);
    final data = _data;
    final locationLabel = _locationLabel(s);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          s.weatherHeader,
          style: TextStyle(fontSize: 13, color: hw.muted),
        ),
        const SizedBox(height: 12),
        if (widget.stations.isNotEmpty)
          Container(
            decoration: elevatedCardDecoration(hw, radius: 16),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: s.referenceStation,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.zero,
                prefixIcon: Icon(Icons.sensors, color: hw.turquoise, size: 20),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  isDense: true,
                  dropdownColor: hw.cardSurface,
                  value: _station?.id,
                  items: [
                    for (final station in widget.stations)
                      DropdownMenuItem(
                        value: station.id,
                        child: Text(
                          station.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: hw.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                  onChanged: _locating
                      ? null
                      : (id) {
                          setState(() {
                            _stationId = id;
                            _user = null;
                          });
                          unawaited(_load());
                          unawaited(_loadForecast());
                        },
                ),
              ),
            ),
          ),
        const SizedBox(height: 10),
        Text(
          _locationFailed ? s.weatherLocationFailed : s.weatherLocationHelp,
          style: TextStyle(fontSize: 12, color: hw.muted),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _locating
                  ? null
                  : _user == null
                  ? _useLocation
                  : () {
                      setState(() => _user = null);
                      unawaited(_load());
                    },
              icon: Icon(
                _user == null ? Icons.my_location : Icons.sensors,
                size: 18,
              ),
              label: Text(
                _locating
                    ? s.locatingLabel
                    : _user == null
                    ? s.useMyLocation
                    : s.useStationWeather,
              ),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () {
                      unawaited(_load(force: true));
                      unawaited(_loadForecast(force: true));
                    },
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(s.refreshWeather),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: MessageCard(
              title: s.weatherLoadErrorTitle(locationLabel),
              message: '$_error${data == null ? '' : ' ${s.cachedWeatherNotice}'}',
              onRetry: () => _load(force: true),
            ),
          ),
        if (data == null)
          _forecastCard(context, hw, s)
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final current = _current(hw, s, data.current, locationLabel);
              final hourly = _forecastCard(context, hw, s);
              if (constraints.maxWidth < 680) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [current, const SizedBox(height: 14), hourly],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: current),
                  const SizedBox(width: 14),
                  Expanded(flex: 2, child: hourly),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _current(
    HeatWatchColors hw,
    AppStrings s,
    CurrentWeather current,
    String locationLabel,
  ) => Container(
    padding: const EdgeInsets.all(22),
    decoration: skyPanelDecoration(hw),
    child: DefaultTextStyle.merge(
      style: const TextStyle(color: Colors.white),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.currentLabel.toUpperCase(),
                      style: const TextStyle(
                        color: Color(0xFFCDE5FF),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      locationLabel,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  _weatherIcon(current.icon),
                  size: 32,
                  color: const Color(0xFFFDE68A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            measurement(current.temperature),
            style: const TextStyle(
              fontSize: 48,
              fontWeight: FontWeight.w700,
              letterSpacing: -1.5,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            current.description,
            style: const TextStyle(fontSize: 14, color: Color(0xFFEAF4FF)),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _weatherMetric(
                s.humidityLabel,
                measurement(current.humidity, '%'),
              ),
              _weatherMetric(
                current.rainUntil == null
                    ? s.rainChance
                    : s.rainChanceUntil(current.rainUntil!),
                measurement(current.rainProbability, '%'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            s.weatherUpdatedAt(current.time),
            style: const TextStyle(fontSize: 11, color: Color(0xFFCDE5FF)),
          ),
        ],
      ),
    ),
  );

  Widget _weatherMetric(String label, String value) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0x26FFFFFF),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0x2EFFFFFF)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFFDCEBFF)),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
        ],
      ),
    ),
  );

  Widget _forecastCard(
    BuildContext context,
    HeatWatchColors hw,
    AppStrings s,
  ) => Container(
    decoration: elevatedCardDecoration(hw),
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.forecastCardTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    s.forecastCardSubtitle,
                    style: TextStyle(fontSize: 12, color: hw.muted),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: hw.turquoise.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'LSTM',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: hw.turquoise,
                ),
              ),
            ),
          ],
        ),
        if (_station case final station?) ...[
          const SizedBox(height: 8),
          Text(
            station.name,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: hw.blue,
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (_forecastLoading)
          Text(s.loadingForecast, style: TextStyle(color: hw.muted))
        else if (_forecastError != null)
          Text(
            '${s.forecastUnavailableTitle}. $_forecastError',
            style: TextStyle(color: hw.muted),
          )
        else if (_forecast case final forecast?)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (index, value) in forecast.values.indexed)
                  () {
                    final color = adaptiveLevelColor(
                      context,
                      warningLevel(value),
                    );
                    return Container(
                      width: 82,
                      margin: EdgeInsets.only(
                        right: index == forecast.values.length - 1 ? 0 : 8,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: hw.subtleSurface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: color.withValues(alpha: 0.35)),
                      ),
                      child: Column(
                        children: [
                          Text(
                            index < forecast.times.length &&
                                    forecast.times[index] != null
                                ? displayTime(
                                    forecast.times[index],
                                    date: false,
                                  )
                                : '+${index + 1}h',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: hw.muted,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            measurement(value),
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }(),
              ],
            ),
          )
        else
          Text(s.noStationForForecast, style: TextStyle(color: hw.muted)),
      ],
    ),
  );

  IconData _weatherIcon(String icon) => switch (icon) {
    'clear' => Icons.wb_sunny_outlined,
    'night' => Icons.nightlight_outlined,
    'partly-cloudy' => Icons.wb_cloudy_outlined,
    'partly-cloudy-night' => Icons.nights_stay_outlined,
    'cloudy' => Icons.cloud_outlined,
    'fog' => Icons.foggy,
    'rain' => Icons.water_drop_outlined,
    'storm' => Icons.thunderstorm_outlined,
    'snow' => Icons.ac_unit,
    _ => Icons.help_outline,
  };
}
