import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/chat_store.dart';
import '../data/gateway_client.dart';
import '../data/token_budget.dart';
import '../models/chat.dart';
import '../models/model_entry.dart';
import 'compaction.dart';

class ChatSession {
  const ChatSession({
    required this.chat,
    this.messages = const [],
    this.send = SendState.initial,
    this.budget = ContextBudget.empty,
    this.entry,
    this.notice,
    this.loading = true,
  });

  final Chat chat;
  final List<ChatMessage> messages;
  final SendState send;
  final ContextBudget budget;

  /// Der Modelleintrag aus der Gateway-Liste — null, wenn das Modell des
  /// Chats gerade nicht angeboten wird (Backend aus, Modell gelöscht).
  final ModelEntry? entry;

  /// Kurzer Hinweis für eine Snackbar (Verdichtung gelaufen, Warnung o.ä.).
  final String? notice;

  final bool loading;

  bool get canSend => chat.model != null && !send.phase.isActive;

  ChatSession copyWith({
    Chat? chat,
    List<ChatMessage>? messages,
    SendState? send,
    ContextBudget? budget,
    ModelEntry? entry,
    bool clearEntry = false,
    String? notice,
    bool clearNotice = false,
    bool? loading,
  }) =>
      ChatSession(
        chat: chat ?? this.chat,
        messages: messages ?? this.messages,
        send: send ?? this.send,
        budget: budget ?? this.budget,
        entry: clearEntry ? null : (entry ?? this.entry),
        notice: clearNotice ? null : (notice ?? this.notice),
        loading: loading ?? this.loading,
      );
}

/// Steuert einen einzelnen Chat: Persistenz vor dem Request, Zustandsmaschine
/// während des Streams, Watchdog gegen stille Hänger.
class ChatController extends StateNotifier<ChatSession> {
  ChatController({
    required Chat chat,
    required ChatStore store,
    required GatewayClient client,
    required Map<String, ModelCalibration> calibrations,
    this.onCalibrationSaved,
  })  : _store = store,
        _client = client,
        _calibrations = {...calibrations},
        super(ChatSession(chat: chat)) {
    _compactor = ContextCompactor(store: store, client: client);
    load();
  }

  final ChatStore _store;
  final GatewayClient _client;
  final Map<String, ModelCalibration> _calibrations;
  final void Function(String key, ModelCalibration value)? onCalibrationSaved;

  late final ContextCompactor _compactor;
  static const _uuid = Uuid();

  /// Ohne Rückmeldung gilt der Lauf nach dieser Zeit als hängend. Das Gateway
  /// sendet alle 10 s einen Heartbeat, 25 s sind also zwei verpasste.
  static const _stallAfter = Duration(seconds: 25);

  /// Der laufende Text wird gedrosselt geschrieben — ein Absturz kostet
  /// höchstens diesen Zeitraum.
  static const _flushInterval = Duration(milliseconds: 300);

  StreamSubscription<ChatEvent>? _subscription;
  Timer? _watchdog;
  Timer? _flush;
  final StringBuffer _pending = StringBuffer();
  String _streamed = '';

  /// Denkschritte laufen getrennt mit: sie gehören nicht in [_streamed] und
  /// damit nicht in den Prompt des nächsten Zuges.
  String _reasoned = '';
  bool _reasoningDirty = false;
  String? _streamingId;
  int _promptChars = 0;

  /// Wird **synchron** gesetzt, sobald ein Lauf abgeschlossen wird. `_finish`
  /// wartet zuerst auf die Datenbank; ohne dieses Flag läuft in genau dieser
  /// Lücke `_onDone` durch und `_fail` überschreibt das fertige Ergebnis mit
  /// "Verbindung endete ohne Abschluss".
  bool _settled = false;

  TokenEstimator get _estimator => TokenEstimator(_calibrations);

  @override
  void dispose() {
    _subscription?.cancel();
    _watchdog?.cancel();
    _flush?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final messages = await _store.messages(state.chat.id);
    // Zwischen await und Zuweisung kann der Controller ersetzt worden sein.
    if (!mounted) return;
    state = state.copyWith(messages: messages, loading: false);
    _recomputeBudget();
  }

  /// Wird vom Provider aufgerufen, wenn die Kalibrierung aus der Datenbank
  /// eintrifft. Nachreichen statt neu bauen: ein Neuaufbau würde den
  /// laufenden Stream mitreißen.
  void applyCalibrations(Map<String, ModelCalibration> values) {
    if (!mounted) return;
    _calibrations
      ..clear()
      ..addAll(values);
    _recomputeBudget();
  }

  /// Wird vom Provider aufgerufen, wenn die Modellliste neu eintrifft.
  void applyModels(ModelsSnapshot snapshot) {
    if (!mounted) return;
    final ref = state.chat.model;
    if (ref == null) {
      state = state.copyWith(clearEntry: true);
      return;
    }
    final matches = snapshot.models.where((m) => m.ref == ref).toList();
    final match = matches.isEmpty ? null : matches.first;
    state = state.copyWith(entry: match, clearEntry: match == null);
    _recomputeBudget();
  }

  void _recomputeBudget() {
    state = state.copyWith(
      budget: computeBudget(
        messages: state.messages,
        entry: state.entry,
        ref: state.chat.model,
        estimator: _estimator,
        systemPrompt: state.chat.systemPrompt,
      ),
    );
  }

  Future<void> setModel(ModelRef ref) async {
    final chat = state.chat.copyWith(model: ref, updatedAt: DateTime.now());
    await _store.upsertChat(chat);
    state = state.copyWith(chat: chat);
    _recomputeBudget();
  }

  Future<void> setCompression(bool enabled) async {
    final chat =
        state.chat.copyWith(compressionEnabled: enabled, updatedAt: DateTime.now());
    await _store.upsertChat(chat);
    state = state.copyWith(chat: chat);
  }

  Future<void> rename(String title) async {
    final chat = state.chat.copyWith(title: title, updatedAt: DateTime.now());
    await _store.upsertChat(chat);
    state = state.copyWith(chat: chat);
  }

  Future<void> toggleInclude(ChatMessage message) async {
    await _store.setIncludeInContext([message.id], !message.includeInContext);
    await load();
  }

  void clearNotice() => state = state.copyWith(clearNotice: true);

  // --- Senden --------------------------------------------------------------

  Future<void> send(String text, {List<Attachment> attachments = const []}) async {
    final ref = state.chat.model;
    if (ref == null || state.send.phase.isActive) return;

    final messageId = _uuid.v4();
    final userMessage = ChatMessage(
      id: messageId,
      chatId: state.chat.id,
      role: MessageRole.user,
      content: text,
      status: MessageStatus.complete,
      createdAt: DateTime.now(),
      attachments: [
        for (final a in attachments)
          Attachment(
            id: a.id,
            messageId: messageId,
            kind: a.kind,
            filename: a.filename,
            path: a.path,
            bytes: a.bytes,
            extractedText: a.extractedText,
            estimatedTokens: a.estimatedTokens,
          )
      ],
    );

    // Erst persistieren, dann senden. Ein Absturz zwischen beidem kostet die
    // Antwort, aber nie die Frage.
    await _store.insertMessage(userMessage);

    if (state.messages.isEmpty) {
      await rename(_titleFrom(text));
    }

    await _startRun(ref);
  }

  /// Neuer Versuch für die letzte Frage — die abgebrochene Antwort bleibt als
  /// Verlauf stehen, statt überschrieben zu werden.
  Future<void> retryLast() async {
    final ref = state.chat.model;
    if (ref == null || state.send.phase.isActive) return;
    await _startRun(ref);
  }

  Future<void> _startRun(ModelRef ref) async {
    final history = await _store.messages(state.chat.id);
    final payload = await _buildPayload(history, ref);
    _promptChars = payload.fold<int>(
        0, (sum, m) => sum + (m['content'] is String ? (m['content'] as String).length : 0));

    final assistantId = _uuid.v4();
    final assistant = ChatMessage(
      id: assistantId,
      chatId: state.chat.id,
      role: MessageRole.assistant,
      content: '',
      status: MessageStatus.streaming,
      createdAt: DateTime.now(),
      requestId: _uuid.v4(),
    );
    await _store.insertMessage(assistant);

    _streamingId = assistantId;
    _settled = false;
    _streamed = '';
    _reasoned = '';
    _reasoningDirty = false;
    _pending.clear();

    final promptTokens = (_promptChars / _estimator.charsPerToken(ref)).ceil();
    final expected = _estimator.expectedPromptTime(promptTokens, ref);

    state = state.copyWith(
      messages: await _store.messages(state.chat.id),
      send: SendState(
        phase: SendPhase.connecting,
        startedAt: DateTime.now(),
        lastEventAt: DateTime.now(),
        streamingMessageId: assistantId,
        promptTokenEstimate: promptTokens,
        estimateIsMeasured: _estimator.isMeasured(ref),
        expectedPromptSeconds: expected == null
            ? null
            : expected.inMilliseconds / 1000.0,
      ),
    );
    _recomputeBudget();
    _startWatchdog();

    _subscription = _client
        .streamChat(ref: ref, messages: payload)
        .listen(_onEvent, onError: (Object e) => _fail('$e'), onDone: _onDone);
  }

  void _onEvent(ChatEvent event) {
    final now = DateTime.now();
    switch (event) {
      case ChatAccepted():
        state = state.copyWith(
          send: state.send
              .copyWith(phase: SendPhase.accepted, lastEventAt: now),
        );
      case ChatPhaseEvent(state: final wire, :final note):
        _applyPhase(wire, note, now);
      case ChatHeartbeat():
        // Nur Lebenszeichen: Phase bleibt, der Watchdog wird zurückgesetzt.
        state = state.copyWith(
          send: state.send.copyWith(
            lastEventAt: now,
            clearNote: state.send.phase == SendPhase.stalled,
            phase: state.send.phase == SendPhase.stalled
                ? SendPhase.processingPrompt
                : state.send.phase,
          ),
        );
      case ChatReasoning(:final text):
        // Eigener Kanal: sichtbar und persistiert, aber nicht Teil der
        // Antwort. Bei abgeschnittener Generierung ist das der einzige
        // Inhalt, den es überhaupt gibt.
        _reasoned += text;
        _reasoningDirty = true;
        _flush ??= Timer.periodic(_flushInterval, (_) => _flushToStore());
        state = state.copyWith(
          send: state.send.copyWith(
            phase: SendPhase.generating,
            lastEventAt: now,
            clearNote: true,
          ),
        );
        _updateStreamingMessage();
      case ChatDelta(:final text):
        _pending.write(text);
        _streamed += text;
        _flush ??= Timer.periodic(_flushInterval, (_) => _flushToStore());
        state = state.copyWith(
          send: state.send.copyWith(
            phase: SendPhase.generating,
            lastEventAt: now,
            clearNote: true,
          ),
        );
        _updateStreamingMessage();
      case ChatDone(:final metrics):
        _finish(metrics);
      case ChatFailure(:final message):
        _fail(message);
    }
  }

  void _applyPhase(String wire, String? note, DateTime now) {
    final phase = switch (wire) {
      'accepted' => SendPhase.accepted,
      'loading_model' => SendPhase.loadingModel,
      'processing_prompt' => SendPhase.processingPrompt,
      'generating' => SendPhase.generating,
      _ => state.send.phase,
    };
    state = state.copyWith(
      send: state.send.copyWith(phase: phase, note: note, lastEventAt: now),
    );
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final send = state.send;
      if (!send.phase.isActive) return;
      final last = send.lastEventAt;
      if (last == null) return;
      final silent = DateTime.now().difference(last);
      if (silent > _stallAfter && send.phase != SendPhase.stalled) {
        state = state.copyWith(
          send: send.copyWith(
            phase: SendPhase.stalled,
            note: 'Seit ${silent.inSeconds} s kein Lebenszeichen vom Gateway',
          ),
        );
      } else {
        // Tick für die verstrichene Zeit im UI.
        state = state.copyWith(send: send.copyWith());
      }
    });
  }

  void _updateStreamingMessage() {
    final id = _streamingId;
    if (id == null) return;
    state = state.copyWith(
      messages: [
        for (final m in state.messages)
          if (m.id == id)
            m.copyWith(content: _streamed, reasoning: _reasoned)
          else
            m
      ],
    );
  }

  Future<void> _flushToStore() async {
    final id = _streamingId;
    if (id == null || (_pending.isEmpty && !_reasoningDirty)) return;
    _pending.clear();
    final reasoning = _reasoningDirty ? _reasoned : null;
    _reasoningDirty = false;
    await _store.appendStreamingText(id, _streamed, reasoning: reasoning);
  }

  Future<void> _finish(ChatMetrics? metrics) async {
    if (_settled) return;
    _settled = true;
    final id = _streamingId;
    _stopTimers();
    if (id != null) {
      await _store.finishMessage(
        id,
        content: _streamed,
        status: MessageStatus.complete,
        metricsJson: metrics?.encode(),
        reasoning: _reasoned,
      );
    }
    _saveCalibration(metrics);

    if (!mounted) return;
    state = state.copyWith(
      messages: await _store.messages(state.chat.id),
      send: state.send.copyWith(phase: SendPhase.done, endedAt: DateTime.now()),
    );
    _recomputeBudget();
    _streamingId = null;

    await _maybeCompact();
  }

  Future<void> _fail(String message) async {
    if (_settled) return;
    _settled = true;
    final id = _streamingId;
    _stopTimers();
    if (id != null) {
      await _store.finishMessage(
        id,
        content: _streamed,
        // Teiltext bleibt erhalten: abgebrochen ist nicht dasselbe wie leer.
        status: _streamed.isEmpty
            ? MessageStatus.failed
            : MessageStatus.interrupted,
        error: message,
        reasoning: _reasoned,
      );
    }
    if (!mounted) return;
    state = state.copyWith(
      messages: await _store.messages(state.chat.id),
      send: state.send.copyWith(
        phase: SendPhase.failed,
        error: message,
        endedAt: DateTime.now(),
      ),
    );
    _streamingId = null;
  }

  Future<void> cancel() async {
    if (_settled) return;
    _settled = true;
    final id = _streamingId;
    await _subscription?.cancel();
    _subscription = null;
    _stopTimers();
    if (id != null) {
      await _store.finishMessage(
        id,
        content: _streamed,
        status: MessageStatus.cancelled,
        error: 'Vom Nutzer abgebrochen',
        reasoning: _reasoned,
      );
    }
    if (!mounted) return;
    state = state.copyWith(
      messages: await _store.messages(state.chat.id),
      send: state.send.copyWith(
        phase: SendPhase.cancelled,
        endedAt: DateTime.now(),
      ),
    );
    _streamingId = null;
  }

  void _onDone() {
    // Stream endete ohne done-Event: das ist ein Abriss, kein Erfolg.
    // `_settled` unterscheidet das vom regulären Ende, dessen `_finish`
    // gerade noch auf die Datenbank wartet.
    if (!_settled && state.send.phase.isActive) {
      _fail('Verbindung endete ohne Abschluss des Gateways');
    }
  }

  void _stopTimers() {
    _flush?.cancel();
    _flush = null;
    _watchdog?.cancel();
    _watchdog = null;
  }

  void _saveCalibration(ChatMetrics? metrics) {
    final ref = state.chat.model;
    final tokens = metrics?.promptTokens.value;
    if (ref == null || tokens == null || tokens <= 0) return;

    final ttft = metrics?.timeToFirstTokenMs.value;
    final load = metrics?.loadMs.value ?? 0;
    final promptMs = (ttft ?? 0) - load;
    final rate = promptMs > 50 ? tokens / (promptMs / 1000) : null;

    final key = ChatStore.modelKey(ref);
    final folded = TokenEstimator.fold(
      _calibrations[key],
      promptChars: _promptChars,
      promptTokens: tokens,
      promptTokensPerSecond: rate,
    );
    _calibrations[key] = folded;
    unawaited(_store.saveCalibration(key, folded));
    onCalibrationSaved?.call(key, folded);
  }

  Future<void> _maybeCompact() async {
    if (!_compactor.shouldRun(chat: state.chat, budget: state.budget)) return;

    final result = await _compactor.run(
      chat: state.chat,
      messages: state.messages,
      estimator: _estimator,
    );
    if (result == null) return;

    state = state.copyWith(
      messages: await _store.messages(state.chat.id),
      notice: result.ok
          ? '${result.replaced} Nachrichten zusammengefasst, '
              '${result.saved} Tokens gespart'
          : 'Zusammenfassung fehlgeschlagen: ${result.error}',
    );
    _recomputeBudget();
  }

  Future<void> undoSummary(ChatMessage summary) async {
    await _compactor.undo(summary);
    await load();
  }

  // --- Prompt-Aufbau -------------------------------------------------------

  Future<List<Map<String, dynamic>>> _buildPayload(
    List<ChatMessage> history,
    ModelRef ref,
  ) async {
    final payload = <Map<String, dynamic>>[];
    final systemPrompt = state.chat.systemPrompt;
    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      payload.add({'role': 'system', 'content': systemPrompt});
    }

    for (final message in history) {
      if (!message.includeInContext) continue;
      // Auch `interrupted`: ein abgeschnittener Halbsatz als Assistant-Turn
      // im Prompt verwirrt das Modell beim Wiederholen mehr, als er hilft.
      if (message.status == MessageStatus.failed ||
          message.status == MessageStatus.cancelled ||
          message.status == MessageStatus.interrupted) {
        continue;
      }
      if (message.role == MessageRole.assistant && message.content.isEmpty) {
        continue;
      }

      final buffer = StringBuffer(message.content);
      final images = <String>[];

      for (final attachment in message.attachments) {
        switch (attachment.kind) {
          case AttachmentKind.image:
            final bytes = await _readBytes(attachment.path);
            if (bytes != null) images.add(base64Encode(bytes));
          case AttachmentKind.pdf:
          case AttachmentKind.text:
            final text = attachment.extractedText;
            if (text != null && text.isNotEmpty) {
              buffer
                ..writeln()
                ..writeln('--- Inhalt von ${attachment.filename} ---')
                ..writeln(text);
            }
        }
      }

      payload.add({
        'role': message.role.sendAs,
        'content': buffer.toString(),
        if (images.isNotEmpty) 'images': images,
      });
    }
    return payload;
  }

  Future<List<int>?> _readBytes(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static String _titleFrom(String text) {
    final cleaned = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isEmpty) return 'Neuer Chat';
    return cleaned.length <= 42 ? cleaned : '${cleaned.substring(0, 42)}…';
  }
}
