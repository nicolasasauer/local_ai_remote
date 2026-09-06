import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_remote/src/data/chat_store.dart';
import 'package:local_ai_remote/src/models/chat.dart';
import 'package:local_ai_remote/src/models/model_entry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regressionen rund um die Persistenz. Der Verlauf ist das einzige, was die
/// App nicht neu beschaffen kann — jeder Fehler hier ist Datenverlust.
void main() {
  late ChatStore store;

  setUpAll(sqfliteFfiInit);

  // In-Memory: jeder Test bekommt eine frische Datenbank, und unter Windows
  // haelt keine offene Datei den Aufraeumschritt auf.
  setUp(() async => store = await ChatStore.open(path: inMemoryDatabasePath));

  tearDown(() async => store.close());

  Chat newChat({String title = 'Neuer Chat', ModelRef? model}) => Chat(
        id: 'c1',
        title: title,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        model: model,
      );

  ChatMessage msg(String id, String content) => ChatMessage(
        id: id,
        chatId: 'c1',
        role: MessageRole.user,
        content: content,
        status: MessageStatus.complete,
        createdAt: DateTime(2026, 1, 1),
      );

  group('upsertChat', () {
    // Der teuerste Fehler des Projekts: `ConflictAlgorithm.replace` wird zu
    // INSERT OR REPLACE, SQLite loescht dabei die Chat-Zeile, und
    // ON DELETE CASCADE nimmt den gesamten Verlauf mit. Ausgeloest wurde das
    // beim automatischen Umbenennen nach der ersten Frage.
    test('Umbenennen loescht die Nachrichten nicht', () async {
      await store.upsertChat(newChat());
      await store.insertMessage(msg('m1', 'Meine Frage'));

      await store.upsertChat(newChat(title: 'Meine Frage'));

      final messages = await store.messages('c1');
      expect(messages, hasLength(1));
      expect(messages.single.content, 'Meine Frage');
      expect((await store.chat('c1'))!.title, 'Meine Frage');
    });

    test('Modellwechsel loescht die Nachrichten nicht', () async {
      await store.upsertChat(newChat());
      await store.insertMessage(msg('m1', 'Frage'));
      await store.insertMessage(msg('m2', 'Noch eine'));

      await store.upsertChat(
        newChat(model: const ModelRef(BackendId.ollama, 'gemma4:e4b')),
      );

      expect(await store.messages('c1'), hasLength(2));
      expect((await store.chat('c1'))!.model?.id, 'gemma4:e4b');
    });

    test('legt einen neuen Chat an, wenn es ihn noch nicht gibt', () async {
      await store.upsertChat(newChat(title: 'Frisch'));
      expect((await store.chat('c1'))!.title, 'Frisch');
      expect(await store.listChats(), hasLength(1));
    });
  });

  group('Loeschen', () {
    test('Chat loeschen raeumt die Nachrichten mit ab', () async {
      await store.upsertChat(newChat());
      await store.insertMessage(msg('m1', 'Frage'));

      await store.deleteChat('c1');

      expect(await store.chat('c1'), isNull);
      expect(await store.messages('c1'), isEmpty);
    });
  });

  group('recoverInterrupted', () {
    test('markiert haengengebliebene Antworten statt sie durchgehen zu lassen',
        () async {
      await store.upsertChat(newChat());
      await store.insertMessage(ChatMessage(
        id: 'm1',
        chatId: 'c1',
        role: MessageRole.assistant,
        content: 'halbe Antw',
        status: MessageStatus.streaming,
        createdAt: DateTime(2026, 1, 1),
      ));

      await store.recoverInterrupted();

      final recovered = (await store.messages('c1')).single;
      expect(recovered.status, MessageStatus.interrupted);
      expect(recovered.content, 'halbe Antw', reason: 'Teiltext bleibt stehen');
      expect(recovered.error, isNotNull, reason: 'Grund wird festgehalten');
    });
  });

  group('Denkschritte', () {
    test('werden getrennt vom Antworttext persistiert', () async {
      await store.upsertChat(newChat());
      await store.insertMessage(ChatMessage(
        id: 'm1',
        chatId: 'c1',
        role: MessageRole.assistant,
        content: '',
        status: MessageStatus.streaming,
        createdAt: DateTime(2026, 1, 1),
      ));

      await store.appendStreamingText('m1', '', reasoning: 'erst denken');
      await store.finishMessage('m1',
          content: 'dann antworten',
          status: MessageStatus.complete,
          reasoning: 'erst denken');

      final m = (await store.messages('c1')).single;
      expect(m.content, 'dann antworten');
      expect(m.reasoning, 'erst denken');
      expect(m.hasReasoning, isTrue);
    });
  });

  group('Recherche', () {
    test('Werkzeugaufruf und Ergebnis ueberleben den Verlauf', () async {
      await store.upsertChat(newChat());
      await store.insertMessage(ChatMessage(
        id: 'a1',
        chatId: 'c1',
        role: MessageRole.assistant,
        content: '',
        status: MessageStatus.complete,
        createdAt: DateTime(2026, 1, 1),
        toolCalls: const [
          ToolCall(id: 'call_1', name: 'web_search',
              arguments: '{"query": "Wetter Berlin"}'),
        ],
      ));
      await store.insertMessage(ChatMessage(
        id: 't1',
        chatId: 'c1',
        role: MessageRole.tool,
        content: '12 Grad',
        status: MessageStatus.complete,
        createdAt: DateTime(2026, 1, 2),
        toolCallId: 'call_1',
        toolName: 'web_search',
        quellen: const [Quelle(titel: 'Wetterdienst', url: 'https://example.com')],
      ));

      final messages = await store.messages('c1');
      expect(messages.first.toolCalls.single.name, 'web_search');
      expect(messages.first.hasToolCalls, isTrue);
      expect(messages.last.role, MessageRole.tool);
      expect(messages.last.toolCallId, 'call_1');
      expect(messages.last.quellen.single.url, 'https://example.com');
    });

    test('Recherche ist pro Chat abschaltbar und bleibt aus', () async {
      await store.upsertChat(newChat());
      expect((await store.chat('c1'))!.researchEnabled, isFalse,
          reason: 'aus, solange niemand sie einschaltet');

      await store.upsertChat(newChat().copyWith(researchEnabled: true));
      expect((await store.chat('c1'))!.researchEnabled, isTrue);
    });

    test('Beschreibung eines Aufrufs nennt den Gegenstand', () {
      // Ohne das waere die Freigabe eine Zusage ohne Gegenstand.
      const suche = ToolCall(
          id: 'x', name: 'web_search', arguments: '{"query": "Kaffeepreise"}');
      expect(suche.beschreibung, contains('Kaffeepreise'));

      const abruf = ToolCall(
          id: 'y', name: 'fetch_url', arguments: '{"url": "https://example.com"}');
      expect(abruf.beschreibung, contains('example.com'));
    });

    test('Kaputte Argumente kippen die Beschreibung nicht', () {
      const kaputt = ToolCall(id: 'z', name: 'web_search', arguments: '{nicht json');
      expect(kaputt.beschreibung, isNotEmpty);
    });
  });
}
