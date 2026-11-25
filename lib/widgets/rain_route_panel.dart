import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_strings.dart';
import '../models/rain_route.dart';
import '../models/sensor.dart';
import '../services/api_service.dart';
import '../services/user_location_service.dart';
import '../theme/app_theme.dart';
import 'dashboard_widgets.dart';

class RainRoutePanel extends StatefulWidget {
  const RainRoutePanel({
    super.key,
    required this.api,
    required this.onPlan,
    required this.onUseLocation,
    this.defaultOrigin,
    this.onRouteSelected,
  });
  final ApiService api;
  final ValueChanged<RainPlan?> onPlan;
  final Future<UserPosition?> Function() onUseLocation;
  final UserPosition? defaultOrigin;
  final ValueChanged<RainRoute>? onRouteSelected;
  @override
  State<RainRoutePanel> createState() => _RainRoutePanelState();
}

class _RainRoutePanelState extends State<RainRoutePanel> {
  final _start = TextEditingController(), _end = TextEditingController();
  LatLng? _startPoint, _endPoint;
  String _vehicle = 'motorcycle';
  bool _busy = false, _scheduled = false;
  bool _originOverridden = false;
  int _revision = 0;
  DateTime? _departure;
  RainPlan? _plan;
  String? _selectedRouteId;
  String? _message;

  @override
  void initState() {
    super.initState();
    final position = widget.defaultOrigin;
    if (position != null) _setLocationOrigin(position);
  }

  @override
  void didUpdateWidget(covariant RainRoutePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.defaultOrigin != oldWidget.defaultOrigin &&
        widget.defaultOrigin != null &&
        !_originOverridden) {
      // The phone fix can arrive after the panel's first frame. Invalidate the
      // old route outside the parent's build, and recheck manual edits then.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _originOverridden || widget.defaultOrigin == null) {
          return;
        }
        final position = widget.defaultOrigin!;
        if (_startPoint == position.point &&
            _start.text == 'Vị trí của tôi') {
          return;
        }
        setState(() {
          _invalidate();
          _setLocationOrigin(position);
        });
      });
    }
  }

  void _setLocationOrigin(UserPosition position) {
    _startPoint = position.point;
    _start.text = 'Vị trí của tôi';
    _message = null;
  }

  @override
  void dispose() {
    _revision++;
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _invalidate() {
    _revision++;
    _busy = false;
    _plan = null;
    _message = null;
    widget.onPlan(null);
  }

  Future<LatLng?> _point(String text, bool origin, AppStrings s) async {
    final chosen = origin ? _startPoint : _endPoint;
    if (chosen != null) return chosen;
    final parts = text.trim().split(',');
    if (parts.length == 2) {
      final lat = double.tryParse(parts[0].trim()),
          lon = double.tryParse(parts[1].trim());
      if (lat != null &&
          lon != null &&
          lat.isFinite &&
          lon.isFinite &&
          lat.abs() <= 90 &&
          lon.abs() <= 180) {
        return LatLng(lat, lon);
      }
    }
    if (text.trim().length < 3) {
      throw ApiException(
        s.isVi
            ? 'Nhập địa chỉ hoặc vĩ độ, kinh độ cho cả hai điểm.'
            : 'Enter an address or latitude, longitude for both points.',
      );
    }
    final results = await widget.api.geocode(text.trim());
    if (!mounted) return null;
    if (results.isEmpty) {
      throw ApiException(
        s.isVi
            ? 'Không tìm thấy địa chỉ. Thử nhập thêm tỉnh/thành hoặc dùng tọa độ.'
            : 'Address not found. Try adding city/province or enter coordinates.',
      );
    }
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      useSafeArea: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              s.chooseExactAddress,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final result in results)
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: Text('${result['label']}'),
              onTap: () => Navigator.pop(context, result),
            ),
        ],
      ),
    );
    if (result == null || !mounted) return null;
    final point = result['point'] as List;
    return LatLng((point[0] as num).toDouble(), (point[1] as num).toDouble());
  }

  Future<void> _useLocation() async {
    final revision = ++_revision;
    final position = await widget.onUseLocation();
    if (!mounted || revision != _revision || position == null) return;
    setState(() {
      _invalidate();
      _originOverridden = false;
      _setLocationOrigin(position);
      _message = AppStrings.of(context).routeOriginDefaultMsg;
    });
  }

  Future<void> _find(AppStrings s) async {
    if (_busy) return;
    if (_scheduled && _departure == null) {
      setState(() => _message = s.selectDepartureFirst);
      return;
    }
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _message = s.searchingRoutesMsg;
      _plan = null;
    });
    widget.onPlan(null);
    try {
      final start = await _point(_start.text, true, s);
      if (!mounted || revision != _revision || start == null) return;
      final end = await _point(_end.text, false, s);
      if (!mounted || revision != _revision || end == null) return;
      final plan = await widget.api.rainRoute(
        start,
        end,
        _vehicle,
        _scheduled ? _departure : null,
      );
      if (!mounted || revision != _revision) return;
      setState(() {
        _plan = plan;
        _selectedRouteId = plan.primary.id;
        _message = [
          if (plan.routes.length == 1) s.singleRouteOnly,
          ...plan.warnings,
        ].join(' ');
      });
      widget.onPlan(plan);
    } catch (error) {
      if (mounted && revision == _revision) setState(() => _message = '$error');
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  Future<void> _pickTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 6)),
      initialDate: _departure ?? now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_departure ?? now),
    );
    if (time == null || !mounted) return;
    setState(() {
      _invalidate();
      _departure = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final hw = HeatWatchColors.of(context);
    return Container(
      decoration: elevatedCardDecoration(hw, radius: 22),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const ValueKey('rain-route-panel'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [hw.blue, hw.turquoise]),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.alt_route, color: Colors.white, size: 22),
          ),
          title: Text(
            s.routePlannerTitle,
            style: TextStyle(fontWeight: FontWeight.w700, color: hw.ink),
          ),
          subtitle: Text(
            s.routePlannerSubtitle,
            style: TextStyle(fontSize: 11, color: hw.muted),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 16, right: 10),
                  child: Column(
                    children: [
                      _pointBadge('A', hw.blue),
                      Container(width: 2, height: 42, color: hw.cardBorder),
                      _pointBadge('B', hw.turquoise),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        key: const ValueKey('route-start'),
                        controller: _start,
                        decoration: InputDecoration(
                          labelText: s.routeOriginLabel,
                          hintText: s.routeCoordHint,
                        ),
                        onChanged: (_) => setState(() {
                          _originOverridden = true;
                          _startPoint = null;
                          _invalidate();
                        }),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _useLocation,
                          icon: const Icon(Icons.my_location, size: 17),
                          label: Text(s.useMyLocation),
                        ),
                      ),
                      TextField(
                        key: const ValueKey('route-end'),
                        controller: _end,
                        decoration: InputDecoration(
                          labelText: s.routeDestLabel,
                          hintText: s.routeCoordHint,
                        ),
                        onChanged: (_) => setState(() {
                          _endPoint = null;
                          _invalidate();
                        }),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              s.vehicleLabel.toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
                color: hw.muted,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _vehicleButton(
                    hw,
                    icon: Icons.two_wheeler,
                    label: s.motorcycle,
                    selected: _vehicle == 'motorcycle',
                    onTap: () => setState(() {
                      _invalidate();
                      _vehicle = 'motorcycle';
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _vehicleButton(
                    hw,
                    icon: Icons.directions_car_outlined,
                    label: s.car,
                    selected: _vehicle == 'car',
                    onTap: () => setState(() {
                      _invalidate();
                      _vehicle = 'car';
                    }),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: hw.subtleSurface,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: hw.cardBorder),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _segmentTab(
                      hw,
                      label: s.leaveNow,
                      selected: !_scheduled,
                      onTap: () => setState(() {
                        _invalidate();
                        _scheduled = false;
                      }),
                    ),
                  ),
                  Expanded(
                    child: _segmentTab(
                      hw,
                      label: s.pickDepartureTitle,
                      selected: _scheduled,
                      onTap: () => setState(() {
                        _invalidate();
                        _scheduled = true;
                      }),
                    ),
                  ),
                ],
              ),
            ),
            if (_scheduled)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(
                      _departure == null
                          ? s.chooseDateTime
                          : '${_departure!.day}/${_departure!.month} ${_departure!.hour.toString().padLeft(2, '0')}:${_departure!.minute.toString().padLeft(2, '0')}',
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: _busy
                            ? [hw.offline, hw.offline]
                            : [hw.blue, hw.turquoise],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: _busy
                          ? null
                          : [
                              BoxShadow(
                                color: hw.blue.withValues(alpha: 0.28),
                                blurRadius: 14,
                                offset: const Offset(0, 5),
                              ),
                            ],
                    ),
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _busy ? null : () => _find(s),
                      icon: Icon(
                        _busy ? Icons.hourglass_top : Icons.arrow_forward,
                        size: 18,
                      ),
                      label: Text(_busy ? s.findingRoute : s.findRoute),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => setState(_invalidate),
                  child: Text(s.clearRoute),
                ),
              ],
            ),
            if (_message?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: hw.subtleSurface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: hw.cardBorder),
                  ),
                  child: Text(
                    _message!,
                    style: TextStyle(fontSize: 12, color: hw.ink),
                  ),
                ),
              ),
            if (_plan != null) ...[
              const SizedBox(height: 10),
              _routeCard(
                hw,
                s,
                s.routeRecommended,
                'recommended',
                _plan!.recommended,
                hw.blue,
              ),
              _routeCard(
                hw,
                s,
                s.routeShortest,
                'shortest',
                _plan!.shortest,
                const Color(0xFF6366F1),
              ),
              _routeCard(
                hw,
                s,
                s.routeLowestRisk,
                'lowest_risk',
                _plan!.lowestRisk,
                hw.turquoise,
              ),
              if (_plan!.otherRoutes.isNotEmpty)
                _otherRoutes(hw, s, _plan!.otherRoutes),
              const SizedBox(height: 8),
              Text(
                s.routeLegendColorNote,
                style: TextStyle(fontSize: 11, color: hw.muted),
              ),
              const SizedBox(height: 5),
              Text(
                s.routeLegendSourceNote,
                style: TextStyle(fontSize: 11, color: hw.muted),
              ),
              if (_plan!.routeById(_selectedRouteId) case final route?)
                _segmentDetails(hw, s, route),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pointBadge(String text, Color color) => Container(
    width: 24,
    height: 24,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w800,
      ),
    ),
  );

  Widget _vehicleButton(
    HeatWatchColors hw, {
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(13),
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 10),
      decoration: BoxDecoration(
        gradient: selected
            ? LinearGradient(colors: [hw.blue, hw.turquoise])
            : null,
        color: selected ? null : hw.subtleSurface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: selected ? Colors.transparent : hw.cardBorder,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: selected ? Colors.white : hw.muted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : hw.ink,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _segmentTab(
    HeatWatchColors hw, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
      decoration: BoxDecoration(
        color: selected ? hw.cardSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: selected ? Border.all(color: hw.cardBorder) : null,
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          color: selected ? hw.turquoise : hw.muted,
        ),
      ),
    ),
  );

  Widget _routeCard(
    HeatWatchColors hw,
    AppStrings s,
    String label,
    String role,
    RainRoute? route,
    Color color,
  ) {
    final isSelected = route != null && _selectedRouteId == route.id;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: isSelected
            ? color.withValues(alpha: 0.12)
            : hw.subtleSurface,
        border: Border.all(
          color: isSelected ? color : hw.cardBorder,
          width: isSelected ? 1.8 : 1,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: color, width: 4)),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ),
                if (route != null) ...[
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _duration(route.durationSeconds, s),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: color,
                        ),
                      ),
                      Text(
                        '${route.distanceKm.toStringAsFixed(1)} km',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: hw.muted,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            if (route == null) ...[
              const SizedBox(height: 8),
              Text(
                s.routeUnavailable,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: hw.muted,
                ),
              ),
            ] else ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: hw.cardSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: hw.cardBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.isVi ? 'MỨC CHỊU NHIỆT' : 'HEAT EXPOSURE',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: hw.muted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            s.isVi
                                ? 'Nóng bức ${s.routeRiskLabel(route.heatRisk)} · Đỉnh ${measurement(route.peakHeat)}'
                                : 'Heat ${s.routeRiskLabel(route.heatRisk)} · Peak ${measurement(route.peakHeat)}',
                            style: TextStyle(
                              color: routeRiskColor(route.heatRisk),
                              fontWeight: FontWeight.w700,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: hw.cardSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: hw.cardBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.isVi ? 'KHẢ NĂNG MƯA' : 'RAIN RISK',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: hw.muted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            s.isVi
                                ? 'Xác suất mưa cao nhất ${_percentage(route.peakRain)} · Open-Meteo'
                                : 'Peak rain ${_percentage(route.peakRain)} · Open-Meteo',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: hw.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _coverageBar(route, hw),
              const SizedBox(height: 6),
              Text(
                s.isVi
                    ? 'Theo thời gian tuyến: ESP32 ${_percentage(route.heatSources[RouteHeatSource.esp32], digits: 1)} · '
                          'LSTM ${_percentage(route.heatSources[RouteHeatSource.lstm], digits: 1)} · '
                          'Open-Meteo ${_percentage(route.heatSources[RouteHeatSource.openMeteo], digits: 1)}'
                    : 'Route share: ESP32 ${_percentage(route.heatSources[RouteHeatSource.esp32], digits: 1)} · '
                          'LSTM ${_percentage(route.heatSources[RouteHeatSource.lstm], digits: 1)} · '
                          'Open-Meteo ${_percentage(route.heatSources[RouteHeatSource.openMeteo], digits: 1)}',
                style: TextStyle(fontSize: 11, color: hw.muted),
              ),
              if (!route.heatComplete || !route.weatherComplete)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    s.isVi
                        ? 'Bao phủ: nóng bức ${_percentage(route.heatCoverage, digits: 1)} · mưa ${_percentage(route.rainCoverage, digits: 1)}'
                        : 'Coverage: heat ${_percentage(route.heatCoverage, digits: 1)} · rain ${_percentage(route.rainCoverage, digits: 1)}',
                    style: TextStyle(fontSize: 11, color: hw.muted),
                  ),
                ),
              if (_plan!.reasons[role] case final reason?)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    reason,
                    style: TextStyle(fontSize: 12, color: hw.ink),
                  ),
                ),
              if (role != 'recommended' && route.id == _plan!.recommendedId)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    s.sameAsRecommended,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: hw.blue,
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: () {
                  setState(() => _selectedRouteId = route.id);
                  widget.onRouteSelected?.call(route);
                },
                icon: Icon(
                  isSelected ? Icons.check_circle : Icons.map_outlined,
                  size: 18,
                ),
                label: Text(isSelected ? s.viewingOnMap : s.viewOnMap),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _coverageBar(RainRoute route, HeatWatchColors hw) {
    final esp = (route.heatSources[RouteHeatSource.esp32] ?? 0).clamp(0.0, 100.0);
    final lstm = (route.heatSources[RouteHeatSource.lstm] ?? 0).clamp(0.0, 100.0);
    final om = (route.heatSources[RouteHeatSource.openMeteo] ?? 0).clamp(0.0, 100.0);
    final total = esp + lstm + om;
    if (total <= 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 6,
        child: Row(
          children: [
            if (esp > 0)
              Expanded(
                flex: (esp * 10).round().clamp(1, 1000),
                child: Container(color: hw.turquoise),
              ),
            if (lstm > 0)
              Expanded(
                flex: (lstm * 10).round().clamp(1, 1000),
                child: Container(color: const Color(0xFF6366F1)),
              ),
            if (om > 0)
              Expanded(
                flex: (om * 10).round().clamp(1, 1000),
                child: Container(color: const Color(0xFF38BDF8)),
              ),
          ],
        ),
      ),
    );
  }

  String _duration(double seconds, AppStrings s) {
    final minutes = (seconds / 60).ceil();
    if (s.isVi) {
      return minutes < 60
          ? '$minutes phút'
          : '${minutes ~/ 60} giờ ${minutes % 60} phút';
    }
    return minutes < 60
        ? '${minutes}m'
        : '${minutes ~/ 60}h ${minutes % 60}m';
  }

  String _percentage(double? value, {int digits = 0}) =>
      value == null ? '—' : '${value.toStringAsFixed(digits)}%';

  Widget _otherRoutes(
    HeatWatchColors hw,
    AppStrings s,
    List<RainRoute> routes,
  ) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: Text(
      s.otherRoutesLabel(routes.length),
      style: TextStyle(fontWeight: FontWeight.w700, color: hw.blue),
    ),
    children: [
      for (final (index, route) in routes.indexed)
        _routeCard(
          hw,
          s,
          s.isVi ? 'Tuyến khác ${index + 1}' : 'Alternative ${index + 1}',
          route.id,
          route,
          hw.offline,
        ),
    ],
  );

  Widget _segmentDetails(
    HeatWatchColors hw,
    AppStrings s,
    RainRoute route,
  ) => ExpansionTile(
    key: ValueKey('segments-${route.id}'),
    tilePadding: EdgeInsets.zero,
    title: Text(
      s.segmentDetailsTitle,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: hw.ink,
      ),
    ),
    children: [
      for (final (index, segment) in route.segments.indexed)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            radius: 13,
            backgroundColor: routeRiskColor(segment.risk).withValues(alpha: 0.14),
            child: Icon(
              Icons.circle,
              size: 10,
              color: routeRiskColor(segment.risk),
            ),
          ),
          title: Text(
            '${s.isVi ? 'Đoạn' : 'Seg'} ${index + 1} · ${displayTime(segment.passedAt, date: false)} · ${s.routeRiskLabel(segment.risk)}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: hw.ink,
            ),
          ),
          subtitle: Text(
            [
              '${s.isVi ? 'Nóng bức' : 'Heat'} ${measurement(segment.heatIndex)} · ${s.routeHeatSourceLabel(segment.source)}',
              '${s.isVi ? 'Mưa' : 'Rain'} ${_percentage(segment.probability)} · Open-Meteo',
              if (segment.stationName != null)
                '${segment.stationName} · ${s.isVi ? 'Cách điểm đánh giá' : 'Distance'} ${measurement(segment.stationDistanceKm, 'km')}',
              if (segment.measuredAt != null)
                '${s.isVi ? 'Đo lúc' : 'Measured'} ${displayTime(segment.measuredAt, date: false)}',
              if (segment.temperature != null)
                '${s.temperatureLabel} ${measurement(segment.temperature)} · ${s.humidityLabel} ${measurement(segment.humidity, '%')}',
            ].join('\n'),
            style: TextStyle(fontSize: 12, color: hw.muted),
          ),
        ),
    ],
  );
}
