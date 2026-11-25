import 'package:latlong2/latlong.dart';

import 'sensor.dart';

enum RouteRisk {
  low('Thấp'),
  moderate('Cảnh báo'),
  high('Cao'),
  unknown('Chưa đủ dữ liệu');

  const RouteRisk(this.label);
  final String label;
  static RouteRisk fromJson(Object? value) =>
      values.where((risk) => risk.name == value).firstOrNull ?? unknown;
}

enum RouteHeatSource {
  esp32('esp32', 'ESP32 + SHT31'),
  lstm('lstm', 'Dự báo LSTM'),
  openMeteo('open_meteo', 'Ước tính từ Open-Meteo'),
  unknown('unknown', 'Chưa có nguồn');

  const RouteHeatSource(this.key, this.label);
  final String key, label;
  static RouteHeatSource fromJson(Object? value) =>
      values.where((source) => source.key == value).firstOrNull ?? unknown;
}

class RouteSegment {
  RouteSegment(Map<String, dynamic> data)
    : start = data['start_index'] as int,
      end = data['end_index'] as int,
      risk = RouteRisk.fromJson(data['risk']),
      source = RouteHeatSource.fromJson(data['heat_source']),
      passedAt = parseTime(data['passed_at']),
      measuredAt = parseTime(data['measured_at']),
      heatIndex = number(data['heat_index']),
      temperature = number(data['temperature']),
      humidity = number(data['humidity']),
      probability = number(data['probability_percent']),
      stationName = data['station_name'] as String?,
      stationDistanceKm = number(data['station_distance_km']);

  final int start, end;
  final RouteRisk risk;
  final RouteHeatSource source;
  final DateTime? passedAt, measuredAt;
  final double? heatIndex,
      temperature,
      humidity,
      probability,
      stationDistanceKm;
  final String? stationName;
}

class RainRoute {
  RainRoute(Map<String, dynamic> data)
    : id = data['id'] as String,
      distanceKm = (data['distance_km'] as num).toDouble(),
      durationSeconds = (data['duration_seconds'] as num).toDouble(),
      weatherComplete = data['weather_complete'] == true,
      heatComplete = data['heat_complete'] == true,
      heatRisk = RouteRisk.fromJson(data['heat_risk']),
      peakHeat = number(data['max_heat_index']),
      peakRain = number(data['max_rain_probability']),
      rainCoverage = number(data['weather_coverage_percent']),
      heatCoverage = number(data['heat_coverage_percent']),
      heatSources = {
        for (final source in RouteHeatSource.values)
          source: number((data['heat_source_percent'] as Map?)?[source.key]),
      },
      geometry = (data['geometry'] as List)
          .map(
            (p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          )
          .toList(),
      segments = (data['segments'] as List)
          .map((s) => RouteSegment(Map<String, dynamic>.from(s as Map)))
          .toList();
  final String id;
  final double distanceKm, durationSeconds;
  final bool weatherComplete, heatComplete;
  final RouteRisk heatRisk;
  final double? peakHeat, peakRain, rainCoverage, heatCoverage;
  final Map<RouteHeatSource, double?> heatSources;
  final List<LatLng> geometry;
  final List<RouteSegment> segments;
}

class RainPlan {
  RainPlan(Map<String, dynamic> data)
    : routes = (data['routes'] as List)
          .map((r) => RainRoute(Map<String, dynamic>.from(r as Map)))
          .toList(),
      recommendedId = data['recommended_route_id'] as String?,
      lowestRiskId = data['lowest_risk_route_id'] as String?,
      shortestId = data['shortest_route_id'] as String,
      reasons = Map<String, String>.from(data['reasons'] as Map? ?? {}),
      warnings = (data['warnings'] as List? ?? []).map((w) => '$w').toList();
  final List<RainRoute> routes;
  final String? recommendedId, lowestRiskId;
  final String shortestId;
  final List<String> warnings;
  final Map<String, String> reasons;
  RainRoute? routeById(String? id) =>
      routes.where((r) => r.id == id).firstOrNull;
  RainRoute? get recommended => routeById(recommendedId);
  RainRoute? get lowestRisk => routeById(lowestRiskId);
  RainRoute get shortest => routes.firstWhere((r) => r.id == shortestId);
  RainRoute get primary => recommended ?? shortest;
  List<RainRoute> get otherRoutes => routes
      .where(
        (route) =>
            !{shortestId, recommendedId, lowestRiskId}.contains(route.id),
      )
      .toList();
}
