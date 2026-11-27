import 'fact.dart';

/// Ab hier gilt eine Karte als dediziert. Integrierte Grafik meldet meist
/// 512 MB oder weniger als eigenen Speicher.
const dedicatedThresholdBytes = 2 * 1024 * 1024 * 1024;

/// Ab hier ist der geteilte Speicher einer dedizierten Karte eine
/// Auslagerung, die bremst, statt Grundrauschen.
const spillThresholdBytes = 1024 * 1024 * 1024;

class GpuSample {
  const GpuSample({
    required this.name,
    required this.vendor,
    required this.source,
    required this.utilPercent,
    required this.vramUsedBytes,
    required this.vramTotalBytes,
    this.sharedUsedBytes = const Fact<int>(
      certainty: Certainty.unknown,
      note: 'Feld fehlt in der Antwort des Gateways',
    ),
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

  /// Was die Karte im System-RAM belegt — im Task-Manager „Gemeinsamer
  /// GPU-Speicher“. Reicht der VRAM nicht, lagert Windows still dorthin aus;
  /// [vramUsedBytes] sieht dann unauffällig aus, die Antworten sind es nicht.
  final Fact<int> sharedUsedBytes;
  final Fact<double> tempC;
  final Fact<double> powerWatts;

  double? get vramFraction {
    final used = vramUsedBytes.value;
    final total = vramTotalBytes.value;
    if (used == null || total == null || total == 0) return null;
    return used / total;
  }

  /// Ob die Karte nennenswert in den System-RAM auslagert.
  ///
  /// Nur bei Karten mit eigenem VRAM: eine integrierte Grafik lebt ohnehin
  /// im geteilten Speicher, dort ist ein großer Wert normal. Ein paar hundert
  /// MB belegt auch eine dedizierte Karte im Leerlauf — erst ab
  /// [spillThresholdBytes] ist es eine Auslagerung, die bremst.
  bool get spillsToRam {
    final shared = sharedUsedBytes.value;
    final total = vramTotalBytes.value;
    return shared != null &&
        total != null &&
        total >= dedicatedThresholdBytes &&
        shared >= spillThresholdBytes;
  }

  static GpuSample fromJson(Map<String, dynamic> j) => GpuSample(
    name: (j['name'] as String?) ?? 'GPU',
    vendor: (j['vendor'] as String?) ?? 'unbekannt',
    source: (j['source'] as String?) ?? 'unbekannt',
    utilPercent: Fact.asDouble(j['util_percent']),
    vramUsedBytes: Fact.asInt(j['vram_used_bytes']),
    vramTotalBytes: Fact.asInt(j['vram_total_bytes']),
    sharedUsedBytes: Fact.asInt(j['shared_used_bytes']),
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

  /// Die Karte, auf der die Modelle laufen: die mit dem meisten eigenen
  /// VRAM.
  ///
  /// Nicht einfach die erste — Windows nennt zuerst die Karte, an der der
  /// Monitor hängt. Steckt der in der integrierten Grafik, rechnete sonst
  /// alles mit deren paar hundert MB.
  GpuSample? get primaryGpu {
    if (gpus.isEmpty) return null;
    var best = gpus.first;
    for (final g in gpus.skip(1)) {
      if ((g.vramTotalBytes.value ?? -1) > (best.vramTotalBytes.value ?? -1)) {
        best = g;
      }
    }
    return best;
  }

  double? get ramFraction {
    final used = ramUsedBytes.value;
    final total = ramTotalBytes.value;
    if (used == null || total == null || total == 0) return null;
    return used / total;
  }

  static TelemetrySample fromJson(Map<String, dynamic> j) => TelemetrySample(
    at:
        DateTime.tryParse((j['at'] as String?) ?? '')?.toLocal() ??
        DateTime.now(),
    receivedAt: DateTime.now(),
    cpuPercent: Fact.asDouble(j['cpu_percent']),
    ramUsedBytes: Fact.asInt(j['ram_used_bytes']),
    ramTotalBytes: Fact.asInt(j['ram_total_bytes']),
    gpus:
        ((j['gpus'] as List<dynamic>?) ?? [])
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

  List<double> seriesGpu() =>
      history
          .map((s) => s.primaryGpu?.utilPercent.value ?? double.nan)
          .toList();

  List<double> seriesVram() =>
      history
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
