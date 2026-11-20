import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/chat.dart';
import '../models/model_entry.dart';

/// Die Datenbank ist die Wahrheit, nicht der RAM. Jede Nachricht ist
/// persistiert, bevor ein Request rausgeht, und eine laufende Antwort wird
/// fortgeschrieben — ein Absturz kostet höchstens die letzten 300 ms Text.
class ChatStore {
  ChatStore._(this._db);

  final Database _db;

  /// [path] überschreibt den Speicherort. Nur für Tests gedacht: dort gibt es
  /// kein path_provider, und jeder Testlauf braucht eine eigene Datei.
  static Future<ChatStore> open({String? path}) async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final location = path ??
        p.join((await getApplicationSupportDirectory()).path, 'chats.db');
    final db = await databaseFactory.openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: 4,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    final store = ChatStore._(db);
    await store.recoverInterrupted();
    return store;
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE chats (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        backend TEXT,
        model TEXT,
        compression_enabled INTEGER NOT NULL DEFAULT 0,
        system_prompt TEXT,
        research_enabled INTEGER NOT NULL DEFAULT 0,
        temperature REAL,
        think INTEGER
      )''');

    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        request_id TEXT,
        error TEXT,
        include_in_context INTEGER NOT NULL DEFAULT 1,
        summary_of TEXT,
        metrics TEXT,
        reasoning TEXT,
        tool_calls TEXT,
        tool_call_id TEXT,
        tool_name TEXT,
        quellen TEXT,
        requested_model TEXT
      )''');

    await db.execute(
        'CREATE INDEX idx_messages_chat ON messages(chat_id, created_at)');

    // Verhindert Dubletten, wenn ein Retry nach Verbindungsabriss durchgeht,
    // obwohl der erste Versuch doch noch angekommen war.
    await db.execute(
        'CREATE UNIQUE INDEX idx_messages_request ON messages(request_id) '
        'WHERE request_id IS NOT NULL');

    await db.execute('''
      CREATE TABLE attachments (
        id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        filename TEXT NOT NULL,
        path TEXT NOT NULL,
        bytes INTEGER NOT NULL DEFAULT 0,
        extracted_text TEXT,
        estimated_tokens INTEGER
      )''');

    // Gemessenes Verhältnis Zeichen/Token pro Modell. Ersetzt mit der Zeit
    // die Heuristik.
    await db.execute('''
      CREATE TABLE calibration (
        model_key TEXT PRIMARY KEY,
        chars_per_token REAL NOT NULL,
        samples INTEGER NOT NULL,
        prompt_tokens_per_second REAL
      )''');
  }

  /// Denkschritte kamen erst mit v2 dazu. Bestehende Datenbanken bekommen die
  /// Spalte nachgereicht, statt bei jedem Start über die fehlende zu stolpern.
  static Future<void> _upgradeSchema(Database db, int from, int to) async {
    if (from < 2) {
      await db.execute('ALTER TABLE messages ADD COLUMN reasoning TEXT');
    }
    if (from < 3) {
      // Recherche kam mit v3 dazu: Werkzeugaufrufe, ihre Ergebnisse und die
      // Quellen, auf denen eine Antwort beruht.
      for (final spalte in [
        'tool_calls TEXT',
        'tool_call_id TEXT',
        'tool_name TEXT',
        'quellen TEXT',
        'requested_model TEXT',
      ]) {
        await db.execute('ALTER TABLE messages ADD COLUMN $spalte');
      }
      await db.execute(
          'ALTER TABLE chats ADD COLUMN research_enabled INTEGER NOT NULL DEFAULT 0');
    }
    if (from < 4) {
      // Antwortverhalten pro Chat (v4). NULL heisst: Vorgabe des Modells.
      await db.execute('ALTER TABLE chats ADD COLUMN temperature REAL');
      await db.execute('ALTER TABLE chats ADD COLUMN think INTEGER');
    }
  }

  /// Schliesst die Datenbank. Im App-Betrieb lebt der Store so lange wie der
  /// Prozess; Tests brauchen das Gegenstueck zum Oeffnen.
  Future<void> close() => _db.close();

  /// Beim Start: alles, was noch auf `streaming` steht, kann nur ein
  /// abgebrochener Lauf sein. Wird sichtbar als Abbruch markiert, statt als
  /// vollständige Antwort durchzugehen.
  Future<int> recoverInterrupted() => _db.update(
        'messages',
        {
          'status': MessageStatus.interrupted.wire,
          'error': 'App wurde beendet, während die Antwort lief',
        },
        where: 'status = ?',
        whereArgs: [MessageStatus.streaming.wire],
      );

  // --- Chats ---------------------------------------------------------------

  Future<List<Chat>> listChats() async {
    final rows = await _db.query('chats', orderBy: 'updated_at DESC');
    return rows.map(Chat.fromRow).toList();
  }

  Future<Chat?> chat(String id) async {
    final rows = await _db.query('chats', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Chat.fromRow(rows.first);
  }

  /// Kein `ConflictAlgorithm.replace`: das übersetzt sich zu
  /// `INSERT OR REPLACE`, und SQLite *löscht* dabei die bestehende Zeile,
  /// bevor es die neue einfügt. Mit `ON DELETE CASCADE` auf `messages` reisst
  /// das den kompletten Verlauf mit — beim Umbenennen nach der ersten Frage
  /// ebenso wie beim Modellwechsel. Ein echtes UPSERT fasst die Zeile an,
  /// statt sie zu ersetzen.
  Future<void> upsertChat(Chat chat) async {
    final row = chat.toRow();
    final columns = row.keys.toList();
    final placeholders = List.filled(columns.length, '?').join(', ');
    final assignments =
        columns.where((c) => c != 'id').map((c) => '$c = excluded.$c').join(', ');
    await _db.rawInsert(
      'INSERT INTO chats (${columns.join(', ')}) VALUES ($placeholders) '
      'ON CONFLICT(id) DO UPDATE SET $assignments',
      columns.map((c) => row[c]).toList(),
    );
  }

  Future<void> touchChat(String id) => _db.update(
        'chats',
        {'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> deleteChat(String id) =>
      _db.delete('chats', where: 'id = ?', whereArgs: [id]);

  Future<int> messageCount(String chatId) async {
    final rows = await _db.rawQuery(
        'SELECT COUNT(*) AS n FROM messages WHERE chat_id = ?', [chatId]);
    return (rows.first['n'] as int?) ?? 0;
  }

  // --- Nachrichten ---------------------------------------------------------

  Future<List<ChatMessage>> messages(String chatId) async {
    final rows = await _db.query('messages',
        where: 'chat_id = ?', whereArgs: [chatId], orderBy: 'created_at ASC');

    final ids = rows.map((r) => r['id'] as String).toList();
    final byMessage = <String, List<Attachment>>{};
    if (ids.isNotEmpty) {
      final placeholders = List.filled(ids.length, '?').join(',');
      final attachmentRows = await _db.query('attachments',
          where: 'message_id IN ($placeholders)', whereArgs: ids);
      for (final row in attachmentRows) {
        final attachment = Attachment.fromRow(row);
        byMessage.putIfAbsent(attachment.messageId, () => []).add(attachment);
      }
    }

    return rows
        .map((r) => ChatMessage.fromRow(
              r,
              attachments: byMessage[r['id'] as String] ?? const [],
            ))
        .toList();
  }

  Future<void> insertMessage(ChatMessage message) async {
    await _db.insert('messages', message.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    for (final attachment in message.attachments) {
      await _db.insert('attachments', attachment.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await touchChat(message.chatId);
  }

  /// Fortschreiben des laufenden Texts. Wird vom Controller gedrosselt
  /// aufgerufen, nicht bei jedem Token.
  Future<void> appendStreamingText(
    String messageId,
    String content, {
    String? reasoning,
  }) =>
      _db.update(
        'messages',
        {
          'content': content,
          if (reasoning != null) 'reasoning': reasoning,
        },
        where: 'id = ?',
        whereArgs: [messageId],
      );

  Future<void> finishMessage(
    String messageId, {
    required String content,
    required MessageStatus status,
    String? metricsJson,
    String? error,
    String? reasoning,
    List<ToolCall>? toolCalls,
  }) =>
      _db.update(
        'messages',
        {
          'content': content,
          'status': status.wire,
          'metrics': metricsJson,
          'error': error,
          if (reasoning != null) 'reasoning': reasoning,
          if (toolCalls != null && toolCalls.isNotEmpty)
            'tool_calls': ToolCall.encode(toolCalls),
        },
        where: 'id = ?',
        whereArgs: [messageId],
      );

  Future<void> setIncludeInContext(Iterable<String> ids, bool include) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.update(
      'messages',
      {'include_in_context': include ? 1 : 0},
      where: 'id IN ($placeholders)',
      whereArgs: ids.toList(),
    );
  }

  Future<void> deleteMessage(String id) =>
      _db.delete('messages', where: 'id = ?', whereArgs: [id]);

  // --- Kalibrierung --------------------------------------------------------

  static String modelKey(ModelRef ref) => '${ref.backend.wire}|${ref.id}';

  Future<Map<String, ModelCalibration>> calibrations() async {
    final rows = await _db.query('calibration');
    return {
      for (final r in rows)
        r['model_key'] as String: ModelCalibration(
          charsPerToken: (r['chars_per_token'] as num).toDouble(),
          samples: (r['samples'] as int?) ?? 0,
          promptTokensPerSecond:
              (r['prompt_tokens_per_second'] as num?)?.toDouble(),
        )
    };
  }

  Future<void> saveCalibration(String key, ModelCalibration value) => _db.insert(
        'calibration',
        {
          'model_key': key,
          'chars_per_token': value.charsPerToken,
          'samples': value.samples,
          'prompt_tokens_per_second': value.promptTokensPerSecond,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
}

class ModelCalibration {
  const ModelCalibration({
    required this.charsPerToken,
    required this.samples,
    this.promptTokensPerSecond,
  });

  final double charsPerToken;
  final int samples;
  final double? promptTokensPerSecond;
}
