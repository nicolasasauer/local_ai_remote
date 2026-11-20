import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_remote/src/data/gateway_client.dart';
import 'package:local_ai_remote/src/models/chat.dart';
import 'package:local_ai_remote/src/models/model_entry.dart';
import 'package:local_ai_remote/src/ui/chat_list_panel.dart';
import 'package:local_ai_remote/src/ui/chat_page.dart';
import 'package:local_ai_remote/src/ui/errors.dart';

Chat chat(String id, DateTime updated, {String title = 'T'}) =>
    Chat(id: id, title: title, createdAt: updated, updatedAt: updated);

ChatMessage msg(MessageRole role, String content) => ChatMessage(
  id: '$role$content',
  chatId: 'c',
  role: role,
  content: content,
  status: MessageStatus.complete,
  createdAt: DateTime(2026),
);

void main() {
  group('Chatliste nach Alter', () {
    final now = DateTime(2026, 11, 20, 15);

    test('teilt in Abschnitte und behält die Reihenfolge', () {
      final groups = groupByAge([
        chat('a', DateTime(2026, 11, 20, 9)),
        chat('b', DateTime(2026, 11, 20, 0, 1)),
        chat('c', DateTime(2026, 11, 19, 23)),
        chat('d', DateTime(2026, 11, 15)),
        chat('e', DateTime(2026, 11, 1)),
        chat('f', DateTime(2025, 1, 1)),
      ], now);

      expect(groups.map((g) => g.label).toList(), [
        'Heute',
        'Gestern',
        'Letzte 7 Tage',
        'Letzte 30 Tage',
        'Älter',
      ]);
      expect(groups.first.chats.map((c) => c.id), ['a', 'b']);
      expect(groups.last.chats.single.id, 'f');
    });

    test('leere Liste ergibt keine Abschnitte', () {
      expect(groupByAge(const [], now), isEmpty);
    });
  });

  group('Gateway-Adresse', () {
    test('ergänzt https und entfernt Schrägstriche am Ende', () {
      expect(
        normalizeGatewayUrl('desktop.tail1.ts.net/'),
        'https://desktop.tail1.ts.net',
      );
      expect(
        normalizeGatewayUrl(' http://10.0.2.2:8765// '),
        'http://10.0.2.2:8765',
      );
      expect(normalizeGatewayUrl(''), '');
    });

    test('lehnt Unbrauchbares mit Begründung ab', () {
      expect(validateGatewayUrl('https://desktop.ts.net'), isNull);
      expect(validateGatewayUrl(''), isNull);
      expect(validateGatewayUrl('ftp://desktop'), isNotNull);
      expect(validateGatewayUrl('https://desktop?x=1'), isNotNull);
      expect(validateGatewayUrl('desktop'), isNotNull);
    });
  });

  group('Fehlerbeschreibung', () {
    test('401 verweist auf das Token', () {
      final p = describeError(GatewayException('nope', statusCode: 401));
      expect(p.headline, contains('Token'));
      expect(p.fixInSettings, isTrue);
      expect(p.detail, 'nope');
    });

    test('Netzfehler und Zeitüberschreitung bleiben unterscheidbar', () {
      expect(
        describeError(const SocketException('x')).headline,
        contains('nicht erreichbar'),
      );
      expect(
        describeError(TimeoutException('x')).headline,
        contains('Keine Antwort'),
      );
    });

    test('Unbekanntes wird wörtlich durchgereicht', () {
      expect(describeError('seltsam').headline, 'seltsam');
    });
  });

  group('Markdown-Export', () {
    test(
      'enthält Gespräch und Systemprompt, aber keine Werkzeugergebnisse',
      () {
        final c = Chat(
          id: 'c',
          title: 'Titel',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          model: const ModelRef(BackendId.ollama, 'qwen3:8b'),
          systemPrompt: 'Sei knapp.',
        );
        final md = exportMarkdown(c, [
          msg(MessageRole.user, 'Frage'),
          msg(MessageRole.tool, 'Seiteninhalt'),
          msg(MessageRole.assistant, 'Antwort'),
        ]);

        expect(md, startsWith('# Titel'));
        expect(md, contains('qwen3:8b'));
        expect(md, contains('Sei knapp.'));
        expect(md, contains('**Du:**\n\nFrage'));
        expect(md, contains('**Modell:**\n\nAntwort'));
        expect(md, isNot(contains('Seiteninhalt')));
      },
    );
  });
}
