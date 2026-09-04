import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme.dart';

/// Verlaufskurve mit gefüllter Fläche. Eigener Painter statt Chart-Bibliothek:
/// bei 1 Hz und 90 Punkten ist das billiger und lässt sich exakt in die
/// Instrumentenleiste einpassen.
class Sparkline extends StatelessWidget {
  const Sparkline({
    required this.values,
    required this.color,
    this.min,
    this.max,
    this.strokeWidth = 1.6,
    this.showLastPoint = true,
    this.baselineGrid = false,
    super.key,
  });

  final List<double> values;
  final Color color;
  final double? min;
  final double? max;
  final double strokeWidth;
  final bool showLastPoint;
  final bool baselineGrid;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SparkPainter(
        values: values,
        color: color,
        min: min,
        max: max,
        strokeWidth: strokeWidth,
        showLastPoint: showLastPoint,
        baselineGrid: baselineGrid,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.values,
    required this.color,
    required this.min,
    required this.max,
    required this.strokeWidth,
    required this.showLastPoint,
    required this.baselineGrid,
  });

  final List<double> values;
  final Color color;
  final double? min;
  final double? max;
  final double strokeWidth;
  final bool showLastPoint;
  final bool baselineGrid;

  @override
  void paint(Canvas canvas, Size size) {
    if (baselineGrid) _paintGrid(canvas, size);
    if (values.length < 2) {
      _paintEmpty(canvas, size);
      return;
    }

    final lower = min ?? values.reduce(math.min);
    var upper = max ?? values.reduce(math.max);
    if (upper - lower < 1e-6) upper = lower + 1;

    final dx = size.width / (values.length - 1);
    Offset pointAt(int i) {
      final normalised = ((values[i] - lower) / (upper - lower)).clamp(0.0, 1.0);
      return Offset(dx * i, size.height - normalised * size.height);
    }

    final line = Path()..moveTo(0, pointAt(0).dy);
    for (var i = 1; i < values.length; i++) {
      final p = pointAt(i);
      final prev = pointAt(i - 1);
      // Leichte Glättung, damit die Kurve bei 1 Hz nicht zackig wirkt.
      final controlX = (prev.dx + p.dx) / 2;
      line.cubicTo(controlX, prev.dy, controlX, p.dy, p.dx, p.dy);
    }

    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(
      area,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, 0),
          Offset(0, size.height),
          [color.withValues(alpha: 0.28), color.withValues(alpha: 0.02)],
        ),
    );

    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = color,
    );

    if (showLastPoint) {
      final last = pointAt(values.length - 1);
      canvas
        ..drawCircle(last, strokeWidth * 2.4, Paint()..color = Tone.base)
        ..drawCircle(last, strokeWidth * 1.4, Paint()..color = color);
    }
  }

  void _paintGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Tone.hairline
      ..strokeWidth = 1;
    for (final fraction in const [0.25, 0.5, 0.75]) {
      final y = size.height * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  void _paintEmpty(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Tone.hairline
      ..strokeWidth = 1;
    final y = size.height - 1;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values.length != values.length ||
      (values.isNotEmpty && old.values.isNotEmpty && old.values.last != values.last) ||
      old.color != color;
}

/// Waagerechter Füllbalken für Anteile (RAM, VRAM, Kontext).
class FillBar extends StatelessWidget {
  const FillBar({
    required this.fraction,
    required this.color,
    this.height = 4,
    this.track = Tone.hairline,
    super.key,
  });

  final double? fraction;
  final Color color;
  final double height;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: fraction == null
            // Kein Anteil bekannt: gestrichelte Spur statt Balken bei Null,
            // der sonst wie "nichts belegt" aussieht.
            ? CustomPaint(painter: _UnknownTrackPainter(track))
            : Stack(
                children: [
                  Container(color: track),
                  FractionallySizedBox(
                    widthFactor: fraction!.clamp(0.0, 1.0),
                    child: Container(color: color),
                  ),
                ],
              ),
      ),
    );
  }
}

class _UnknownTrackPainter extends CustomPainter {
  _UnknownTrackPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.height;
    const dash = 4.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(math.min(x + dash, size.width), size.height / 2),
        paint,
      );
      x += dash * 2;
    }
  }

  @override
  bool shouldRepaint(_UnknownTrackPainter old) => old.color != color;
}
