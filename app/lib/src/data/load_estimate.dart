import '../models/load_settings.dart';
import '../models/model_entry.dart';
import '../models/telemetry.dart';

enum Fit {
  /// Mit Luft für Rechenpuffer.
  fits,

  /// Rechnerisch ja, aber ohne Reserve — Ollama lagert dann womöglich
  /// einzelne Schichten aus.
  tight,

  /// Passt nicht: ein Teil läuft auf der CPU, Antworten werden deutlich
  /// langsamer.
  spills,

  /// Mindestens eine Größe fehlt — dann wird nichts behauptet.
  unknown,
}

/// Abschätzung, was ein Modell mit bestimmten Ladeoptionen an Speicher
/// belegt, und ob das in den freien Speicher passt.
///
/// Eine Schätzung, kein Messwert: die Gewichte sind die Dateigröße, der
/// Kontext folgt aus der Architektur. Dazu kommen Rechenpuffer, die je nach
/// Backend und Version schwanken — deshalb die Reserve bei [Fit.tight].
class LoadEstimate {
  const LoadEstimate({
    required this.fit,
    required this.target,
    this.weightBytes,
    this.kvBytes,
    this.contextTokens,
    this.availableBytes,
    this.reasons = const [],
  });

  final Fit fit;

  /// "Grafikspeicher" oder "Arbeitsspeicher".
  final String target;
  final int? weightBytes;
  final int? kvBytes;
  final int? contextTokens;
  final int? availableBytes;

  /// Warum etwas fehlt — wird angezeigt statt einer erfundenen Zahl.
  final List<String> reasons;

  int? get totalBytes =>
      (weightBytes == null || kvBytes == null) ? null : weightBytes! + kvBytes!;
}

/// Anteil des freien Speichers, ab dem es knapp wird.
const _reserve = 0.9;

LoadEstimate estimateLoad({
  required ModelEntry model,
  required LoadSettings settings,
  TelemetrySample? telemetry,
}) {
  final reasons = <String>[];
  final onCpu = settings.gpu == GpuMode.off;
  final target = onCpu ? 'Arbeitsspeicher' : 'Grafikspeicher';

  final weights = model.diskBytes.value;
  if (weights == null) reasons.add('Dateigröße des Modells unbekannt');

  final ctx = settings.contextLength ?? model.loadedContextLength.value;
  if (ctx == null) {
    reasons.add('Kontextfenster auf Vorgabe — Größe erst nach dem Laden bekannt');
  }
  final perToken = model.kvBytesPerToken.value;
  if (perToken == null) {
    reasons.add(model.kvBytesPerToken.note ?? 'Speicher pro Token unbekannt');
  }
  final kv = (ctx != null && perToken != null) ? ctx * perToken : null;

  int? available;
  if (telemetry == null) {
    reasons.add('keine Telemetrie vom Desktop');
  } else if (onCpu) {
    final total = telemetry.ramTotalBytes.value;
    final used = telemetry.ramUsedBytes.value;
    if (total != null && used != null) available = total - used;
  } else {
    final gpu = telemetry.primaryGpu;
    final total = gpu?.vramTotalBytes.value;
    final used = gpu?.vramUsedBytes.value;
    if (total != null && used != null) {
      // Ein geladenes Modell gibt seinen Platz beim Neuladen frei.
      final own = model.isLoaded ? (model.vramBytes.value ?? 0) : 0;
      available = total - used + own;
      if (model.isLoaded && !model.vramBytes.isKnown) {
        reasons.add('belegter Speicher des geladenen Modells unbekannt — '
            'freier Speicher eher unterschätzt');
      }
    }
  }
  if (telemetry != null && available == null) {
    reasons.add('$target des Desktops nicht messbar');
  }

  final total = (weights == null || kv == null) ? null : weights + kv;
  final fit = (total == null || available == null)
      ? Fit.unknown
      : total <= available * _reserve
          ? Fit.fits
          : total <= available
              ? Fit.tight
              : Fit.spills;

  return LoadEstimate(
    fit: fit,
    target: target,
    weightBytes: weights,
    kvBytes: kv,
    contextTokens: ctx,
    availableBytes: available,
    reasons: reasons,
  );
}
