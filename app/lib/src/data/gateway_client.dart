import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/chat.dart';
import '../models/model_entry.dart';
import '../models/telemetry.dart';

class GatewayException implements Exception {
  GatewayException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// Ereignisse des Chat-Streams. Jedes davon verschiebt die Zustandsmaschine.
sealed class ChatEvent {
  const ChatEvent();
}

/// HTTP-Header sind da — der Request ist nachweislich angekommen.
class ChatAccepted extends ChatEvent {
  const ChatAccepted();
}

class ChatPhaseEvent extends ChatEvent {
  const ChatPhaseEvent(this.state, this.note);
  final String state;
  final String? note;
}

class ChatDelta extends ChatEvent {
  const ChatDelta(this.text);
  final String text;
}

/// Denkschritte eines Reasoning-Modells. Getrennt von [ChatDelta], weil sie
/// nicht in die Antwort und nicht in den nächsten Prompt gehören — aber
/// sichtbar sein müssen, sonst wirkt das Modell untätig.
class ChatReasoning extends ChatEvent {
  const ChatReasoning(this.text);
  final String text;
}

/// Lebenszeichen ohne Inhalt: trennt "rechnet noch" von "Verbindung tot".
class ChatHeartbeat extends ChatEvent {
  const ChatHeartbeat();
}

/// Das Modell möchte Werkzeuge aufrufen. Ausgeführt wird erst nach Freigabe.
class ChatToolCalls extends ChatEvent {
  const ChatToolCalls(this.calls);
  final List<ToolCall> calls;
}

class ChatDone extends ChatEvent {
  const ChatDone(this.metrics);
  final ChatMetrics? metrics;
}

class ChatFailure extends ChatEvent {
  const ChatFailure(this.message);
  final String message;
}

/// Ergebnis eines ausgeführten Recherche-Aufrufs.
class ResearchResult {
  const ResearchResult({
    required this.inhalt,
    required this.quellen,
    this.gekuerzt = false,
  });

  final String inhalt;
  final List<Quelle> quellen;
  final bool gekuerzt;
}

class GatewayClient {
  GatewayClient({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _http;

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  void close() => _http.close();

  Uri _uri(String path) {
    final trimmed =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$trimmed$path');
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  Future<GatewayHealth> health() async {
    final res = await _http
        .get(_uri('/v1/health'), headers: _headers)
        .timeout(const Duration(seconds: 8));
    _ensureOk(res);
    return GatewayHealth.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<ModelsSnapshot> models() async {
    final res = await _http
        .get(_uri('/v1/models'), headers: _headers)
        .timeout(const Duration(seconds: 30));
    _ensureOk(res);
    return ModelsSnapshot.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> pin(ModelRef ref) => _post('/v1/models/pin', ref.toJson());

  Future<void> unload(ModelRef ref) => _post('/v1/models/unload', ref.toJson());

  Future<void> _post(String path, Map<String, dynamic> body) async {
    final res = await _http
        .post(_uri(path),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 60));
    _ensureOk(res);
  }

  void _ensureOk(http.Response res) {
    if (res.statusCode >= 400) {
      String detail = res.body;
      try {
        detail = (jsonDecode(res.body) as Map)['detail']?.toString() ?? detail;
      } catch (_) {/* Rohtext behalten */}
      throw GatewayException(detail.isEmpty ? 'HTTP ${res.statusCode}' : detail,
          statusCode: res.statusCode);
    }
  }

  /// Chat als Server-Sent-Events. Der Stream endet nur, wenn das Gateway
  /// schließt oder der Abonnent abbricht.
  Stream<ChatEvent> streamChat({
    required ModelRef ref,
    required List<Map<String, dynamic>> messages,
    double? temperature,
    bool research = false,
  }) async* {
    // Das Abbestellen des Streams schliesst die Verbindung mit; das Gateway
    // sieht den Disconnect und bricht die Generierung auf dem Desktop ab.
    // `gateway_client_test.dart` haelt genau das fest — daran haengt, ob
    // "Abbrechen" wirklich Rechenzeit freigibt.
    yield* _streamChat(_http, ref, messages, temperature, research);
  }

  Stream<ChatEvent> _streamChat(
    http.Client client,
    ModelRef ref,
    List<Map<String, dynamic>> messages,
    double? temperature,
    bool research,
  ) async* {
    final request = http.Request('POST', _uri('/v1/chat'))
      ..headers.addAll({
        ..._headers,
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'backend': ref.backend.wire,
        'model': ref.id,
        'messages': messages,
        if (temperature != null) 'temperature': temperature,
        if (research) 'research': true,
      });

    final http.StreamedResponse response;
    try {
      response = await client.send(request);
    } catch (e) {
      yield ChatFailure('Gateway nicht erreichbar: $e');
      return;
    }

    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      yield ChatFailure('Gateway antwortete ${response.statusCode}: '
          '${body.isEmpty ? '(kein Text)' : body}');
      return;
    }

    yield const ChatAccepted();

    final lines =
        response.stream.transform(utf8.decoder).transform(const LineSplitter());

    try {
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;

        final Map<String, dynamic> event;
        try {
          event = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        switch (event['type']) {
          case 'delta':
            yield ChatDelta((event['text'] as String?) ?? '');
          case 'reasoning':
            yield ChatReasoning((event['text'] as String?) ?? '');
          case 'tool_calls':
            final roh = event['calls'];
            yield ChatToolCalls([
              if (roh is List)
                for (final c in roh)
                  if (c is Map<String, dynamic>) ToolCall.fromJson(c)
            ]);
          case 'status':
            yield ChatPhaseEvent(
                (event['state'] as String?) ?? '', event['note'] as String?);
          case 'heartbeat':
            yield const ChatHeartbeat();
          case 'done':
            final raw = event['metrics'];
            yield ChatDone(raw is Map<String, dynamic>
                ? ChatMetrics(raw: raw)
                : null);
          case 'error':
            yield ChatFailure(
                (event['message'] as String?) ?? 'unbekannter Fehler');
        }
      }
    } catch (e) {
      yield ChatFailure('Stream abgebrochen: $e');
    }
  }

  /// Einmalige Vervollständigung ohne Streaming — für die Zusammenfassung
  /// des Kontexts.
  Future<String> completeOnce({
    required ModelRef ref,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.2,
  }) async {
    final buffer = StringBuffer();
    await for (final event in streamChat(
      ref: ref,
      messages: messages,
      temperature: temperature,
    )) {
      if (event is ChatDelta) buffer.write(event.text);
      if (event is ChatFailure) throw GatewayException(event.message);
    }
    return buffer.toString().trim();
  }

  /// Führt einen **freigegebenen** Recherche-Aufruf aus.
  ///
  /// Bewusst ein eigener Aufruf und kein Schritt im Chat-Stream: zwischen dem
  /// Vorschlag des Modells und der Ausführung liegt so zwingend eine
  /// Entscheidung des Nutzers.
  Future<ResearchResult> runResearch(ToolCall call) async {
    final res = await _http
        .post(_uri('/v1/research'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'name': call.name, 'arguments': call.arguments}))
        .timeout(const Duration(seconds: 60));
    _ensureOk(res);
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return ResearchResult(
      inhalt: (j['inhalt'] as String?) ?? '',
      quellen: [
        for (final q in (j['quellen'] as List<dynamic>? ?? const []))
          if (q is Map<String, dynamic>)
            Quelle(
              titel: (q['titel'] as String?) ?? (q['url'] as String?) ?? '',
              url: (q['url'] as String?) ?? '',
            )
      ],
      gekuerzt: (j['gekuerzt'] as bool?) ?? false,
    );
  }

  Uri telemetryUri() {
    final base = _uri('/v1/telemetry');
    final scheme = switch (base.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      final other => other,
    };
    return base.replace(
      scheme: scheme,
      queryParameters: token.isEmpty ? null : {'token': token},
    );
  }

  /// Telemetrie-Kanal. Der Aufrufer verwaltet Reconnects, damit die Politik
  /// (Backoff, letzter Stand) an einer Stelle liegt.
  Stream<TelemetrySample> telemetry() {
    final channel = WebSocketChannel.connect(telemetryUri());
    // Ein Fehlschlag beim Verbinden kommt zweimal: über `ready` und über den
    // Stream. Ohne Abnehmer für `ready` landet er als unbehandelter Fehler in
    // der Zone — bei jedem Reconnect-Versuch, solange der Desktop schläft.
    // Behandelt wird er über den Stream, beim Aufrufer.
    channel.ready.ignore();
    return channel.stream.map((raw) => TelemetrySample.fromJson(
        jsonDecode(raw as String) as Map<String, dynamic>));
  }
}
