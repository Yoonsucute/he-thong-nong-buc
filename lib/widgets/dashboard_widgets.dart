import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/rain_route.dart';
import '../models/sensor.dart';
import '../theme/app_theme.dart';

Color routeRiskColor(RouteRisk risk) => switch (risk) {
  RouteRisk.low => const Color(0xFF0D9488),
  RouteRisk.moderate => const Color(0xFFD97706),
  RouteRisk.high => const Color(0xFFDC2626),
  RouteRisk.unknown => const Color(0xFF64748B),
};

class SkyBackdrop extends StatelessWidget {
  const SkyBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hw = HeatWatchColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [hw.skyTop, hw.skyMid, hw.skyBottom],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(.9, -.82),
            radius: .75,
            colors: [hw.skyGlow, hw.skyGlow.withValues(alpha: 0)],
          ),
        ),
        child: child,
      ),
    );
  }
}

BoxDecoration skyPanelDecoration([HeatWatchColors? hw]) {
  final colors = hw ?? HeatWatchColors.light;
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [colors.heroStart, colors.heroMid, colors.heroEnd],
      stops: const [0, 0.55, 1],
    ),
    borderRadius: BorderRadius.circular(24),
    boxShadow: [
      BoxShadow(
        color: colors.heroStart.withValues(alpha: 0.24),
        blurRadius: 24,
        offset: const Offset(0, 10),
      ),
    ],
  );
}

BoxDecoration elevatedCardDecoration(
  HeatWatchColors hw, {
  Color? borderColor,
  double radius = 20,
}) => BoxDecoration(
  color: hw.cardSurface,
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: borderColor ?? hw.cardBorder),
  boxShadow: [
    BoxShadow(
      color: hw.cardShadow,
      blurRadius: 18,
      offset: const Offset(0, 6),
    ),
  ],
);

Color levelColor(int level) => switch (level) {
  2 => const Color(0xFFDC2626),
  1 => const Color(0xFFD97706),
  0 => const Color(0xFF0D9488),
  _ => const Color(0xFF64748B),
};

Color adaptiveLevelColor(BuildContext context, int level) {
  final hw = HeatWatchColors.of(context);
  return switch (level) {
    2 => hw.danger,
    1 => hw.caution,
    0 => hw.safe,
    _ => hw.offline,
  };
}

Color _levelColorOnSky(int level) => switch (level) {
  2 => const Color(0xFFFFB4BA),
  1 => const Color(0xFFFDE68A),
  0 => const Color(0xFF99F6E4),
  _ => const Color(0xFFE2EEFF),
};

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.level, this.onDark = false});
  final int level;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final color = onDark
        ? _levelColorOnSky(level)
        : adaptiveLevelColor(context, level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: onDark ? .18 : .12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: onDark ? .35 : .25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            level > 0
                ? Icons.warning_amber_rounded
                : level == 0
                ? Icons.check_circle_outline
                : Icons.help_outline,
            color: color,
            size: 15,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              s.warningLabel(level),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final hw = HeatWatchColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: TextStyle(fontSize: 12, color: hw.muted),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class MessageCard extends StatelessWidget {
  const MessageCard({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.sensors_off_outlined,
    this.onRetry,
  });
  final String title, message;
  final IconData icon;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final hw = HeatWatchColors.of(context);
    final s = AppStrings.of(context);
    return Container(
      decoration: elevatedCardDecoration(hw),
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: hw.turquoise.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: hw.turquoise, size: 30),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: hw.muted, fontSize: 13),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(s.retry),
            ),
          ],
        ],
      ),
    );
  }
}

class Metrics extends StatelessWidget {
  const Metrics({super.key, required this.reading});
  final Reading? reading;
  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final hw = HeatWatchColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HeatIndexCard(reading: reading),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, size) {
            final width = (size.maxWidth - 12) / 2;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _metric(
                  context,
                  hw,
                  width,
                  Icons.thermostat,
                  s.temperatureLabel,
                  measurement(reading?.temperature),
                  const Color(0xFFF59E0B),
                ),
                _metric(
                  context,
                  hw,
                  width,
                  Icons.water_drop_outlined,
                  s.humidityLabel,
                  measurement(reading?.humidity, '%'),
                  hw.turquoise,
                  fraction: reading?.humidity == null
                      ? null
                      : (reading!.humidity! / 100).clamp(0.0, 1.0),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _metric(
    BuildContext context,
    HeatWatchColors hw,
    double width,
    IconData icon,
    String title,
    String value,
    Color color, {
    double? fraction,
  }) => SizedBox(
    width: width,
    child: Container(
      decoration: elevatedCardDecoration(hw, radius: 18),
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 16),
              ),
              const Spacer(),
              if (fraction != null)
                SizedBox.square(
                  dimension: 34,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: ExcludeSemantics(
                          child: CircularProgressIndicator(
                            value: fraction,
                            strokeWidth: 3.2,
                            strokeCap: StrokeCap.round,
                            backgroundColor: hw.cardBorder,
                            color: color,
                          ),
                        ),
                      ),
                      Text(
                        '${(fraction * 100).round()}%',
                        style: TextStyle(
                          fontSize: 8.5,
                          fontWeight: FontWeight.w800,
                          color: hw.ink,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: hw.subtleSurface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: hw.cardBorder),
                  ),
                  child: Text(
                    'ESP32',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: hw.muted,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: hw.muted,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: hw.ink,
                fontSize: 25,
                letterSpacing: -0.6,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class HeatIndexCard extends StatelessWidget {
  const HeatIndexCard({super.key, required this.reading});
  final Reading? reading;

  double? _spectrumFraction(double? heat) {
    if (heat == null) return null;
    if (heat <= 32) return ((heat - 20) / 12 * 0.476).clamp(0.02, 0.476);
    if (heat <= 38) return 0.476 + (heat - 32) / 6 * 0.286;
    return (0.762 + (heat - 38) / 6 * 0.238).clamp(0.762, 0.98);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final hw = HeatWatchColors.of(context);
    final level = reading?.level ?? -1;
    final hasIndex = reading?.heatIndex != null;
    final heatColor = _levelColorOnSky(level);
    final fraction = _spectrumFraction(reading?.heatIndex);
    return Container(
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
                child: Icon(
                  Icons.thermostat_outlined,
                  color: heatColor,
                  size: 18,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  s.heatIndexCardHeader,
                  style: const TextStyle(
                    color: Color(0xFFEAF4FF),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  reading?.heatIndex?.toStringAsFixed(1) ?? '—',
                  style: TextStyle(
                    fontSize: 68,
                    height: 1,
                    letterSpacing: -3,
                    fontWeight: FontWeight.w700,
                    color: heatColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (hasIndex) ...[
                  const SizedBox(width: 6),
                  const Text(
                    '°C',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFE5F0FF),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          StatusBadge(level: level, onDark: true),
          if (fraction != null) ...[
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) => Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 48,
                        child: Container(
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Color(0xFF2DD4BF),
                            borderRadius: BorderRadius.horizontal(
                              left: Radius.circular(999),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        flex: 28,
                        child: Container(
                          height: 6,
                          color: const Color(0xFFFBBF24),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        flex: 24,
                        child: Container(
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Color(0xFFF87171),
                            borderRadius: BorderRadius.horizontal(
                              right: Radius.circular(999),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    left: (constraints.maxWidth * fraction - 7).clamp(
                      0.0,
                      math.max(0.0, constraints.maxWidth - 14),
                    ),
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF0F2942),
                          width: 3,
                        ),
                        boxShadow: const [
                          BoxShadow(color: Color(0x55000000), blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    s.thresholdScaleSafe,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFFD0E7FF),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  '32°C',
                  style: TextStyle(fontSize: 10, color: Color(0xFFD0E7FF)),
                ),
                const SizedBox(width: 6),
                const Text(
                  '38°C+',
                  style: TextStyle(fontSize: 10, color: Color(0xFFD0E7FF)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class StationQuickView extends StatelessWidget {
  const StationQuickView({
    super.key,
    required this.station,
    required this.onDetails,
  });
  final Station station;
  final VoidCallback onDetails;
  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final hw = HeatWatchColors.of(context);
    final onlineColor = station.online ? hw.safe : hw.muted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    station.name,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: hw.ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: onlineColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          station.online
                              ? '● ${s.stationConnected}'
                              : '○ ${s.stationLostSignal}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: onlineColor,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: hw.subtleSurface,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: hw.cardBorder),
                        ),
                        child: Text(
                          station.id,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: hw.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Metrics(reading: station.latest),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: hw.subtleSurface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: hw.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.schedule, size: 15, color: hw.blue),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      s.relativeUpdateText(
                        station.latest?.createdAt ?? station.lastSeen,
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: hw.ink,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    station.locationSource == 'gps'
                        ? Icons.gps_fixed
                        : Icons.cell_tower,
                    size: 15,
                    color: station.locationSource == 'lbs'
                        ? hw.caution
                        : hw.turquoise,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      s.stationLocationDescription(station),
                      style: TextStyle(fontSize: 11, color: hw.muted),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (!station.online)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              s.quickViewCachedNotice,
              style: TextStyle(fontSize: 12, color: hw.muted),
            ),
          ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: onDetails,
          icon: const Icon(Icons.arrow_forward_rounded, size: 18),
          label: Text(s.viewDetails),
        ),
      ],
    );
  }
}

class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.values,
    this.labels = const [],
    this.forecast = false,
  });
  final List<double> values;
  final List<String> labels;
  final bool forecast;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const SizedBox.shrink();
    final hw = HeatWatchColors.of(context);
    final s = AppStrings.of(context);
    final minValue = values.reduce(math.min).floorToDouble() - 1;
    final maxValue = math.max(
      values.reduce(math.max).ceilToDouble() + 1,
      minValue + 4,
    );
    return Semantics(
      label:
          '${forecast ? (s.isVi ? 'Dự báo' : 'Forecast') : (s.isVi ? 'Lịch sử' : 'History')} '
          '${s.heatIndexLabel}: ${values.map((e) => e.toStringAsFixed(1)).join(', ')} °C',
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '${maxValue.toStringAsFixed(0)} °C',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: hw.muted,
                ),
              ),
              const Spacer(),
              Text(
                forecast
                    ? (s.isVi ? '5 giờ tiếp theo' : 'Next 5 hours')
                    : (s.isVi
                          ? '${values.length} lần đo'
                          : '${values.length} readings'),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: hw.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 150,
            width: double.infinity,
            child: CustomPaint(
              painter: _TrendPainter(
                values,
                minValue,
                maxValue,
                forecast,
                hw: hw,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${minValue.toStringAsFixed(0)} °C',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: hw.muted,
              ),
            ),
          ),
          if (labels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: labels
                    .map(
                      (e) => Flexible(
                        child: Text(
                          e,
                          style: TextStyle(fontSize: 11, color: hw.muted),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(
    this.values,
    this.low,
    this.high,
    this.forecast, {
    required this.hw,
  });
  final List<double> values;
  final double low, high;
  final bool forecast;
  final HeatWatchColors hw;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 8.0;
    final area = Rect.fromLTRB(
      inset,
      inset,
      size.width - inset,
      size.height - inset,
    );
    final grid = Paint()
      ..color = hw.chartGrid
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = area.top + area.height * i / 3;
      canvas.drawLine(Offset(area.left, y), Offset(area.right, y), grid);
    }

    for (final (threshold, color) in [
      (32.0, hw.caution.withValues(alpha: 0.45)),
      (38.0, hw.danger.withValues(alpha: 0.45)),
    ]) {
      if (threshold >= low && threshold <= high) {
        final y = area.bottom - (threshold - low) / (high - low) * area.height;
        final dashPaint = Paint()
          ..color = color
          ..strokeWidth = 1.2;
        for (double x = area.left; x < area.right; x += 8) {
          canvas.drawLine(
            Offset(x, y),
            Offset(math.min(x + 4, area.right), y),
            dashPaint,
          );
        }
      }
    }

    final points = List.generate(
      values.length,
      (i) => Offset(
        area.left +
            area.width * (values.length == 1 ? .5 : i / (values.length - 1)),
        area.bottom - (values[i] - low) / (high - low) * area.height,
      ),
    );

    final line = Path()..moveTo(points.first.dx, points.first.dy);
    if (points.length == 2) {
      line.lineTo(points[1].dx, points[1].dy);
    } else {
      for (var i = 0; i < points.length - 1; i++) {
        final p0 = points[i];
        final p1 = points[i + 1];
        final midX = (p0.dx + p1.dx) / 2;
        line.cubicTo(midX, p0.dy, midX, p1.dy, p1.dx, p1.dy);
      }
    }

    final fill = Path.from(line)
      ..lineTo(points.last.dx, area.bottom)
      ..lineTo(points.first.dx, area.bottom)
      ..close();
    final color = forecast ? hw.blue : hw.turquoise;
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .28), color.withValues(alpha: .01)],
        ).createShader(area),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    if (values.length <= 12) {
      for (var i = 0; i < points.length; i++) {
        final point = points[i];
        final dotColor = switch (warningLevel(values[i])) {
          2 => hw.danger,
          1 => hw.caution,
          0 => hw.safe,
          _ => color,
        };
        canvas.drawCircle(point, 5.5, Paint()..color = hw.cardSurface);
        canvas.drawCircle(point, 3.6, Paint()..color = dotColor);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.low != low ||
      oldDelegate.high != high ||
      oldDelegate.forecast != forecast ||
      oldDelegate.hw != hw;
}
