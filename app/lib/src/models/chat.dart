import 'dart:convert';

import 'fact.dart';
import 'model_entry.dart';

enum MessageRole {
  user('user'),
  assistant('assistant'),
  system('system'),

  /// Zusammenfassung älterer Nachrichten. Wird als System-Rolle gesendet,
  /// bleibt im UI aber unterscheidbar.
  summary('summary');

  const MessageRole(this.wire);
  final String wire;

  String get sendAs => this == MessageRole.summary ? 'system' : wire;

  static MessageRole parse(String raw) =>
      MessageRole.values.firstWhere((r) => r.wire == raw,
          orElse: () => MessageRole.assistant);
}

enum MessageStatus {
  complete('complete'),
  streaming('streaming'),

  /// App wurde beendet oder abgeschossen, während die Antwort lief.
  interrupted('interrupted'),
  failed('failed'),
  cancelled('cancelled');

  const MessageStatus(this.wire);
  final String wire;

  static MessageStatus parse(String raw) =>
      MessageStatus.values.firstWhere((s) => s.wire == raw,
          orElse: () => MessageStatus.complete);
}

enum AttachmentKind { image, pdf, text }

class Attachment {
  const Attachment({
    required this.id,
    required this.messageId,
    required this.kind,
    required this.filename,
    required this.path,
    required this.bytes,
    this.extractedText,
    this.estimatedTokens,
  });

  final String id;
  final String messageId;
  final AttachmentKind kind;
  final String filename;
  final String path;
  final int bytes;

  /// Nur bei PDFs: der extrahierte Text. Die Extraktion passiert in der App,
  /// weil kein Inferenz-Backend PDFs annimmt.
  final String? extractedText;
  final int? estimatedTokens;

  Map<String, Object?> toRow() => {
        'id': id,
        'message_id': messageId,
        'kind': kind.name,
        'filename': filename,
        'path': path,
        'bytes': bytes,
        'extracted_text': extractedText,
        'estimated_tokens': estimatedTokens,
      };

  static Attachment fromRow(Map<String, Object?> r) => Attachment(
        id: r['id'] as String,
        messageId: r['message_id'] as String,
        kind: AttachmentKind.values.firstWhere(
          (k) => k.name == r['kind'],
          orElse: () => AttachmentKind.text,
        ),
        filename: r['filename'] as String,
        path: r['path'] as String,
        bytes: (r['bytes'] as int?) ?? 0,
        extractedText: r['extracted_text'] as String?,
        estimatedTokens: r['estimated_tokens'] as int?,
      );
}

/// Kennzahlen einer Antwort. Der Rohwert vom Gateway wird mitgeführt, damit
/// er unverändert in die Datenbank wandert.
class ChatMetrics {
  const ChatMetrics({required this.raw});

  final Map<String, dynamic> raw;

  Fact<double> get totalMs => Fact.asDouble(raw['total_ms']);
  Fact<double> get loadMs => Fact.asDouble(raw['load_ms']);
  Fact<double> get timeToFirstTokenMs =>
      Fact.asDouble(raw['time_to_first_token_ms']);
  Fact<int> get promptTokens => Fact.asInt(raw['prompt_tokens']);
  Fact<int> get completionTokens => Fact.asInt(raw['completion_tokens']);
  Fact<double> get tokensPerSecond => Fact.asDouble(raw['tokens_per_second']);
  Fact<String> get stopReason => Fact.asString(raw['stop_reason']);

  /// Das Modell, das laut Backend geantwortet hat. LM Studio beantwortet
  /// jeden Namen mit dem gerade geladenen Modell — ohne dieses Feld bliebe
  /// unbemerkt, dass die Antwort von einem anderen stammt als gewählt.
  Fact<String> get servedModel => Fact.asString(raw['served_model']);

  String encode() => jsonEncode(raw);

  static ChatMetrics? decode(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      return ChatMetrics(raw: jsonDecode(source) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.chatId,
    required this.role,
    required this.content,
    required this.status,
    required this.createdAt,
    this.requestId,
    this.error,
    this.includeInContext = true,
    this.summaryOf = const [],
    this.metrics,
    this.attachments = const [],
    this.reasoning,
  });

  final String id;
  final String chatId;
  final MessageRole role;
  final String content;
  final MessageStatus status;
  final DateTime createdAt;

  /// Idempotenzschlüssel: verhindert, dass ein Wiederholen nach Absturz
  /// dieselbe Antwort doppelt anlegt.
  final String? requestId;
  final String? error;

  /// Abwählbar, ohne zu löschen — so bleibt die Nachricht sichtbar, zählt
  /// aber nicht mehr gegen das Kontextfenster.
  final bool includeInContext;

  /// IDs der Nachrichten, die diese Zusammenfassung ersetzt.
  final List<String> summaryOf;

  final ChatMetrics? metrics;
  final List<Attachment> attachments;

  /// Denkschritte eines Reasoning-Modells. Gehören nicht in den Kontext des
  /// nächsten Zuges, sind aber bei abgeschnittener Antwort der einzige Inhalt
  /// — deshalb persistiert statt nur live angezeigt.
  final String? reasoning;

  bool get hasReasoning => (reasoning ?? '').isNotEmpty;

  bool get isRunning => status == MessageStatus.streaming;
  bool get isSummary => role == MessageRole.summary;

  ChatMessage copyWith({
    String? content,
    MessageStatus? status,
    String? error,
    bool? includeInContext,
    ChatMetrics? metrics,
    List<Attachment>? attachments,
    String? reasoning,
  }) =>
      ChatMessage(
        id: id,
        chatId: chatId,
        role: role,
        content: content ?? this.content,
        status: status ?? this.status,
        createdAt: createdAt,
        requestId: requestId,
        error: error ?? this.error,
        includeInContext: includeInContext ?? this.includeInContext,
        summaryOf: summaryOf,
        metrics: metrics ?? this.metrics,
        attachments: attachments ?? this.attachments,
        reasoning: reasoning ?? this.reasoning,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'chat_id': chatId,
        'role': role.wire,
        'content': content,
        'status': status.wire,
        'created_at': createdAt.millisecondsSinceEpoch,
        'request_id': requestId,
        'error': error,
        'include_in_context': includeInContext ? 1 : 0,
        'summary_of': summaryOf.isEmpty ? null : jsonEncode(summaryOf),
        'metrics': metrics?.encode(),
        'reasoning': reasoning,
      };

  static ChatMessage fromRow(
    Map<String, Object?> r, {
    List<Attachment> attachments = const [],
  }) =>
      ChatMessage(
        id: r['id'] as String,
        chatId: r['chat_id'] as String,
        role: MessageRole.parse(r['role'] as String),
        content: (r['content'] as String?) ?? '',
        status: MessageStatus.parse(r['status'] as String),
        createdAt:
            DateTime.fromMillisecondsSinceEpoch((r['created_at'] as int?) ?? 0),
        requestId: r['request_id'] as String?,
        error: r['error'] as String?,
        includeInContext: ((r['include_in_context'] as int?) ?? 1) == 1,
        summaryOf: switch (r['summary_of']) {
          final String s when s.isNotEmpty =>
            (jsonDecode(s) as List<dynamic>).cast<String>(),
          _ => const [],
        },
        metrics: ChatMetrics.decode(r['metrics'] as String?),
        attachments: attachments,
        reasoning: r['reasoning'] as String?,
      );
}

class Chat {
  const Chat({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.model,
    this.compressionEnabled = false,
    this.systemPrompt,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Modell gehört zum Chat, nicht zur App — sonst wechselt ein Umschalten
  /// stillschweigend das Modell aller offenen Unterhaltungen.
  final ModelRef? model;

  /// Standardmäßig aus: Zusammenfassen ist verlustbehaftet.
  final bool compressionEnabled;

  final String? systemPrompt;

  /// Gleichheit nur über die id: der Chat dient als Schlüssel einer
  /// Provider-Family, und ein Umbenennen mitten im Stream darf den laufenden
  /// Controller nicht ersetzen.
  @override
  bool operator ==(Object other) => other is Chat && other.id == id;

  @override
  int get hashCode => id.hashCode;

  Chat copyWith({
    String? title,
    ModelRef? model,
    bool? compressionEnabled,
    String? systemPrompt,
    DateTime? updatedAt,
  }) =>
      Chat(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        model: model ?? this.model,
        compressionEnabled: compressionEnabled ?? this.compressionEnabled,
        systemPrompt: systemPrompt ?? this.systemPrompt,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'backend': model?.backend.wire,
        'model': model?.id,
        'compression_enabled': compressionEnabled ? 1 : 0,
        'system_prompt': systemPrompt,
      };

  static Chat fromRow(Map<String, Object?> r) {
    final backend = r['backend'] as String?;
    final model = r['model'] as String?;
    return Chat(
      id: r['id'] as String,
      title: (r['title'] as String?) ?? 'Neuer Chat',
      createdAt:
          DateTime.fromMillisecondsSinceEpoch((r['created_at'] as int?) ?? 0),
      updatedAt:
          DateTime.fromMillisecondsSinceEpoch((r['updated_at'] as int?) ?? 0),
      model: (backend != null && model != null)
          ? ModelRef(BackendId.parse(backend), model)
          : null,
      compressionEnabled: ((r['compression_enabled'] as int?) ?? 0) == 1,
      systemPrompt: r['system_prompt'] as String?,
    );
  }
}

/// Zustandsmaschine eines Sendevorgangs. Jeder Übergang hat ein reales
/// Signal als Auslöser — nichts davon ist geraten.
enum SendPhase {
  idle('Bereit'),
  queued('In der Warteschlange'),
  connecting('Verbinde mit Gateway'),
  accepted('Vom Gateway angenommen'),
  loadingModel('Modell wird in den Speicher geladen'),
  processingPrompt('Prompt wird verarbeitet'),
  generating('Antwortet'),
  stalled('Keine Rückmeldung'),
  done('Fertig'),
  failed('Fehlgeschlagen'),
  cancelled('Abgebrochen');

  const SendPhase(this.label);
  final String label;

  bool get isActive => const {
        SendPhase.queued,
        SendPhase.connecting,
        SendPhase.accepted,
        SendPhase.loadingModel,
        SendPhase.processingPrompt,
        SendPhase.generating,
        SendPhase.stalled,
      }.contains(this);
}

class SendState {
  const SendState({
    this.phase = SendPhase.idle,
    this.startedAt,
    this.endedAt,
    this.lastEventAt,
    this.note,
    this.error,
    this.streamingMessageId,
    this.promptTokenEstimate,
    this.estimateIsMeasured = false,
    this.expectedPromptSeconds,
  });

  final SendPhase phase;
  final DateTime? startedAt;

  /// Zeitpunkt des Abschlusses. Ohne den liefe die Uhr nach einem Fehler
  /// weiter und die Karte behauptete Arbeit, die längst beendet ist.
  final DateTime? endedAt;

  /// Zeitpunkt des letzten Lebenszeichens (Delta, Status oder Heartbeat).
  final DateTime? lastEventAt;

  final String? note;
  final String? error;
  final String? streamingMessageId;

  final int? promptTokenEstimate;

  /// Ob die Tokenzahl gemessen oder nur geschätzt ist. Steuert das "~"
  /// vor der Zahl im UI.
  final bool estimateIsMeasured;

  /// Nur gesetzt, wenn für dieses Modell schon eine Rate gemessen wurde.
  final double? expectedPromptSeconds;

  Duration get elapsed => startedAt == null
      ? Duration.zero
      : (endedAt ?? DateTime.now()).difference(startedAt!);

  /// ``clearNote``/``clearError`` sind nötig, weil ein ``null`` im
  /// benannten Parameter nicht von "nicht übergeben" zu unterscheiden ist —
  /// ohne sie klebt eine Stall-Meldung fest, auch wenn wieder Tokens fließen.
  SendState copyWith({
    SendPhase? phase,
    DateTime? startedAt,
    DateTime? endedAt,
    DateTime? lastEventAt,
    String? note,
    bool clearNote = false,
    String? error,
    bool clearError = false,
    String? streamingMessageId,
    int? promptTokenEstimate,
    bool? estimateIsMeasured,
    double? expectedPromptSeconds,
  }) =>
      SendState(
        phase: phase ?? this.phase,
        startedAt: startedAt ?? this.startedAt,
        endedAt: endedAt ?? this.endedAt,
        lastEventAt: lastEventAt ?? this.lastEventAt,
        note: clearNote ? null : (note ?? this.note),
        error: clearError ? null : (error ?? this.error),
        streamingMessageId: streamingMessageId ?? this.streamingMessageId,
        promptTokenEstimate: promptTokenEstimate ?? this.promptTokenEstimate,
        estimateIsMeasured: estimateIsMeasured ?? this.estimateIsMeasured,
        expectedPromptSeconds:
            expectedPromptSeconds ?? this.expectedPromptSeconds,
      );

  static const SendState initial = SendState();
}
