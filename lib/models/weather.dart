import 'sensor.dart';

class CurrentWeather {
  CurrentWeather.fromJson(Map<String, dynamic> json)
    : time = (json['time'] as String).substring(11, 16),
      temperature = number(json['temperature']),
      humidity = number(json['humidity']),
      rainProbability = number(json['rain_probability']),
      icon = json['icon'] as String,
      description = json['description'] as String,
      rainUntil = (json['rain_until'] as String?)?.substring(11, 16);

  final String time, icon, description;
  final String? rainUntil;
  final double? temperature, humidity, rainProbability;
}

class LocalWeather {
  LocalWeather.fromJson(Map<String, dynamic> json)
    : current = CurrentWeather.fromJson(
        json['current'] as Map<String, dynamic>,
      );

  final CurrentWeather current;
}
