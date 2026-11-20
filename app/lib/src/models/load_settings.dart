import 'model_entry.dart';

/// Wie viel GPU ein Modell bekommt.
enum GpuMode {
  auto('auto', 'Automatisch'),
  max('max', 'Maximal'),
  off('off', 'Nur CPU');

  const GpuMode(this.wire, this.label);
  final String wire;
  final String label;

  static GpuMode parse(Object? raw) =>
      GpuMode.values.firstWhere((m) => m.wire == raw, orElse: () => GpuMode.auto);
}

/// Ladeoptionen für ein Modell. Gehören zum Modell, nicht zum Chat: zwei
/// Chats mit demselben Modell teilen sich ohnehin dieselbe geladene Instanz.
class LoadSettings {
  const LoadSettings({
    this.contextLength,
    this.keepAliveSeconds,
    this.gpu = GpuMode.auto,
  });

  /// `null`: Vorgabe des Backends.
  final int? contextLength;

  /// `null`: Vorgabe des Backends, `-1`: dauerhaft.
  final int? keepAliveSeconds;
  final GpuMode gpu;

  static const standard = LoadSettings();

  bool get isDefault =>
      contextLength == null && keepAliveSeconds == null && gpu == GpuMode.auto;

  LoadSettings copyWith({
    int? contextLength,
    bool clearContext = false,
    int? keepAliveSeconds,
    bool clearKeepAlive = false,
    GpuMode? gpu,
  }) =>
      LoadSettings(
        contextLength:
            clearContext ? null : (contextLength ?? this.contextLength),
        keepAliveSeconds:
            clearKeepAlive ? null : (keepAliveSeconds ?? this.keepAliveSeconds),
        gpu: gpu ?? this.gpu,
      );

  Map<String, dynamic> toJson() => {
        if (contextLength != null) 'context_length': contextLength,
        if (keepAliveSeconds != null) 'keep_alive': keepAliveSeconds,
        'gpu': gpu.wire,
      };

  static LoadSettings fromJson(Map<String, dynamic> j) => LoadSettings(
        contextLength: (j['context_length'] as num?)?.toInt(),
        keepAliveSeconds: (j['keep_alive'] as num?)?.toInt(),
        gpu: GpuMode.parse(j['gpu']),
      );

  /// Was davon pro Chat-Anfrage mitgehen darf.
  ///
  /// LM Studio setzt Kontextfenster und GPU-Anteil nur beim Laden; das
  /// Gateway lehnt sie pro Anfrage ab, statt sie still zu ignorieren. Also
  /// schickt die App dort nur die Haltedauer — und auch die nur, wenn sie
  /// positiv ist.
  Map<String, dynamic>? forChat(BackendId backend) {
    if (isDefault) return null;
    if (backend == BackendId.lmstudio) {
      final k = keepAliveSeconds;
      return (k != null && k > 0) ? {'keep_alive': k} : null;
    }
    return toJson();
  }

  @override
  bool operator ==(Object other) =>
      other is LoadSettings &&
      other.contextLength == contextLength &&
      other.keepAliveSeconds == keepAliveSeconds &&
      other.gpu == gpu;

  @override
  int get hashCode => Object.hash(contextLength, keepAliveSeconds, gpu);
}

/// Haltedauern zur Auswahl. Feste Stufen statt eines Freifelds: die
/// Unterschiede, auf die es ankommt, sind Minuten gegen Stunden gegen immer.
const keepAliveChoices = <(int?, String)>[
  (null, 'Vorgabe'),
  (300, '5 min'),
  (1800, '30 min'),
  (7200, '2 h'),
  (28800, '8 h'),
  (-1, 'Dauerhaft'),
];

/// Kontextfenster zur Auswahl, gefiltert auf das, was Modell und Gateway
/// zulassen.
List<int> contextChoices({int? modelMax, int? gatewayMax}) {
  const stufen = [2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144];
  return [
    for (final s in stufen)
      if ((modelMax == null || s <= modelMax) &&
          (gatewayMax == null || s <= gatewayMax))
        s,
  ];
}

enum PullState {
  running,
  done,
  failed,
  cancelled;

  static PullState parse(Object? raw) => PullState.values
      .firstWhere((s) => s.name == raw, orElse: () => PullState.failed);
}

/// Ein Download im Gateway.
class PullJob {
  const PullJob({
    required this.model,
    required this.state,
    this.status = '',
    this.completed = 0,
    this.total,
    this.error,
  });

  final String model;
  final PullState state;
  final String status;
  final int completed;

  /// `null`, solange Ollama die Größe nicht genannt hat.
  final int? total;
  final String? error;

  double? get fraction =>
      (total == null || total == 0) ? null : (completed / total!).clamp(0, 1);

  static PullJob fromJson(Map<String, dynamic> j) => PullJob(
        model: (j['model'] as String?) ?? '?',
        state: PullState.parse(j['state']),
        status: (j['status'] as String?) ?? '',
        completed: (j['completed'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt(),
        error: j['error'] as String?,
      );
}

class PullsSnapshot {
  const PullsSnapshot({this.enabled = false, this.jobs = const []});

  final bool enabled;
  final List<PullJob> jobs;

  bool get anyRunning => jobs.any((j) => j.state == PullState.running);

  static PullsSnapshot fromJson(Map<String, dynamic> j) => PullsSnapshot(
        enabled: (j['enabled'] as bool?) ?? false,
        jobs: [
          for (final e in (j['jobs'] as List<dynamic>? ?? const []))
            if (e is Map<String, dynamic>) PullJob.fromJson(e),
        ],
      );
}
