import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../data/gateway_client.dart';

/// Verbindungsfehler in einen Satz, mit dem man etwas anfangen kann.
///
/// Der Originaltext bleibt als [detail] erhalten — eine Übersetzung, die den
/// eigentlichen Grund verschluckt, wäre schlimmer als gar keine.
class GatewayProblem {
  const GatewayProblem(
    this.headline, {
    this.detail,
    this.fixInSettings = false,
  });

  final String headline;
  final String? detail;

  /// Ob der Fehler in den Einstellungen zu beheben ist (Adresse, Token).
  final bool fixInSettings;
}

GatewayProblem describeError(Object error) {
  final raw = '$error';

  if (error is GatewayException) {
    return switch (error.statusCode) {
      401 || 403 => GatewayProblem(
        'Token abgelehnt — in den Einstellungen prüfen',
        detail: raw,
        fixInSettings: true,
      ),
      404 => GatewayProblem(
        'Unter dieser Adresse antwortet kein Gateway',
        detail: raw,
        fixInSettings: true,
      ),
      final int code when code >= 500 => GatewayProblem(
        'Gateway meldet einen Fehler ($code)',
        detail: raw,
      ),
      _ => GatewayProblem(raw),
    };
  }
  if (error is TimeoutException) {
    return GatewayProblem(
      'Keine Antwort vom Gateway — Desktop aus oder im Ruhezustand?',
      detail: raw,
    );
  }
  if (error is HandshakeException || error is TlsException) {
    return GatewayProblem(
      'TLS-Fehler — stimmt die https-Adresse aus „tailscale serve"?',
      detail: raw,
      fixInSettings: true,
    );
  }
  if (error is SocketException ||
      error is http.ClientException ||
      error is WebSocketException) {
    return GatewayProblem(
      'Gateway nicht erreichbar — Tailscale verbunden?',
      detail: raw,
    );
  }
  if (error is FormatException || error is ArgumentError) {
    return GatewayProblem(
      'Die Gateway-Adresse ist ungültig',
      detail: raw,
      fixInSettings: true,
    );
  }
  return GatewayProblem(raw);
}

/// Prüft eine eingegebene Gateway-Adresse. `null` heißt in Ordnung.
String? validateGatewayUrl(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'Vollständige Adresse mit https:// angeben';
  }
  if (uri.scheme != 'https' && uri.scheme != 'http') {
    return 'Nur http:// oder https://';
  }
  if (uri.hasQuery || uri.hasFragment) {
    return 'Ohne ? oder # — nur Schema, Host und ggf. Port';
  }
  return null;
}

/// Ergänzt ein fehlendes Schema. Tailscale-Namen sind immer https.
String normalizeGatewayUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return text;
  if (!text.contains('://')) text = 'https://$text';
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}
