import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_remote/src/data/load_estimate.dart';
import 'package:local_ai_remote/src/models/load_settings.dart';
import 'package:local_ai_remote/src/models/model_entry.dart';
import 'package:local_ai_remote/src/models/telemetry.dart';

const gib = 1024 * 1024 * 1024;

Map<String, dynamic> fact(Object? v) =>
    {'value': v, 'certainty': v == null ? 'unknown' : 'known', 'note': null};

ModelEntry modell({
  String backend = 'ollama',
  String state = 'not_loaded',
  int? disk = 5 * gib,
  int? kvPerToken = 147456, // qwen3:8b, f16
  int? loadedCtx,
  int? vram,
}) =>
    ModelEntry.fromJson({
      'id': 'qwen3:8b',
      'backend': backend,
      'state': state,
      'disk_bytes': fact(disk),
      'kv_bytes_per_token': fact(kvPerToken),
      'loaded_context_length': fact(loadedCtx),
      'vram_bytes': fact(vram),
    });

TelemetrySample messung({int vramTotal = 16 * gib, int vramUsed = 2 * gib}) =>
    TelemetrySample.fromJson({
      'ram_total_bytes': fact(32 * gib),
      'ram_used_bytes': fact(12 * gib),
      'gpus': [
        {
          'name': 'GPU',
          'vendor': 'amd',
          'source': 'test',
          'vram_total_bytes': fact(vramTotal),
          'vram_used_bytes': fact(vramUsed),
        }
      ],
    });

void main() {
  group('Abschätzung vor dem Laden', () {
    test('Gewichte plus Kontext, gegen freien Grafikspeicher', () {
      final e = estimateLoad(
        model: modell(),
        settings: const LoadSettings(contextLength: 32768),
        telemetry: messung(),
      );
      expect(e.weightBytes, 5 * gib);
      expect(e.kvBytes, 32768 * 147456); // 4,5 GiB
      expect(e.availableBytes, 14 * gib);
      expect(e.fit, Fit.fits);
    });

    test('großes Kontextfenster passt nicht mehr', () {
      final e = estimateLoad(
        model: modell(),
        settings: const LoadSettings(contextLength: 131072), // 18 GiB KV
        telemetry: messung(),
      );
      expect(e.fit, Fit.spills);
    });

    test('ohne Reserve ist es knapp', () {
      // 5 GiB + 4,5 GiB = 9,5 GiB bei 10 GiB frei.
      final e = estimateLoad(
        model: modell(),
        settings: const LoadSettings(contextLength: 32768),
        telemetry: messung(vramUsed: 6 * gib),
      );
      expect(e.fit, Fit.tight);
    });

    test('ein geladenes Modell gibt seinen Platz beim Neuladen frei', () {
      final e = estimateLoad(
        model: modell(state: 'loaded', vram: 7 * gib, loadedCtx: 8192),
        settings: const LoadSettings(contextLength: 32768),
        telemetry: messung(vramUsed: 13 * gib),
      );
      // 16 - 13 + 7 = 10 GiB frei, gebraucht 9,5 GiB.
      expect(e.availableBytes, 10 * gib);
      expect(e.fit, Fit.tight);
    });

    test('nur CPU rechnet gegen den Arbeitsspeicher', () {
      final e = estimateLoad(
        model: modell(),
        settings: const LoadSettings(contextLength: 8192, gpu: GpuMode.off),
        telemetry: messung(),
      );
      expect(e.target, 'Arbeitsspeicher');
      expect(e.availableBytes, 20 * gib);
    });

    test('ohne Architekturdaten wird nichts behauptet', () {
      final e = estimateLoad(
        model: modell(backend: 'lmstudio', kvPerToken: null),
        settings: const LoadSettings(contextLength: 32768),
        telemetry: messung(),
      );
      expect(e.fit, Fit.unknown);
      expect(e.totalBytes, isNull);
      expect(e.reasons, isNotEmpty);
    });

    test('Kontext auf Vorgabe: nimmt das geladene Fenster, sonst unbekannt', () {
      expect(
        estimateLoad(
          model: modell(state: 'loaded', loadedCtx: 4096, vram: 6 * gib),
          settings: LoadSettings.standard,
          telemetry: messung(),
        ).contextTokens,
        4096,
      );
      expect(
        estimateLoad(
          model: modell(),
          settings: LoadSettings.standard,
          telemetry: messung(),
        ).fit,
        Fit.unknown,
      );
    });
  });

  group('Ladeoptionen pro Anfrage', () {
    const alles = LoadSettings(
        contextLength: 16384, keepAliveSeconds: 1800, gpu: GpuMode.max);

    test('Ollama bekommt alles', () {
      expect(alles.forChat(BackendId.ollama),
          {'context_length': 16384, 'keep_alive': 1800, 'gpu': 'max'});
    });

    test('LM Studio nur die Haltedauer — der Rest gilt beim Laden', () {
      expect(alles.forChat(BackendId.lmstudio), {'keep_alive': 1800});
      expect(
          const LoadSettings(keepAliveSeconds: -1)
              .forChat(BackendId.lmstudio),
          isNull);
    });

    test('Vorgabe schickt gar nichts', () {
      expect(LoadSettings.standard.forChat(BackendId.ollama), isNull);
    });

    test('übersteht den Weg durch JSON', () {
      expect(LoadSettings.fromJson(alles.toJson()), alles);
    });

    test('Stufen respektieren Modell- und Gateway-Grenze', () {
      expect(contextChoices(modelMax: 40960, gatewayMax: 16384).last, 16384);
      expect(contextChoices(modelMax: 8192).last, 8192);
    });
  });

  group('Downloads', () {
    test('Fortschritt nur, wenn die Größe bekannt ist', () {
      final ohne = PullJob.fromJson({'model': 'x', 'state': 'running'});
      expect(ohne.fraction, isNull);
      final mit = PullJob.fromJson(
          {'model': 'x', 'state': 'running', 'completed': 25, 'total': 100});
      expect(mit.fraction, 0.25);
    });

    test('unbekannter Zustand gilt als gescheitert, nicht als fertig', () {
      expect(PullJob.fromJson({'model': 'x', 'state': '???'}).state,
          PullState.failed);
    });
  });
}
