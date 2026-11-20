import 'fact.dart';

enum BackendId {
  ollama('ollama', 'Ollama'),
  lmstudio('lmstudio', 'LM Studio');

  const BackendId(this.wire, this.label);
  final String wire;
  final String label;

  static BackendId parse(String? raw) =>
      raw == 'lmstudio' ? BackendId.lmstudio : BackendId.ollama;
}

enum ModelState {
  loaded('Im Speicher'),
  loading('Wird geladen'),
  unloading('Wird entladen'),
  notLoaded('Kalt'),
  error('Fehler');

  const ModelState(this.label);
  final String label;

  static ModelState parse(String? raw) => switch (raw) {
        'loaded' => ModelState.loaded,
        'loading' => ModelState.loading,
        'unloading' => ModelState.unloading,
        'error' => ModelState.error,
        _ => ModelState.notLoaded,
      };
}

enum ModelKind { llm, vision, embedding, unknown }

class ModelRef {
  const ModelRef(this.backend, this.id);
  final BackendId backend;
  final String id;

  Map<String, dynamic> toJson() => {'backend': backend.wire, 'model': id};

  @override
  bool operator ==(Object other) =>
      other is ModelRef && other.backend == backend && other.id == id;

  @override
  int get hashCode => Object.hash(backend, id);
}

class ModelEntry {
  ModelEntry({
    required this.id,
    required this.label,
    required this.backend,
    required this.state,
    required this.kind,
    required this.family,
    required this.parameterSize,
    required this.quantization,
    required this.diskBytes,
    required this.vramBytes,
    required this.vramFraction,
    required this.contextLength,
    required this.loadedContextLength,
    this.kvBytesPerToken = const Fact<int>(
        certainty: Certainty.unknown, note: 'Gateway liefert den Wert nicht'),
    required this.unloadsAt,
    required this.vision,
    required this.tools,
    required this.thinking,
    this.error,
  });

  final String id;
  final String label;
  final BackendId backend;
  final ModelState state;
  final ModelKind kind;

  final Fact<String> family;
  final Fact<String> parameterSize;
  final Fact<String> quantization;
  final Fact<int> diskBytes;
  final Fact<int> vramBytes;
  final Fact<double> vramFraction;
  final Fact<int> contextLength;
  final Fact<int> loadedContextLength;

  /// Speicher pro Token Kontext (KV-Cache), geschätzt aus der Architektur.
  final Fact<int> kvBytesPerToken;
  final Fact<DateTime> unloadsAt;
  final Fact<bool> vision;
  final Fact<bool> tools;

  /// Modell erzeugt Denkschritte, die getrennt vom Antworttext ankommen.
  final Fact<bool> thinking;
  final String? error;

  ModelRef get ref => ModelRef(backend, id);
  bool get isLoaded => state == ModelState.loaded;

  /// Das Kontextfenster, das im Chat wirklich zaehlt: wenn geladen, der
  /// tatsaechlich reservierte Wert, sonst das Maximum des Modells.
  Fact<int> get effectiveContext =>
      loadedContextLength.isKnown ? loadedContextLength : contextLength;

  /// Teil des Modells, der nicht auf der GPU liegt. Ein Wert deutlich unter 1
  /// erklaert, warum ein geladenes Modell zaeh antwortet.
  bool get isPartiallyOffloaded =>
      vramFraction.isKnown && vramFraction.value! < 0.98;

  static ModelEntry fromJson(Map<String, dynamic> j) => ModelEntry(
        id: j['id'] as String,
        label: (j['label'] as String?) ?? j['id'] as String,
        backend: BackendId.parse(j['backend'] as String?),
        state: ModelState.parse(j['state'] as String?),
        kind: switch (j['kind']) {
          'vlm' => ModelKind.vision,
          'llm' => ModelKind.llm,
          'embedding' => ModelKind.embedding,
          _ => ModelKind.unknown,
        },
        family: Fact.asString(j['family']),
        parameterSize: Fact.asString(j['parameter_size']),
        quantization: Fact.asString(j['quantization']),
        diskBytes: Fact.asInt(j['disk_bytes']),
        vramBytes: Fact.asInt(j['vram_bytes']),
        vramFraction: Fact.asDouble(j['vram_fraction']),
        contextLength: Fact.asInt(j['context_length']),
        loadedContextLength: Fact.asInt(j['loaded_context_length']),
        kvBytesPerToken: Fact.asInt(j['kv_bytes_per_token']),
        unloadsAt: Fact.asDate(j['unloads_at']),
        vision: Fact.asBool(j['vision']),
        tools: Fact.asBool(j['tools']),
        thinking: Fact.asBool(j['thinking']),
        error: j['error'] as String?,
      );
}

class BackendError {
  const BackendError(this.backend, this.message);
  final BackendId backend;
  final String message;
}

/// Momentaufnahme der Modellliste. Ein Fehler ist hier ein Zustand, kein
/// Abbruch — "Gateway weg" und "Backend weg" sind verschiedene Dinge.
/// Marker: es ist noch keine Gateway-Adresse gesetzt.
class GatewayNotConfigured {
  const GatewayNotConfigured();
  @override
  String toString() => 'Keine Gateway-Adresse gesetzt';
}

class ModelsSnapshot {
  const ModelsSnapshot({
    this.models = const [],
    this.backendErrors = const [],
    this.gatewayError,
    this.gatewayErrorCause,
  });

  final List<ModelEntry> models;
  final List<BackendError> backendErrors;
  final String? gatewayError;

  /// Die ursprüngliche Ausnahme — damit die Oberfläche einen 401 von einem
  /// abgeschalteten Desktop unterscheiden kann, statt nur Text zu haben.
  final Object? gatewayErrorCause;

  /// Gateway gar nicht eingerichtet — etwas anderes als "eingerichtet, aber
  /// nicht erreichbar".
  bool get notConfigured => gatewayErrorCause is GatewayNotConfigured;

  bool get gatewayReachable => gatewayError == null;

  List<ModelEntry> get selectable =>
      models.where((m) => m.kind != ModelKind.embedding).toList();

  List<ModelEntry> get loaded => models.where((m) => m.isLoaded).toList();

  static ModelsSnapshot fromJson(Map<String, dynamic> j) => ModelsSnapshot(
        models: (j['models'] as List<dynamic>)
            .map((e) => ModelEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        backendErrors: ((j['errors'] as List<dynamic>?) ?? [])
            .map((e) => BackendError(
                  BackendId.parse((e as Map)['backend'] as String?),
                  (e['message'] as String?) ?? 'unbekannter Fehler',
                ))
            .toList(),
      );
}

class BackendHealth {
  const BackendHealth({
    required this.backend,
    required this.reachable,
    required this.version,
    this.message,
  });

  final BackendId backend;
  final bool reachable;
  final Fact<String> version;
  final String? message;

  static BackendHealth fromJson(Map<String, dynamic> j) => BackendHealth(
        backend: BackendId.parse(j['backend'] as String?),
        reachable: j['reachable'] as bool? ?? false,
        version: Fact.asString(j['version']),
        message: j['message'] as String?,
      );
}

class GatewayHealth {
  const GatewayHealth({
    required this.hostname,
    required this.gatewayVersion,
    required this.backends,
    this.pullEnabled = false,
    this.maxContext,
  });

  final String hostname;
  final String gatewayVersion;
  final List<BackendHealth> backends;

  /// Ob das Gateway Modelle herunterladen darf (`GATEWAY_ALLOW_PULL`).
  final bool pullEnabled;

  /// Obergrenze fürs Kontextfenster (`GATEWAY_MAX_CONTEXT`), sonst `null`.
  final int? maxContext;

  static GatewayHealth fromJson(Map<String, dynamic> j) => GatewayHealth(
        hostname: (j['hostname'] as String?) ?? 'unbekannt',
        gatewayVersion: (j['gateway_version'] as String?) ?? '?',
        backends: (j['backends'] as List<dynamic>)
            .map((e) => BackendHealth.fromJson(e as Map<String, dynamic>))
            .toList(),
        pullEnabled: (j['pull_enabled'] as bool?) ?? false,
        maxContext: (j['max_context'] as num?)?.toInt(),
      );
}
