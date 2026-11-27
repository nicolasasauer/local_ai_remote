import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_remote/src/models/telemetry.dart';

const _gib = 1024 * 1024 * 1024;

Map<String, dynamic> _fact(Object? value) => {
  'value': value,
  'certainty': value == null ? 'unknown' : 'known',
  'note': value == null ? 'nicht gemessen' : null,
};

Map<String, dynamic> _gpu(String name, int? total, {int? shared}) => {
  'name': name,
  'vendor': 'amd',
  'source': 'windows-counters',
  'util_percent': _fact(50.0),
  'vram_used_bytes': _fact(1 * _gib),
  'vram_total_bytes': _fact(total),
  if (shared != null || total != null) 'shared_used_bytes': _fact(shared),
  'temp_c': _fact(null),
  'power_watts': _fact(null),
};

TelemetrySample _sample(List<Map<String, dynamic>> gpus) =>
    TelemetrySample.fromJson({
      'at': '2026-11-27T10:00:00Z',
      'cpu_percent': _fact(10.0),
      'ram_used_bytes': _fact(8 * _gib),
      'ram_total_bytes': _fact(32 * _gib),
      'gpus': gpus,
      'gpu_note': null,
    });

void main() {
  group('primaryGpu', () {
    test('nimmt die Karte mit dem meisten VRAM, nicht die erste', () {
      // Windows nennt die integrierte Grafik zuerst, wenn der Monitor
      // daran hängt.
      final s = _sample([
        _gpu('AMD Radeon(TM) Graphics', 512 * 1024 * 1024),
        _gpu('AMD Radeon RX 9060 XT', 16 * _gib),
      ]);
      expect(s.primaryGpu!.name, 'AMD Radeon RX 9060 XT');
    });

    test('ohne bekannte Größen bleibt es die erste', () {
      final s = _sample([_gpu('A', null), _gpu('B', null)]);
      expect(s.primaryGpu!.name, 'A');
    });
  });

  group('spillsToRam', () {
    test('8 GiB geteilt bei einer 16-GiB-Karte ist Auslagerung', () {
      final g = GpuSample.fromJson(_gpu('RX', 16 * _gib, shared: 8 * _gib));
      expect(g.spillsToRam, isTrue);
    });

    test('ein paar hundert MB sind Grundrauschen', () {
      final g = GpuSample.fromJson(
        _gpu('RX', 16 * _gib, shared: 300 * 1024 * 1024),
      );
      expect(g.spillsToRam, isFalse);
    });

    test('integrierte Grafik lebt im geteilten Speicher', () {
      final g = GpuSample.fromJson(
        _gpu('iGPU', 512 * 1024 * 1024, shared: 3 * _gib),
      );
      expect(g.spillsToRam, isFalse);
    });

    test('älteres Gateway ohne das Feld: keine Warnung, aber Begründung', () {
      final json = _gpu('RX', 16 * _gib)..remove('shared_used_bytes');
      final g = GpuSample.fromJson(json);
      expect(g.spillsToRam, isFalse);
      expect(g.sharedUsedBytes.isKnown, isFalse);
      expect(g.sharedUsedBytes.note, isNotNull);
    });
  });
}
