import 'fact.dart';

class GpuSample {
  const GpuSample({
    required this.name,
    required this.vendor,
    required this.source,
    required this.utilPercent,
    required this.vramUsedBytes,
    required this.vramTotalBytes,
    required this.tempC,
    required this.powerWatts,
  });

  final String name;
  final String vendor;

  /// Woher die Werte kommen (rocm-smi, amdgpu_top, …). Gehoert ins UI, weil
  /// die Quelle bestimmt, welche Felder überhaupt belegt sind.
  final String source;

  final Fact<double> utilPercent;
  final Fact<int> vramUsedBytes;
  final Fact<int> vramTotalBytes;
  final Fact<double> tempC;
  final Fact<double> powerWatts;

  double? get vramFraction {
    final used = vramUsedBytes.value;
    final total = vramTotalBytes.value;
    if (used == null || total == null || total == 0) return null;
    return used / total;
  }

  static GpuSample fromJson(Map<String, dynamic> j) => GpuSample(
        name: (j['name'] as String?) ?? 'GPU',
        vendor: (j['vendor'] as String?) ?? 'unbekannt',
        source: (j['source'] as String?) ?? 'unbekannt',
        utilPercent: Fact.asDouble(j['util_percent']),
        vramUsedBytes: Fact.asInt(j['vram_used_bytes']),
        vramTotalBytes: Fact.asInt(j['vram_total_bytes']),
        tempC: Fact.asDouble(j['temp_c']),
        powerWatts: Fact.asDouble(j['power_watts']),
      );
}

class TelemetrySample {
  const TelemetrySample({
    required this.at,
    required this.receivedAt,
    required this.cpuPercent,
    required this.ramUsedBytes,
    required this.ramTotalBytes,
    required this.gpus,
    this.gpuNote,
  });

  final DateTime at;

  /// Lokale Ankunftszeit — Basis für die Veraltungsanzeige, unabhängig von
  /// einer schiefen Uhr auf dem Desktop.
  final DateTime receivedAt;

  final Fact<double> cpuPercent;
  final Fact<int> ramUsedBytes;
  final Fact<int> ramTotalBytes;
  final List<GpuSample> gpus;

  /// Gesetzt, wenn keine einzige GPU-Quelle funktioniert hat.
  final String? gpuNote;

  GpuSample? get primaryGpu => gpus.isEmpty ? null : gpus.first;

  double? get ramFraction {
    final used = ramUsedBytes.value;
    final total = ramTotalBytes.value;
    if (used == null || total == null || total == 0) return null;
    return used / total;
  }

  static TelemetrySample fromJson(Map<String, dynamic> j) => TelemetrySample(
        at: DateTime.tryParse((j['at'] as String?) ?? '')?.toLocal() ??
            DateTime.now(),
        receivedAt: DateTime.now(),
        cpuPercent: Fact.asDouble(j['cpu_percent']),
        ramUsedBytes: Fact.asInt(j['ram_used_bytes']),
        ramTotalBytes: Fact.asInt(j['ram_total_bytes']),
        gpus: ((j['gpus'] as List<dynamic>?) ?? [])
            .map((e) => GpuSample.fromJson(e as Map<String, dynamic>))
            .toList(),
        gpuNote: j['gpu_note'] as String?,
      );
}

/// Verlauf plus Verbindungszustand. Die App zeigt bei Abriss den letzten
/// Stand mit Zeitstempel, statt ihn als aktuell auszugeben.
class TelemetryFeed {
  const TelemetryFeed({
    this.history = const [],
    this.connected = false,
    this.error,
    this.reconnectIn,
  });

  final List<TelemetrySample> history;
  final bool connected;
  final String? error;
  final Duration? reconnectIn;

  static const int capacity = 120;

  TelemetrySample? get latest => history.isEmpty ? null : history.last;

  Duration? get age {
    final last = latest;
    if (last == null) return null;
    return DateTime.now().difference(last.receivedAt);
  }

  /// Ab drei Sekunden ohne Sample gilt die Anzeige als veraltet — bei 1 Hz
  /// Takt ist das eindeutig ein Aussetzer und nicht bloß Jitter.
  bool get isStale => (age ?? Duration.zero).inMilliseconds > 3000;

  List<double> seriesCpu() =>
      history.map((s) => s.cpuPercent.value ?? double.nan).toList();

  List<double> seriesRam() =>
      history.map((s) => (s.ramFraction ?? double.nan) * 100).toList();

  List<double> seriesGpu() => history
      .map((s) => s.primaryGpu?.utilPercent.value ?? double.nan)
      .toList();

  List<double> seriesVram() => history
      .map((s) => (s.primaryGpu?.vramFraction ?? double.nan) * 100)
      .toList();

  TelemetryFeed append(TelemetrySample sample) {
    final next = [...history, sample];
    if (next.length > capacity) next.removeRange(0, next.length - capacity);
    return TelemetryFeed(history: next, connected: true);
  }

  TelemetryFeed disconnected(String reason, Duration retryIn) => TelemetryFeed(
        history: history,
        connected: false,
        error: reason,
        reconnectIn: retryIn,
      );
}
