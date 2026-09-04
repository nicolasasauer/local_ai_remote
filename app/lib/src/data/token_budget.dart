import '../data/chat_store.dart';
import '../models/chat.dart';
import '../models/fact.dart';
import '../models/model_entry.dart';

/// Clientseitig gibt es keinen Tokenizer, also wird geschätzt — aber nur so
/// lange, bis das Gateway die erste echte `prompt_tokens`-Zahl liefert. Ab
/// dann rechnet die App mit dem gemessenen Verhältnis dieses Modells und das
/// "~" vor der Zahl verschwindet.
class TokenEstimator {
  const TokenEstimator(this.calibrations);

  final Map<String, ModelCalibration> calibrations;

  /// Startwert für gemischt deutsch-englischen Text mit Codeanteil.
  static const double defaultCharsPerToken = 3.8;

  /// Mindestens so viele Messungen, bevor eine Schätzung als gemessen gilt.
  static const int trustedAfterSamples = 2;

  ModelCalibration? _for(ModelRef ref) => calibrations[ChatStore.modelKey(ref)];

  double charsPerToken(ModelRef ref) =>
      _for(ref)?.charsPerToken ?? defaultCharsPerToken;

  bool isMeasured(ModelRef ref) =>
      (_for(ref)?.samples ?? 0) >= trustedAfterSamples;

  int estimate(String text, ModelRef ref) =>
      (text.length / charsPerToken(ref)).ceil();

  /// Erwartete Dauer der Prompt-Verarbeitung. Bewusst null, solange nichts
  /// gemessen wurde — lieber keine Angabe als eine erfundene.
  Duration? expectedPromptTime(int tokens, ModelRef ref) {
    final rate = _for(ref)?.promptTokensPerSecond;
    if (rate == null || rate <= 0) return null;
    return Duration(milliseconds: (tokens / rate * 1000).round());
  }

  /// Neue Messung einarbeiten: gleitender Mittelwert, damit ein Ausreißer
  /// (etwa ein Prompt mit viel Code) die Kalibrierung nicht kippt.
  static ModelCalibration fold(
    ModelCalibration? previous, {
    required int promptChars,
    required int promptTokens,
    double? promptTokensPerSecond,
  }) {
    final measured = promptTokens > 0
        ? promptChars / promptTokens
        : previous?.charsPerToken ?? defaultCharsPerToken;

    final samples = (previous?.samples ?? 0) + 1;
    final blended = previous == null
        ? measured
        : (previous.charsPerToken * previous.samples + measured) / samples;

    final rate = switch ((previous?.promptTokensPerSecond, promptTokensPerSecond)) {
      (null, final now?) => now,
      (final before?, final now?) => before * 0.7 + now * 0.3,
      (final before?, null) => before,
      _ => null,
    };

    return ModelCalibration(
      charsPerToken: blended.clamp(1.5, 12.0),
      samples: samples,
      promptTokensPerSecond: rate,
    );
  }
}

/// Füllstand des Kontextfensters für einen Chat.
class ContextBudget {
  const ContextBudget({
    required this.usedTokens,
    required this.limit,
    required this.measured,
    this.droppedTokens = 0,
  });

  final int usedTokens;

  /// Kommt vom Modell und kann selbst unbekannt sein — dann zeigt das UI
  /// den Verbrauch ohne Balken statt einen Balken gegen einen Fantasiewert.
  final Fact<int> limit;

  final bool measured;

  /// Tokens, die durch Abwahl oder Zusammenfassung nicht mitgesendet werden.
  final int droppedTokens;

  static const ContextBudget empty =
      ContextBudget(usedTokens: 0, limit: Fact<int>(), measured: false);

  double? get fill {
    final max = limit.value;
    if (max == null || max <= 0) return null;
    return usedTokens / max;
  }

  bool get overflows => (fill ?? 0) >= 1.0;

  bool exceeds(double threshold) => (fill ?? 0) >= threshold;

  String get usedLabel => measured ? '$usedTokens' : '~$usedTokens';
}

/// Zählt, was tatsächlich gesendet würde: abgewählte und ersetzte Nachrichten
/// bleiben sichtbar, zählen hier aber nicht mit.
ContextBudget computeBudget({
  required List<ChatMessage> messages,
  required ModelEntry? entry,
  required ModelRef? ref,
  required TokenEstimator estimator,
  String? systemPrompt,
}) {
  if (ref == null) return ContextBudget.empty;

  var used = 0;
  var dropped = 0;

  void count(String text, bool included) {
    // Rollen-Overhead pro Nachricht, grob konstant über Chat-Templates.
    final tokens = estimator.estimate(text, ref) + 4;
    if (included) {
      used += tokens;
    } else {
      dropped += tokens;
    }
  }

  if (systemPrompt != null && systemPrompt.isNotEmpty) {
    count(systemPrompt, true);
  }

  for (final message in messages) {
    if (message.status == MessageStatus.failed ||
        message.status == MessageStatus.cancelled) {
      continue;
    }
    count(message.content, message.includeInContext);
    for (final attachment in message.attachments) {
      final text = attachment.extractedText;
      if (text != null && text.isNotEmpty) {
        count(text, message.includeInContext);
      }
    }
  }

  return ContextBudget(
    usedTokens: used,
    limit: entry?.effectiveContext ??
        const Fact<int>(
          certainty: Certainty.unknown,
          note: 'Modell nicht in der Liste des Gateways gefunden',
        ),
    measured: estimator.isMeasured(ref),
    droppedTokens: dropped,
  );
}
