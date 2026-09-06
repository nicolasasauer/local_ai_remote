import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_remote/src/models/chat.dart';
import 'package:local_ai_remote/src/ui/widgets/message_view.dart';

/// Was die Nachricht anzeigt, ist die letzte Stelle, an der Ehrlichkeit
/// verloren gehen kann: die Daten sind da, aber niemand sieht sie.
void main() {
  ChatMessage antwort({
    String content = 'Die Antwort',
    String? reasoning,
    MessageStatus status = MessageStatus.complete,
    String? error,
    Map<String, dynamic>? metrics,
  }) =>
      ChatMessage(
        id: 'm1',
        chatId: 'c1',
        role: MessageRole.assistant,
        content: content,
        status: status,
        createdAt: DateTime(2026, 1, 1),
        error: error,
        reasoning: reasoning,
        metrics: metrics == null
            ? null
            : ChatMetrics.decode(jsonEncode(metrics)),
      );

  Future<void> zeige(
    WidgetTester tester,
    ChatMessage message, {
    String? expectedModel,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MessageView(
            message: message,
            expectedModel: expectedModel,
            onRetry: () {},
            onToggleInclude: () {},
            onUndoSummary: () {},
          ),
        ),
      ),
    ));
  }

  Map<String, dynamic> fact(Object? value) =>
      {'value': value, 'certainty': value == null ? 'unknown' : 'known', 'note': null};

  group('Modellverwechslung', () {
    testWidgets('wird gemeldet, wenn ein anderes Modell geantwortet hat',
        (tester) async {
      await zeige(
        tester,
        antwort(metrics: {'served_model': fact('gemma-4-26b')}),
        expectedModel: 'qwen3-coder-30b',
      );

      expect(find.textContaining('gemma-4-26b'), findsOneWidget);
      expect(find.textContaining('qwen3-coder-30b'), findsOneWidget);
    });

    testWidgets('bleibt still, wenn es passt', (tester) async {
      await zeige(
        tester,
        antwort(metrics: {'served_model': fact('qwen3-coder-30b')}),
        expectedModel: 'qwen3-coder-30b',
      );

      expect(find.textContaining('Geantwortet hat'), findsNothing);
    });

    testWidgets('bleibt still, wenn das Backend nichts meldet', (tester) async {
      // Lieber keine Aussage als eine erfundene.
      await zeige(
        tester,
        antwort(metrics: {'served_model': fact(null)}),
        expectedModel: 'qwen3-coder-30b',
      );

      expect(find.textContaining('Geantwortet hat'), findsNothing);
    });
  });

  group('Unterbrochene Antwort', () {
    testWidgets('nennt den festgehaltenen Grund', (tester) async {
      // Ein Netzabriss mitten in der Sitzung ist etwas anderes als ein
      // Absturz der App - den Unterschied kennt nur diese Zeile.
      await zeige(
        tester,
        antwort(
          content: 'halbe Antw',
          status: MessageStatus.interrupted,
          error: 'Stream abgebrochen: Connection closed',
        ),
      );

      expect(find.textContaining('Connection closed'), findsOneWidget);
      expect(find.text('halbe Antw'), findsOneWidget,
          reason: 'Teiltext bleibt sichtbar');
    });

    testWidgets('faellt auf einen neutralen Text zurueck', (tester) async {
      await zeige(tester, antwort(status: MessageStatus.interrupted));
      expect(find.textContaining('Unterbrochen'), findsOneWidget);
    });
  });

  group('Denkschritte', () {
    testWidgets('stehen getrennt vom Antworttext', (tester) async {
      await zeige(tester, antwort(content: 'Paris', reasoning: 'erst denken'));

      expect(find.text('Paris'), findsOneWidget);
      expect(find.textContaining('Denkschritte'), findsOneWidget);
      // Eingeklappt, solange nichts laeuft: sie sind oft laenger als die
      // Antwort und wuerden sie sonst zudecken.
      expect(find.text('erst denken'), findsNothing);
    });

    testWidgets('lassen sich aufklappen', (tester) async {
      await zeige(tester, antwort(content: 'Paris', reasoning: 'erst denken'));

      await tester.tap(find.textContaining('Denkschritte'));
      await tester.pumpAndSettle();

      expect(find.text('erst denken'), findsOneWidget);
    });
  });

  group('Markdown', () {
    testWidgets('Auszeichnungen stehen nicht mehr woertlich da', (tester) async {
      // Modelle schreiben Markdown. Ohne Aufbereitung liest man `**` im Chat.
      await zeige(tester, antwort(content: 'Die Hauptstadt ist **Rom**.'));

      expect(find.textContaining('**'), findsNothing);
      // Der Text selbst bleibt vollständig lesbar.
      expect(find.textContaining('Rom'), findsWidgets);
    });

    testWidgets('halbfertige Syntax kippt die Anzeige nicht', (tester) async {
      // Während des Streams ist der Text zwangsläufig unvollständig.
      await zeige(tester, antwort(content: 'Ein **halb offener'));
      expect(tester.takeException(), isNull);
    });
  });

  group('Modellabweichung nach Modellwechsel', () {
    testWidgets('vergleicht gegen das angefragte Modell', (tester) async {
      // Ein späterer Wechsel im Chat darf alte Antworten nicht rückwirkend
      // als "falsches Modell" markieren.
      final m = ChatMessage(
        id: 'm1',
        chatId: 'c1',
        role: MessageRole.assistant,
        content: 'Antwort',
        status: MessageStatus.complete,
        createdAt: DateTime(2026, 1, 1),
        requestedModel: 'llama3.2:1b',
        metrics: ChatMetrics.decode(jsonEncode({
          'served_model': {'value': 'llama3.2:1b', 'certainty': 'known', 'note': null}
        })),
      );

      await zeige(tester, m, expectedModel: 'qwen3.6-35b');

      expect(find.textContaining('Geantwortet hat'), findsNothing);
    });
  });
}
