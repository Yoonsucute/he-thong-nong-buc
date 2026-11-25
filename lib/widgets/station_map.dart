import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_strings.dart';
import '../models/rain_route.dart';
import '../models/sensor.dart';
import '../services/user_location_service.dart';
import '../theme/app_theme.dart';
import 'dashboard_widgets.dart';

class StationMap extends StatefulWidget {
  const StationMap({
    super.key,
    required this.stations,
    required this.onSelect,
    this.selectedId,
    this.loadTiles = true,
    this.tileProvider,
    this.userPosition,
    this.routePlan,
    this.selectedRouteId,
    this.onLocate,
    this.locating = false,
  });
  final List<Station> stations;
  final ValueChanged<Station> onSelect;
  final String? selectedId;
  final bool loadTiles;
  final TileProvider? tileProvider;
  final UserPosition? userPosition;
  final RainPlan? routePlan;
  final String? selectedRouteId;
  final VoidCallback? onLocate;
  final bool locating;

  @override
  State<StationMap> createState() => _StationMapState();
}

class _StationMapState extends State<StationMap> {
  static final _alternativePattern = StrokePattern.dashed(
    segments: const [8, 7],
  );
  static final _modeledPattern = StrokePattern.dashed(segments: const [9, 6]);
  final _controller = MapController();
  bool _ready = false;
  bool _hasFittedLocations = false;
  String? _tileError;

  List<Station> get _located =>
      widget.stations.where((e) => e.hasLocation).toList();

  void _focusUser() {
    final position = widget.userPosition;
    if (!_ready || position == null) return;
    _hasFittedLocations = true;
    _controller.move(
      position.point,
      position.accuracy > 3000
          ? 12
          : position.accuracy > 500
          ? 14
          : 16,
    );
  }

  void _focusRoute() {
    final plan = widget.routePlan;
    if (!_ready || plan == null) return;
    _hasFittedLocations = true;
    final selected = plan.routeById(widget.selectedRouteId);
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(
          selected?.geometry ??
              plan.routes.expand((route) => route.geometry).toList(),
        ),
        padding: const EdgeInsets.all(35),
        maxZoom: 15,
      ),
    );
  }

  List<Polyline> _routeLines() {
    final plan = widget.routePlan;
    if (plan == null) return [];
    final selected = plan.routeById(widget.selectedRouteId) ?? plan.primary;
    return [
      for (final alternative in plan.routes)
        if (alternative != selected)
          Polyline(
            points: alternative.geometry,
            color: const Color(0xFF9A8AC1),
            strokeWidth: 4,
            pattern: _alternativePattern,
          ),
      Polyline(
        points: selected.geometry,
        color: selected.segments.isEmpty
            ? routeRiskColor(RouteRisk.unknown)
            : Colors.white,
        strokeWidth: 8,
      ),
      for (final segment in selected.segments)
        Polyline(
          points: selected.geometry.sublist(segment.start, segment.end + 1),
          color: routeRiskColor(segment.risk),
          strokeWidth: 5,
          pattern: segment.risk == RouteRisk.unknown
              ? const StrokePattern.dotted(spacingFactor: 1.8)
              : switch (segment.source) {
                  RouteHeatSource.lstm => const StrokePattern.dotted(
                    spacingFactor: 1.8,
                  ),
                  RouteHeatSource.openMeteo => _modeledPattern,
                  _ => const StrokePattern.solid(),
                },
        ),
    ];
  }

  void _focus() {
    if (!_ready) return;
    final points = _located;
    if (points.isEmpty) {
      _controller.move(const LatLng(13, 109), 5);
    } else if (points.length == 1) {
      _controller.move(
        LatLng(points.first.mapLatitude!, points.first.mapLongitude!),
        12,
      );
      _hasFittedLocations = true;
    } else {
      _controller.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(
            points.map((e) => LatLng(e.mapLatitude!, e.mapLongitude!)).toList(),
          ),
          padding: const EdgeInsets.fromLTRB(64, 120, 120, 48),
          maxZoom: 13,
        ),
      );
      _hasFittedLocations = true;
    }
  }

  @override
  void didUpdateWidget(covariant StationMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    if (widget.userPosition != null &&
        widget.userPosition != oldWidget.userPosition) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusUser();
      });
      return;
    }
    if (widget.routePlan != null &&
        (widget.routePlan != oldWidget.routePlan ||
            widget.selectedRouteId != oldWidget.selectedRouteId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusRoute();
      });
      return;
    }
    final needsInitialFit = !_hasFittedLocations && _located.isNotEmpty;
    final selectionChanged = widget.selectedId != oldWidget.selectedId;
    if (needsInitialFit || selectionChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_ready) return;
        final match = _located.where((e) => e.id == widget.selectedId);
        if (selectionChanged && match.isNotEmpty) {
          _controller.move(
            LatLng(match.first.mapLatitude!, match.first.mapLongitude!),
            13,
          );
          _hasFittedLocations = true;
        } else if (!_hasFittedLocations && _located.isNotEmpty) {
          _focus();
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hw = HeatWatchColors.of(context);
    final s = AppStrings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: hw.cardBorder),
            boxShadow: [
              BoxShadow(
                color: hw.cardShadow,
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(21),
            child: SizedBox(
              height: 370,
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _controller,
                    options: MapOptions(
                      initialCenter: const LatLng(13, 109),
                      initialZoom: 5,
                      minZoom: 3,
                      maxZoom: 19,
                      onMapReady: () {
                        _ready = true;
                        if (widget.routePlan != null) {
                          _focusRoute();
                        } else if (widget.userPosition != null) {
                          _focusUser();
                        } else {
                          _focus();
                        }
                      },
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                      ),
                    ),
                    children: [
                      if (widget.loadTiles)
                        TileLayer(
                          // Imagery only; do not overlay hybrid/reference labels.
                          urlTemplate:
                              'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                          maxNativeZoom: 19,
                          tileProvider: widget.tileProvider,
                          userAgentPackageName: 'com.example.he_thong_nong_buc',
                          errorTileCallback: (tile, error, stackTrace) {
                            if (mounted && _tileError == null) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) {
                                  setState(
                                    () => _tileError = s.isVi
                                        ? 'Không tải được ảnh nền. Kiểm tra Internet.'
                                        : 'Unable to load map tiles. Check Internet.',
                                  );
                                }
                              });
                            }
                          },
                        ),
                      PolylineLayer(polylines: _routeLines()),
                      if (_located.isNotEmpty)
                        CircleLayer(
                          circles: [
                            for (final station in _located) ...[
                              CircleMarker(
                                point: LatLng(
                                  station.mapLatitude!,
                                  station.mapLongitude!,
                                ),
                                radius: 450,
                                useRadiusInMeter: true,
                                color: levelColor(
                                  station.latest?.level ?? -1,
                                ).withValues(alpha: 0.16),
                                borderColor: levelColor(
                                  station.latest?.level ?? -1,
                                ).withValues(alpha: 0.48),
                                borderStrokeWidth: 1.5,
                              ),
                              CircleMarker(
                                point: LatLng(
                                  station.mapLatitude!,
                                  station.mapLongitude!,
                                ),
                                radius: 170,
                                useRadiusInMeter: true,
                                color: levelColor(
                                  station.latest?.level ?? -1,
                                ).withValues(alpha: 0.24),
                              ),
                            ],
                          ],
                        ),
                      if (widget.userPosition != null)
                        CircleLayer(
                          circles: [
                            CircleMarker(
                              point: widget.userPosition!.point,
                              radius: widget.userPosition!.accuracy,
                              useRadiusInMeter: true,
                              color: const Color(0x22155EEF),
                              borderColor: const Color(0x88155EEF),
                              borderStrokeWidth: 1.5,
                            ),
                          ],
                        ),
                      // Labels are tied to geographic coordinates and painted
                      // underneath device pins. They never intercept taps or drags.
                      IgnorePointer(
                        child: MarkerLayer(
                          markers: [
                            _island(
                              const LatLng(16.5414, 111.6853),
                              'Hoàng Sa',
                            ),
                            _island(
                              const LatLng(8.6444, 111.9192),
                              'Trường Sa',
                            ),
                          ],
                        ),
                      ),
                      MarkerLayer(
                        markers: [
                          for (final station in _located)
                            Marker(
                              point: LatLng(
                                station.mapLatitude!,
                                station.mapLongitude!,
                              ),
                              width: 112,
                              height: 110,
                              alignment: Alignment.topCenter,
                              child: _stationMarker(context, hw, s, station),
                            ),
                        ],
                      ),
                      if (widget.userPosition != null)
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: widget.userPosition!.point,
                              width: 148,
                              height: 20,
                              alignment: Alignment.center,
                              child: Semantics(
                                label: s.yourLocation,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  alignment: Alignment.center,
                                  children: [
                                    Positioned(
                                      bottom: 28,
                                      left: 0,
                                      right: 0,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: hw.cardSurface,
                                          border: Border.all(color: hw.blue),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: hw.cardShadow,
                                              blurRadius: 8,
                                            ),
                                          ],
                                        ),
                                        child: Text(
                                          s.yourLocation,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: hw.blue,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Container(
                                      key: const ValueKey('user-location-dot'),
                                      width: 20,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: const Color(0xFF155EEF),
                                        border: Border.all(
                                          color: Colors.white,
                                          width: 3,
                                        ),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Color(0x55155EEF),
                                            blurRadius: 8,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      decoration: BoxDecoration(
                        color: hw.cardSurface.withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: hw.cardBorder),
                        boxShadow: [
                          BoxShadow(
                            color: hw.cardShadow,
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.onLocate != null) ...[
                            _control(
                              hw,
                              Icons.my_location,
                              widget.locating ? s.locatingLabel : s.locateMe,
                              () {
                                if (!widget.locating) widget.onLocate!();
                              },
                              active: widget.locating,
                            ),
                            Divider(height: 1, color: hw.cardBorder),
                          ],
                          _control(
                            hw,
                            Icons.center_focus_strong,
                            s.allStationsTooltip,
                            _focus,
                          ),
                          Divider(height: 1, color: hw.cardBorder),
                          _control(
                            hw,
                            Icons.add,
                            s.zoomInTooltip,
                            () => _controller.move(
                              _controller.camera.center,
                              (_controller.camera.zoom + 1).clamp(3, 19),
                            ),
                          ),
                          Divider(height: 1, color: hw.cardBorder),
                          _control(
                            hw,
                            Icons.remove,
                            s.zoomOutTooltip,
                            () => _controller.move(
                              _controller.camera.center,
                              (_controller.camera.zoom - 1).clamp(3, 19),
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
        ),
        const SizedBox(height: 8),
        Text(s.mapAttribution, style: TextStyle(fontSize: 10, color: hw.muted)),
        if (_tileError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _tileError!,
              style: TextStyle(color: hw.caution, fontSize: 12),
            ),
          ),
        if (_located.length < widget.stations.length)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              s.stationsAwaitingGps(widget.stations.length - _located.length),
              style: TextStyle(fontSize: 12, color: hw.muted),
            ),
          ),
      ],
    );
  }

  Widget _stationMarker(
    BuildContext context,
    HeatWatchColors hw,
    AppStrings s,
    Station station,
  ) {
    final activePin = station.online && !station.isLastKnown;
    final pinColor = activePin
        ? adaptiveLevelColor(context, station.latest?.level ?? -1)
        : hw.offline;
    final selected = station.id == widget.selectedId;
    return Semantics(
      key: ValueKey('device-pin-${station.id}'),
      button: true,
      label:
          'Thiết bị ${station.id}, ${station.name}, '
          '${station.online ? 'đang kết nối' : 'vị trí đã lưu, mất tín hiệu'}, ${station.locationDescription}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onSelect(station),
        child: Column(
          children: [
            Container(
              height: 70,
              width: 112,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: hw.cardSurface,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: selected
                      ? hw.blue
                      : activePin
                      ? pinColor
                      : hw.cardBorder,
                  width: selected ? 2 : 1.3,
                ),
                boxShadow: [
                  BoxShadow(
                    color: hw.cardShadow,
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Text(
                    station.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: hw.ink,
                    ),
                  ),
                  Text(
                    station.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: hw.muted),
                  ),
                  Text(
                    station.locationSource == 'lbs'
                        ? (s.isVi ? 'LBS · Ước lượng' : 'LBS · Approx')
                        : s.locationSourceLabel(station.locationSource),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: hw.caution,
                    ),
                  ),
                  Text(
                    station.isLastKnown
                        ? (s.isVi ? 'Vị trí gần nhất' : 'Last known')
                        : station.online
                        ? measurement(station.latest?.heatIndex)
                        : (s.isVi
                              ? 'Mất tín hiệu · Vị trí đã lưu'
                              : 'Offline · Saved fix'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: station.online ? pinColor : hw.offline,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.location_on, size: 40, color: pinColor),
          ],
        ),
      ),
    );
  }

  Widget _control(
    HeatWatchColors hw,
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    bool active = false,
  }) => SizedBox(
    width: 42,
    height: 40,
    child: IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 20, color: active ? hw.turquoise : hw.blue),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
    ),
  );

  Marker _island(LatLng point, String name) => Marker(
    point: point,
    width: 92,
    height: 32,
    child: Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF0F4C81),
        border: Border.all(color: const Color(0xFFC4DCF6)),
        borderRadius: BorderRadius.circular(7),
        boxShadow: const [
          BoxShadow(
            color: Color(0x400F2942),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        name,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}
