import 'package:flutter/material.dart';

import '../../models/fact.dart';
import '../../theme.dart';
import '../format.dart';
import 'fact_view.dart';
import 'sparkline.dart';

/// Ein Instrument: Kurve als Hintergrund, Zahl im Vordergrund. Die Kurve ist
/// hier bewusst Untergrund und nicht Hauptmotiv — im Chat zählt der aktuelle
/// Wert, der Verlauf gibt nur Kontext.
class Instrument extends StatelessWidget {
  const Instrument({
    required this.label,
    required this.value,
    required this.series,
    required this.color,
    this.detail,
    this.fraction,
    this.min = 0,
    this.max = 100,
    this.stale = false,
    this.compact = false,
    this.onTap,
    super.key,
  });

  final String label;
  final Widget value;
  final List<double> series;
  final Color color;
  final Widget? detail;
  final double? fraction;
  final double min;
  final double? max;
  final bool stale;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final height = compact ? 52.0 : 96.0;
    final tint = stale ? color.withValues(alpha: 0.35) : color;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Tone.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Tone.hairline),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: EdgeInsets.only(top: compact ? 18 : 34),
              child: Sparkline(
                values: series,
                color: tint,
                min: min,
                max: max,
                strokeWidth: compact ? 1.2 : 1.7,
                baselineGrid: !compact,
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 12,
                vertical: compact ? 6 : 10,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: compact ? 10.5 : 12,
                          color: Tone.muted,
                          letterSpacing: 0.2,
                        ),
                      ),
                      if (stale) ...[
                        const SizedBox(width: 5),
                        const Icon(Icons.history_toggle_off,
                            size: 11, color: Tone.amber),
                      ],
                    ],
                  ),
                  const SizedBox(height: 1),
                  DefaultTextStyle.merge(
                    style: kMono.copyWith(
                      fontSize: compact ? 15 : 22,
                      color: stale ? Tone.muted : Tone.ink,
                      fontWeight: FontWeight.w500,
                      height: 1.1,
                    ),
                    child: value,
                  ),
                  if (detail != null && !compact) ...[
                    const Spacer(),
                    DefaultTextStyle.merge(
                      style: const TextStyle(fontSize: 11.5, color: Tone.muted),
                      child: detail!,
                    ),
                  ],
                  if (fraction != null && !compact) ...[
                    const SizedBox(height: 6),
                    FillBar(fraction: fraction, color: tint),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Zahl aus einem Fact, im Instrumentenformat.
class InstrumentValue extends StatelessWidget {
  const InstrumentValue(this.fact, {required this.format, this.unit, super.key});

  final Fact<double> fact;
  final String Function(double) format;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        FactText<double>(fact, format: format, mono: true),
        if (unit != null && fact.isKnown)
          Text(
            ' $unit',
            style: const TextStyle(fontSize: 12, color: Tone.muted),
          ),
      ],
    );
  }
}

/// Hinweisband, wenn die Telemetrie veraltet oder abgerissen ist. Der letzte
/// Stand bleibt sichtbar, aber datiert — nicht als aktuell verkauft.
class StaleBanner extends StatelessWidget {
  const StaleBanner({
    required this.age,
    required this.reconnectIn,
    required this.error,
    required this.onRetry,
    super.key,
  });

  final Duration? age;
  final Duration? reconnectIn;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (age != null) 'Stand ${formatAgo(age!)}',
      if (reconnectIn != null)
        'neuer Versuch in ${reconnectIn!.inSeconds} s',
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Tone.amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Tone.amber.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.link_off, size: 16, color: Tone.amber),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Telemetrie unterbrochen${parts.isEmpty ? '' : ' — ${parts.join(', ')}'}',
                  style: const TextStyle(fontSize: 12.5, color: Tone.ink),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: const TextStyle(fontSize: 11.5, color: Tone.muted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Neu verbinden')),
        ],
      ),
    );
  }
}
