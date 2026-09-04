import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_remote/src/data/gateway_client.dart';
import 'package:local_ai_remote/src/models/model_entry.dart';

/// Ein Gateway-Doppel, das SSE liefert und meldet, wann der Client geht.
class _FakeGateway {
  _FakeGateway._(this._server);

  final HttpServer _server;

  /// Wartet, bis der Server keine offene Verbindung mehr hat.
  ///
  /// Zuverlässiger als auf einen Schreibfehler zu warten: ein `write` auf
  /// einen bereits geschlossenen Loopback-Socket landet erst im Puffer des
  /// Betriebssystems und meldet den Fehler mit Verzögerung oder gar nicht.
  Future<void> awaitNoConnections({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_server.connectionsInfo().total == 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw StateError(
      'Verbindung steht nach $timeout noch offen - das Gateway saehe keinen '
      'Disconnect und das Modell rechnete weiter.',
    );
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeGateway> start({
    required List<String> events,
    bool endlessly = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeGateway._(server);

    server.listen((request) async {
      final res = request.response
        ..headers.contentType = ContentType('text', 'event-stream')
        ..bufferOutput = false;

      try {
        for (final event in events) {
          res.write('data: $event\n\n');
          await res.flush();
        }
        while (endlessly) {
          // Heartbeats, bis der Client abbricht. Genau daran zeigt sich, ob
          // ein Abbrechen die Verbindung wirklich beendet.
          res.write('data: {"type":"heartbeat"}\n\n');
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        await res.close();
      } catch (_) {
        // Schreiben schlaegt fehl, sobald die Gegenseite zu ist.
      }
    });

    return fake;
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  const ref = ModelRef(BackendId.ollama, 'm1');

  test('trennt beim Abbrechen wirklich die Verbindung', () async {
    // Der eigentliche Punkt: das Abbestellen eines Streams schliesst für sich
    // genommen keine TCP-Verbindung. Ohne eigenen, geschlossenen Client sieht
    // das Gateway keinen Disconnect und das Modell rechnet auf dem Desktop
    // weiter, obwohl die App längst "Abgebrochen" anzeigt.
    final gateway = await _FakeGateway.start(
      events: ['{"type":"delta","text":"a"}'],
      endlessly: true,
    );
    addTearDown(gateway.stop);

    final client = GatewayClient(baseUrl: gateway.baseUrl, token: 't');
    final seen = <ChatEvent>[];
    final sub = client
        .streamChat(ref: ref, messages: const [])
        .listen(seen.add);

    // Warten, bis wirklich Daten fliessen.
    while (seen.whereType<ChatDelta>().isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    await sub.cancel();

    await gateway.awaitNoConnections();
  });

  test('trennt die Verbindung auch am regulaeren Ende', () async {
    final gateway = await _FakeGateway.start(events: [
      '{"type":"delta","text":"Hallo"}',
      '{"type":"done","metrics":{}}',
    ]);
    addTearDown(gateway.stop);

    final client = GatewayClient(baseUrl: gateway.baseUrl, token: 't');
    final events =
        await client.streamChat(ref: ref, messages: const []).toList();

    expect(events.whereType<ChatAccepted>(), hasLength(1));
    expect(events.whereType<ChatDelta>().single.text, 'Hallo');
    expect(events.whereType<ChatDone>(), hasLength(1));
  });

  test('reicht Denkschritte als eigenen Ereignistyp weiter', () async {
    final gateway = await _FakeGateway.start(events: [
      '{"type":"reasoning","text":"erst denken"}',
      '{"type":"delta","text":"dann antworten"}',
      '{"type":"done","metrics":{}}',
    ]);
    addTearDown(gateway.stop);

    final client = GatewayClient(baseUrl: gateway.baseUrl, token: 't');
    final events =
        await client.streamChat(ref: ref, messages: const []).toList();

    expect(events.whereType<ChatReasoning>().single.text, 'erst denken');
    expect(events.whereType<ChatDelta>().single.text, 'dann antworten');
  });

  test('meldet einen Fehler mitten im Stream als Grund, nicht als Abriss',
      () async {
    final gateway = await _FakeGateway.start(events: [
      '{"type":"delta","text":"halb"}',
      '{"type":"error","message":"not enough VRAM"}',
    ]);
    addTearDown(gateway.stop);

    final client = GatewayClient(baseUrl: gateway.baseUrl, token: 't');
    final events =
        await client.streamChat(ref: ref, messages: const []).toList();

    expect(events.whereType<ChatFailure>().single.message, 'not enough VRAM');
  });

  test('telemetryUri wechselt auf wss und haengt den Token an', () {
    final client =
        GatewayClient(baseUrl: 'https://desktop.tailnet.ts.net', token: 'geheim');
    final uri = client.telemetryUri();

    expect(uri.scheme, 'wss');
    expect(uri.path, '/v1/telemetry');
    expect(uri.queryParameters['token'], 'geheim');
  });
}
