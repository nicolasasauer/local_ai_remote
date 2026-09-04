import 'package:uuid/uuid.dart';

import '../data/chat_store.dart';
import '../data/gateway_client.dart';
import '../data/token_budget.dart';
import '../models/chat.dart';

/// Verdichtet ältere Nachrichten zu einer Zusammenfassung.
///
/// Zwei Regeln machen das umkehrbar: Die Originale werden nie gelöscht,
/// sondern nur aus dem Kontext genommen (`include_in_context = 0`), und die
/// Verdichtung läuft **nach** einer Antwort, nicht vor dem Senden — sonst
/// wartet man doppelt.
class ContextCompactor {
  ContextCompactor({
    required this.store,
    required this.client,
    this.threshold = 0.75,
    this.keepRecent = 6,
    this.minimumToSummarise = 4,
  });

  final ChatStore store;
  final GatewayClient client;

  /// Ab diesem Füllstand wird verdichtet.
  final double threshold;

  /// So viele der jüngsten Nachrichten bleiben immer wörtlich erhalten.
  final int keepRecent;

  final int minimumToSummarise;

  static const _uuid = Uuid();

  static const _instruction =
      'Fasse den folgenden Gesprächsausschnitt so zusammen, dass die '
      'Unterhaltung ohne die Originalnachrichten fortgesetzt werden kann. '
      'Übernimm Zahlen, Namen, Dateipfade, Codebezeichner und offene Fragen '
      'wörtlich. Keine Einleitung, keine Bewertung, nur der verdichtete Inhalt.';

  bool shouldRun({required Chat chat, required ContextBudget budget}) =>
      chat.compressionEnabled &&
      chat.model != null &&
      budget.exceeds(threshold);

  /// Gibt die eingesparten Tokens zurück, oder null wenn nichts passiert ist.
  Future<CompactionResult?> run({
    required Chat chat,
    required List<ChatMessage> messages,
    required TokenEstimator estimator,
  }) async {
    final ref = chat.model;
    if (ref == null) return null;

    final eligible = messages
        .where((m) =>
            m.includeInContext &&
            !m.isSummary &&
            m.status == MessageStatus.complete)
        .toList();

    if (eligible.length <= keepRecent + minimumToSummarise) return null;

    final toSummarise = eligible.sublist(0, eligible.length - keepRecent);
    final transcript = toSummarise
        .map((m) => '${m.role == MessageRole.user ? 'Nutzer' : 'Assistent'}: '
            '${m.content}')
        .join('\n\n');

    final String summary;
    try {
      summary = await client.completeOnce(
        ref: ref,
        messages: [
          {'role': 'system', 'content': _instruction},
          {'role': 'user', 'content': transcript},
        ],
      );
    } on GatewayException catch (e) {
      // Fehlschlag ist folgenlos: es wurde noch nichts verändert.
      return CompactionResult.failed(e.message);
    }

    if (summary.isEmpty) {
      return CompactionResult.failed('Das Modell lieferte keine Zusammenfassung');
    }

    final ids = toSummarise.map((m) => m.id).toList();
    final message = ChatMessage(
      id: _uuid.v4(),
      chatId: chat.id,
      role: MessageRole.summary,
      content: summary,
      status: MessageStatus.complete,
      // Zeitstempel der letzten ersetzten Nachricht, damit die Marke im
      // Transkript an der richtigen Stelle steht.
      createdAt: toSummarise.last.createdAt.add(const Duration(milliseconds: 1)),
      summaryOf: ids,
    );

    await store.insertMessage(message);
    await store.setIncludeInContext(ids, false);

    final before = toSummarise.fold<int>(
        0, (sum, m) => sum + estimator.estimate(m.content, ref));
    final after = estimator.estimate(summary, ref);

    return CompactionResult(
      replaced: ids.length,
      tokensBefore: before,
      tokensAfter: after,
    );
  }

  /// Rückgängig machen: Zusammenfassung löschen, Originale wieder aufnehmen.
  Future<void> undo(ChatMessage summary) async {
    await store.setIncludeInContext(summary.summaryOf, true);
    await store.deleteMessage(summary.id);
  }
}

class CompactionResult {
  const CompactionResult({
    required this.replaced,
    required this.tokensBefore,
    required this.tokensAfter,
    this.error,
  });

  const CompactionResult.failed(String message)
      : replaced = 0,
        tokensBefore = 0,
        tokensAfter = 0,
        error = message;

  final int replaced;
  final int tokensBefore;
  final int tokensAfter;
  final String? error;

  bool get ok => error == null && replaced > 0;
  int get saved => tokensBefore - tokensAfter;
}
