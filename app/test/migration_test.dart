import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_remote/src/data/chat_store.dart';
import 'package:local_ai_remote/src/models/chat.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Migration von einer alten Datenbank auf den aktuellen Stand.
///
/// Der Verlauf ist das einzige, was die App nicht neu beschaffen kann. Eine
/// kaputte Migration merkt man erst beim ersten Start nach dem Update — und
/// dann ist es zu spaet. In dieser Sitzung ist genau das einmal passiert.
void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  late String pfad;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('migration_test');
    pfad = '${tmp.path}/chats.db';
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // Unter Windows haelt manchmal noch ein Handle; fuer den Test egal.
    }
  });

  /// Legt eine Datenbank im Stand v1 an — so sah das Schema vor Denkschritten
  /// und Recherche aus.
  Future<void> legeV1An() async {
    final db = await databaseFactoryFfi.openDatabase(
      pfad,
      options: OpenDatabaseOptions(version: 1),
    );
    await db.execute('''
      CREATE TABLE chats (
        id TEXT PRIMARY KEY, title TEXT NOT NULL,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        backend TEXT, model TEXT,
        compression_enabled INTEGER NOT NULL DEFAULT 0,
        system_prompt TEXT)''');
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
        role TEXT NOT NULL, content TEXT NOT NULL, status TEXT NOT NULL,
        created_at INTEGER NOT NULL, request_id TEXT, error TEXT,
        include_in_context INTEGER NOT NULL DEFAULT 1,
        summary_of TEXT, metrics TEXT)''');
    await db.execute(
        'CREATE INDEX idx_messages_chat ON messages(chat_id, created_at)');
    await db.execute(
        'CREATE UNIQUE INDEX idx_messages_request ON messages(request_id) '
        'WHERE request_id IS NOT NULL');
    await db.execute('''
      CREATE TABLE attachments (
        id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        kind TEXT NOT NULL, filename TEXT NOT NULL, path TEXT NOT NULL,
        bytes INTEGER NOT NULL DEFAULT 0,
        extracted_text TEXT, estimated_tokens INTEGER)''');
    await db.execute('''
      CREATE TABLE calibration (
        model_key TEXT PRIMARY KEY, chars_per_token REAL NOT NULL,
        samples INTEGER NOT NULL, prompt_tokens_per_second REAL)''');

    await db.insert('chats', {
      'id': 'alt', 'title': 'Alter Chat',
      'created_at': 1, 'updated_at': 1, 'compression_enabled': 0,
    });
    await db.insert('messages', {
      'id': 'm1', 'chat_id': 'alt', 'role': 'user',
      'content': 'Frage von frueher', 'status': 'complete',
      'created_at': 1, 'include_in_context': 1,
    });
    await db.close();
  }

  test('v1 -> aktuell: der Verlauf ueberlebt', () async {
    await legeV1An();

    final store = await ChatStore.open(path: pfad);
    addTearDown(store.close);

    final chat = await store.chat('alt');
    expect(chat, isNotNull);
    expect(chat!.title, 'Alter Chat');
    // Die Voreinstellungen der neuen Spalten muessen greifen.
    expect(chat.researchEnabled, isFalse);

    final messages = await store.messages('alt');
    expect(messages, hasLength(1));
    expect(messages.single.content, 'Frage von frueher');
    // Die neuen Felder sind leer, aber lesbar — kein Absturz beim Parsen.
    expect(messages.single.reasoning, isNull);
    expect(messages.single.toolCalls, isEmpty);
    expect(messages.single.quellen, isEmpty);
  });

  test('nach der Migration laesst sich das Neue auch schreiben', () async {
    await legeV1An();
    final store = await ChatStore.open(path: pfad);
    addTearDown(store.close);

    await store.insertMessage(ChatMessage(
      id: 'neu',
      chatId: 'alt',
      role: MessageRole.tool,
      content: 'Ergebnis',
      status: MessageStatus.complete,
      createdAt: DateTime(2026, 1, 1),
      toolCallId: 'call_1',
      toolName: 'web_search',
      quellen: const [Quelle(titel: 'Quelle', url: 'https://example.com')],
    ));

    final geladen = (await store.messages('alt')).last;
    expect(geladen.role, MessageRole.tool);
    expect(geladen.quellen.single.url, 'https://example.com');
  });

  test('zweimal oeffnen migriert nicht doppelt', () async {
    await legeV1An();
    final erst = await ChatStore.open(path: pfad);
    await erst.close();

    // Ein zweites ALTER TABLE auf dieselbe Spalte wuerde werfen.
    final zweit = await ChatStore.open(path: pfad);
    addTearDown(zweit.close);
    expect(await zweit.messages('alt'), hasLength(1));
  });
}
