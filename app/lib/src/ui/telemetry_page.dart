import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/fact.dart';
import '../models/telemetry.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'format.dart';
import 'widgets/fact_view.dart';
import 'widgets/instruments.dart';

class TelemetryPage extends ConsumerWidget {
  const TelemetryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(telemetryProvider);
    final latest = feed.latest;
    final gpu = latest?.primaryGpu;
    final wide = MediaQuery.sizeOf(context).width >= 720;

    return Scaffold(
      appBar: AppBar(
        title: const Text('System'),
        actions: [
          IconButton(
            tooltip: 'Neu verbinden',
            icon: const Icon(Icons.refresh),
            onPressed: ref.read(telemetryProvider.notifier).reconnectNow,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
        children: [
          if (!feed.connected || feed.isStale)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: StaleBanner(
                age: feed.age,
                reconnectIn: feed.reconnectIn,
                error: feed.error,
                onRetry: ref.read(telemetryProvider.notifier).reconnectNow,
              ),
            ),

          if (latest == null)
            const _NoData()
          else ...[
            GridView.count(
              crossAxisCount: wide ? 2 : 1,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: wide ? 2.6 : 3.4,
              children: [
                Instrument(
                  label: 'CPU',
                  color: Tone.teal,
                  series: feed.seriesCpu(),
                  stale: feed.isStale,
                  value: InstrumentValue(
                    latest.cpuPercent,
                    format: (v) => v.toStringAsFixed(0),
                    unit: '%',
                  ),
                  fraction: latest.cpuPercent.value == null
                      ? null
                      : latest.cpuPercent.value! / 100,
                ),
                Instrument(
                  label: 'Arbeitsspeicher',
                  color: Tone.violet,
                  series: feed.seriesRam(),
                  stale: feed.isStale,
                  value: InstrumentValue(
                    Fact<double>(
                      value: latest.ramUsedBytes.value == null
                          ? null
                          : latest.ramUsedBytes.value! / (1024 * 1024 * 1024),
                      certainty: latest.ramUsedBytes.certainty,
                      note: latest.ramUsedBytes.note,
                    ),
                    format: (v) => v.toStringAsFixed(1),
                    unit: 'GiB',
                  ),
                  detail: latest.ramTotalBytes.isKnown
                      ? Text('von ${formatGiB(latest.ramTotalBytes.value!)} GiB')
                      : const Text('Gesamtgröße unbekannt'),
                  fraction: latest.ramFraction,
                ),
                if (gpu != null) ...[
                  Instrument(
                    label: 'GPU-Last · ${gpu.name}',
                    color: Tone.amber,
                    series: feed.seriesGpu(),
                    stale: feed.isStale,
                    value: InstrumentValue(
                      gpu.utilPercent,
                      format: (v) => v.toStringAsFixed(0),
                      unit: '%',
                    ),
                    detail: Text('Quelle: ${gpu.source}'),
                    fraction: gpu.utilPercent.value == null
                        ? null
                        : gpu.utilPercent.value! / 100,
                  ),
                  Instrument(
                    label: 'VRAM',
                    color: Tone.alert,
                    series: feed.seriesVram(),
                    stale: feed.isStale,
                    value: InstrumentValue(
                      Fact<double>(
                        value: gpu.vramUsedBytes.value == null
                            ? null
                            : gpu.vramUsedBytes.value! / (1024 * 1024 * 1024),
                        certainty: gpu.vramUsedBytes.certainty,
                        note: gpu.vramUsedBytes.note,
                      ),
                      format: (v) => v.toStringAsFixed(1),
                      unit: 'GiB',
                    ),
                    detail: gpu.vramTotalBytes.isKnown
                        ? Text('von ${formatGiB(gpu.vramTotalBytes.value!)} GiB')
                        : const Text('Gesamtgröße unbekannt'),
                    fraction: gpu.vramFraction,
                  ),
                ],
              ],
            ),

            if (gpu == null) _NoGpu(note: latest.gpuNote),
            if (gpu != null) _GpuDetails(gpu: gpu),

            const SizedBox(height: 18),
            _Footer(sample: latest, samples: feed.history.length),
          ],
        ],
      ),
    );
  }
}

class _GpuDetails extends StatelessWidget {
  const _GpuDetails({required this.gpu});

  final GpuSample gpu;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: Tone.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Tone.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(gpu.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          FactRow(
            'Temperatur',
            FactText<double>(
              gpu.tempC,
              format: (v) => '${v.toStringAsFixed(0)} °C',
              mono: true,
            ),
          ),
          FactRow(
            'Leistungsaufnahme',
            FactText<double>(
              gpu.powerWatts,
              format: (v) => '${v.toStringAsFixed(0)} W',
              mono: true,
            ),
          ),
          FactRow('Hersteller', Text(gpu.vendor.toUpperCase())),
          FactRow('Auslesequelle', Text(gpu.source)),
        ],
      ),
    );
  }
}

/// Kein GPU-Wert ist ein eigener Zustand, nicht "0 %". Der Grund vom Gateway
/// steht direkt hier, damit man weiß, was zu installieren ist.
class _NoGpu extends StatelessWidget {
  const _NoGpu({required this.note});

  final String? note;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Tone.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Tone.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.videocam_off_outlined,
                  size: 16, color: Tone.muted),
              const SizedBox(width: 8),
              Text(
                'Keine GPU-Werte',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            note ??
                'Das Gateway hat keine GPU gemeldet und keinen Grund mitgeliefert.',
            style: const TextStyle(fontSize: 12.5, color: Tone.muted, height: 1.45),
          ),
          const SizedBox(height: 8),
          const Text(
            'Unter Windows liest amdgpu_top die Radeon-Werte aus; die Exe muss '
            'im PATH des Gateway-Prozesses liegen.',
            style: TextStyle(fontSize: 12, color: Tone.faint, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _NoData extends StatelessWidget {
  const _NoData();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        children: [
          const Icon(Icons.monitor_heart_outlined, size: 34, color: Tone.faint),
          const SizedBox(height: 12),
          Text(
            'Noch keine Messwerte',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            'Sobald die Verbindung zum Gateway steht, läuft hier ein Wert pro Sekunde ein.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: Tone.muted, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.sample, required this.samples});

  final TelemetrySample sample;
  final int samples;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.schedule, size: 12, color: Tone.faint),
        const SizedBox(width: 6),
        Text(
          'Messung ${formatClock(sample.at)} · $samples Punkte im Verlauf',
          style: const TextStyle(fontSize: 11.5, color: Tone.faint),
        ),
      ],
    );
  }
}
