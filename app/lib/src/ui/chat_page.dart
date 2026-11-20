import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_controller.dart';
import '../data/attachment_picker.dart';
import '../models/chat.dart';
import '../models/fact.dart';
import '../models/model_entry.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'chat_list_panel.dart';
import 'dialogs.dart';
import 'format.dart';
import 'models_page.dart';
import 'widgets/gateway_banner.dart';
import 'widgets/context_bar.dart';
import 'widgets/instruments.dart';
import 'widgets/message_view.dart';
import 'widgets/phase_bar.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({required this.chat, this.onOpenList, super.key});

  final Chat chat;
  final VoidCallback? onOpenList;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  final _picker = const AttachmentPicker();
  final _pending = <Attachment>[];

  /// Ob der Verlauf am Ende klebt. Wer nach oben scrollt, um etwas
  /// nachzulesen, soll vom Stream nicht ständig nach unten gerissen werden.
  bool _stick = true;
  bool _showJump = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // Sendeknopf und Rahmen des Eingabefelds hängen an Text und Fokus.
    _input.addListener(() => setState(() {}));
    _inputFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atEnd = pos.maxScrollExtent - pos.pixels < 80;
    // Nur eine Bewegung des Nutzers löst das Kleben; das Nachwachsen des
    // Inhalts verschiebt maxScrollExtent und darf das nicht.
    if (pos.userScrollDirection != ScrollDirection.idle) _stick = atEnd;
    final show = !atEnd;
    if (show != _showJump) setState(() => _showJump = show);
  }

  ChatController get _controller =>
      ref.read(chatControllerProvider(widget.chat).notifier);

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(chatControllerProvider(widget.chat));

    // Nach dem Umbenennen (Titel aus der ersten Frage) muss die Liste links
    // nachziehen.
    ref.listen(
      chatControllerProvider(widget.chat).select((s) => s.chat.title),
      (_, __) => ref.read(chatListProvider.notifier).refresh(),
    );

    ref.listen(chatControllerProvider(widget.chat).select((s) => s.notice), (
      _,
      notice,
    ) {
      if (notice == null) return;
      showNotice(context, notice);
      _controller.clearNotice();
    });

    if (_stick) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
    }

    final empty = session.messages.isEmpty && !session.loading;

    return Scaffold(
      appBar: AppBar(
        leading:
            widget.onOpenList == null
                ? null
                : IconButton(
                  tooltip: 'Chats',
                  icon: const Icon(Icons.menu),
                  onPressed: widget.onOpenList,
                ),
        title: _Title(session: session),
        actions: [
          IconButton(
            tooltip: 'Neuer Chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: () => startNewChat(ref),
          ),
          IconButton(
            tooltip: 'Modell wählen',
            icon: const Icon(Icons.memory),
            onPressed: () => _pickModel(session),
          ),
          PopupMenuButton<String>(
            tooltip: 'Mehr',
            color: Tone.raised,
            onSelected: (value) => _menu(value, session),
            itemBuilder:
                (context) => [
                  CheckedPopupMenuItem(
                    value: 'research',
                    checked: session.chat.researchEnabled,
                    child: const Text('Im Web nachsehen dürfen'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'compress',
                    checked: session.chat.compressionEnabled,
                    child: const Text('Kontext verdichten'),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'system',
                    child: Text(
                      (session.chat.systemPrompt?.trim().isNotEmpty ?? false)
                          ? 'Systemprompt bearbeiten'
                          : 'Systemprompt festlegen',
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'rename',
                    child: Text('Umbenennen'),
                  ),
                  PopupMenuItem(
                    value: 'export',
                    enabled: session.messages.isNotEmpty,
                    child: const Text('Als Markdown kopieren'),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Chat löschen',
                      style: TextStyle(color: Tone.alert),
                    ),
                  ),
                ],
          ),
        ],
      ),
      body: Column(
        children: [
          const GatewayBanner(),
          const _MiniTelemetry(),
          if (session.chat.systemPrompt?.trim().isNotEmpty ?? false)
            _SystemPromptStrip(
              text: session.chat.systemPrompt!,
              onTap: () => _editSystemPrompt(session),
            ),
          Expanded(
            child:
                empty
                    ? _EmptyChat(
                      hasModel: session.chat.model != null,
                      onPickModel: () => _pickModel(session),
                      onSuggestion: (text) {
                        _input.text = text;
                        _inputFocus.requestFocus();
                      },
                    )
                    : Stack(
                      children: [
                        ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.only(top: 8, bottom: 12),
                          itemCount: session.messages.length,
                          itemBuilder: (context, i) {
                            final message = session.messages[i];
                            // Volle Breite bis 860 px, dann mittig: sonst
                            // landen eigene Nachrichten in der Mitte statt
                            // rechts.
                            return Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 860,
                                ),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: MessageView(
                                    message: message,
                                    expectedModel: session.chat.model?.id,
                                    onRetry: _controller.retryLast,
                                    onToggleInclude:
                                        () =>
                                            _controller.toggleInclude(message),
                                    onUndoSummary:
                                        () => _controller.undoSummary(message),
                                    onCopied:
                                        () => showNotice(
                                          context,
                                          'In die Zwischenablage kopiert',
                                        ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        if (_showJump)
                          Positioned(
                            right: 14,
                            bottom: 10,
                            child: FloatingActionButton.small(
                              tooltip: 'Zum Ende',
                              backgroundColor: Tone.raised,
                              foregroundColor: Tone.ink,
                              elevation: 2,
                              onPressed: () {
                                _stick = true;
                                _animateToEnd();
                              },
                              child: const Icon(Icons.arrow_downward, size: 18),
                            ),
                          ),
                      ],
                    ),
          ),
          if (session.wartetAufFreigabe)
            _Freigabe(
              calls: session.pendingCalls,
              onApprove: _controller.approveResearch,
              onReject: _controller.rejectResearch,
            ),
          PhaseBar(
            send: session.send,
            onCancel: _controller.cancel,
            onRetry: _controller.retryLast,
          ),
          ContextBar(budget: session.budget),
          _Composer(
            controller: _input,
            focusNode: _inputFocus,
            pending: _pending,
            canSend:
                session.canSend &&
                !session.wartetAufFreigabe &&
                (_input.text.trim().isNotEmpty || _pending.isNotEmpty),
            hasModel: session.chat.model != null,
            visionFact: session.entry?.vision,
            onPickImages:
                () async => _addAttachments(await _picker.pickImages()),
            onPickDocuments:
                () async => _addAttachments(await _picker.pickDocuments()),
            onRemove: (a) => setState(() => _pending.remove(a)),
            onSend: _send,
            onStop: _controller.cancel,
            busy: session.send.phase.isActive,
          ),
        ],
      ),
    );
  }

  Future<void> _pickModel(ChatSession session) async {
    final next = await showModelPicker(
      context,
      ref,
      current: session.chat.model,
    );
    if (next != null) await _switchModel(session, next);
  }

  void _addAttachments(List<Attachment> added) {
    if (added.isEmpty) return;
    setState(() => _pending.addAll(added));

    // PDFs ohne Textebene sind der Klassiker; das muss vor dem Senden gesagt
    // werden, nicht danach.
    final empty = added.where(
      (a) => a.kind != AttachmentKind.image && a.extractedText == null,
    );
    if (empty.isNotEmpty && mounted) {
      showNotice(
        context,
        'Aus ${empty.map((a) => a.filename).join(', ')} konnte kein Text '
        'gelesen werden — vermutlich ein Scan ohne Textebene.',
        warn: true,
      );
    }
  }

  Future<void> _switchModel(ChatSession session, ModelRef next) async {
    final entries = ref.read(modelsProvider).valueOrNull?.models ?? const [];
    final target = entries.where((m) => m.ref == next).firstOrNull;
    final limit = target?.effectiveContext.value;

    if (limit != null && session.budget.usedTokens > limit) {
      final proceed = await confirm(
        context,
        title: 'Kleineres Kontextfenster',
        body:
            'Der Verlauf umfasst ${formatCount(session.budget.usedTokens)} '
            'Tokens, das gewählte Modell fasst ${formatCount(limit)}. Ältere '
            'Nachrichten würden abgeschnitten.',
        action: 'Trotzdem wechseln',
      );
      if (!proceed) return;
    }

    final hasImages = session.messages.any(
      (m) => m.attachments.any((a) => a.kind == AttachmentKind.image),
    );
    if (hasImages && target?.vision.value == false && mounted) {
      final proceed = await confirm(
        context,
        title: 'Modell ohne Bildverständnis',
        body:
            'Im Verlauf sind Bilder. Dieses Modell kann sie nicht sehen und '
            'antwortet trotzdem — nur eben ohne sie.',
        action: 'Trotzdem wechseln',
      );
      if (!proceed) return;
    }

    await _controller.setModel(next);
  }

  Future<void> _editSystemPrompt(ChatSession session) async {
    final text = await askText(
      context,
      title: 'Systemprompt',
      initial: session.chat.systemPrompt ?? '',
      hint: 'z. B. „Antworte knapp und auf Deutsch."',
      help:
          'Gilt nur für diesen Chat und geht jeder Anfrage voraus. Leer '
          'lassen, um ihn zu entfernen.',
      multiline: true,
    );
    if (text == null) return;
    await _controller.setSystemPrompt(text.trim());
  }

  Future<void> _menu(String value, ChatSession session) async {
    switch (value) {
      case 'research':
        await _controller.setResearch(!session.chat.researchEnabled);
      case 'compress':
        await _controller.setCompression(!session.chat.compressionEnabled);
      case 'system':
        await _editSystemPrompt(session);
      case 'rename':
        final name = await askText(
          context,
          title: 'Chat umbenennen',
          initial: session.chat.title,
        );
        if (name != null && name.trim().isNotEmpty) {
          await _controller.rename(name.trim());
          await ref.read(chatListProvider.notifier).refresh();
        }
      case 'export':
        await Clipboard.setData(
          ClipboardData(text: exportMarkdown(session.chat, session.messages)),
        );
        if (mounted) showNotice(context, 'Chat als Markdown kopiert');
      case 'delete':
        await deleteChatWithConfirm(context, ref, session.chat);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    final attachments = List<Attachment>.from(_pending);
    _input.clear();
    setState(_pending.clear);
    _stick = true;
    await _controller.send(text, attachments: attachments);
    _jumpToEnd();
  }

  void _jumpToEnd() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (_scroll.position.pixels != max) _scroll.jumpTo(max);
  }

  void _animateToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }
}

/// Ein Chat als Markdown — zum Weitergeben oder Ablegen. Denkschritte und
/// Werkzeugergebnisse bleiben draußen: sie sind Arbeitsmaterial, nicht das
/// Gespräch.
String exportMarkdown(Chat chat, List<ChatMessage> messages) {
  final b = StringBuffer('# ${chat.title}\n\n');
  if (chat.model != null) b.writeln('_Modell: ${chat.model!.id}_\n');
  if (chat.systemPrompt?.trim().isNotEmpty ?? false) {
    b.writeln('> **System:** ${chat.systemPrompt!.trim()}\n');
  }
  for (final m in messages) {
    if (m.role == MessageRole.tool) continue;
    final who = switch (m.role) {
      MessageRole.user => 'Du',
      MessageRole.summary => 'Zusammenfassung',
      MessageRole.system => 'System',
      _ => 'Modell',
    };
    if (m.content.trim().isEmpty && m.attachments.isEmpty) continue;
    b.writeln('**$who:**\n');
    for (final a in m.attachments) {
      b.writeln('📎 ${a.filename}');
    }
    if (m.attachments.isNotEmpty) b.writeln();
    b.writeln('${m.content.trim()}\n');
  }
  return b.toString().trimRight();
}

class _Title extends StatelessWidget {
  const _Title({required this.session});

  final ChatSession session;

  @override
  Widget build(BuildContext context) {
    final entry = session.entry;
    final model = session.chat.model;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          session.chat.title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            if (entry != null) ...[
              StateDot(state: entry.state, size: 7),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${entry.label} · ${entry.state.label}',
                  style: const TextStyle(fontSize: 11.5, color: Tone.muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ] else
              Flexible(
                child: Text(
                  model == null
                      ? 'Kein Modell gewählt'
                      // Der Chat kennt sein Modell, die Gateway-Liste nicht:
                      // Backend aus oder Modell gelöscht.
                      : '${model.id} · derzeit nicht angeboten',
                  style: const TextStyle(fontSize: 11.5, color: Tone.amber),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Telemetrie im Kleinformat über dem Verlauf: reicht, um zu sehen, ob der
/// Rechner arbeitet, ohne die Seite zu wechseln.
class _MiniTelemetry extends ConsumerWidget {
  const _MiniTelemetry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(telemetryProvider);
    final latest = feed.latest;
    if (latest == null) return const SizedBox.shrink();
    final gpu = latest.primaryGpu;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Instrument(
              label: 'CPU',
              compact: true,
              color: Tone.teal,
              stale: feed.isStale,
              series: feed.seriesCpu(),
              value: InstrumentValue(
                latest.cpuPercent,
                format: (v) => v.toStringAsFixed(0),
                unit: '%',
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Instrument(
              label: 'RAM',
              compact: true,
              color: Tone.violet,
              stale: feed.isStale,
              series: feed.seriesRam(),
              value: Text(
                latest.ramFraction == null
                    ? '—'
                    : '${(latest.ramFraction! * 100).toStringAsFixed(0)} %',
              ),
            ),
          ),
          if (gpu != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Instrument(
                label: 'GPU',
                compact: true,
                color: Tone.amber,
                stale: feed.isStale,
                series: feed.seriesGpu(),
                value: InstrumentValue(
                  gpu.utilPercent,
                  format: (v) => v.toStringAsFixed(0),
                  unit: '%',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SystemPromptStrip extends StatelessWidget {
  const _SystemPromptStrip({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Tone.hairline)),
        ),
        child: Row(
          children: [
            const Icon(Icons.tune, size: 13, color: Tone.violet),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                text.trim().replaceAll(RegExp(r'\s+'), ' '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Tone.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Enter sendet am Desktop, Umschalt+Enter macht eine neue Zeile. Auf dem
/// Telefon bleibt Enter ein Zeilenumbruch — dort gibt es den Sendeknopf
/// direkt daneben, und ein versehentlich halb abgeschickter Gedanke ist
/// ärgerlicher als ein Tipp mehr.
bool get _enterSends => switch (defaultTargetPlatform) {
  TargetPlatform.windows ||
  TargetPlatform.linux ||
  TargetPlatform.macOS => true,
  _ => false,
};

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.pending,
    required this.canSend,
    required this.hasModel,
    required this.visionFact,
    required this.onPickImages,
    required this.onPickDocuments,
    required this.onRemove,
    required this.onSend,
    required this.onStop,
    required this.busy,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<Attachment> pending;
  final bool canSend;
  final bool hasModel;
  final Fact<bool>? visionFact;
  final Future<void> Function() onPickImages;
  final Future<void> Function() onPickDocuments;
  final void Function(Attachment) onRemove;
  final Future<void> Function() onSend;
  final VoidCallback onStop;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final visionKnownFalse = visionFact?.value == false;

    Widget field = TextField(
      controller: controller,
      focusNode: focusNode,
      minLines: 1,
      maxLines: 8,
      textInputAction: TextInputAction.newline,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        hintText:
            hasModel
                ? (_enterSends
                    ? 'Nachricht  ·  Umschalt+Enter für neue Zeile'
                    : 'Nachricht')
                : 'Zuerst oben ein Modell wählen',
        hintStyle: const TextStyle(color: Tone.faint),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      ),
    );

    if (_enterSends) {
      field = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter): () {
            if (canSend && !busy) onSend();
          },
          const SingleActivator(LogicalKeyboardKey.numpadEnter): () {
            if (canSend && !busy) onSend();
          },
        },
        child: field,
      );
    }

    return Container(
      color: Tone.base,
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Container(
              decoration: BoxDecoration(
                color: Tone.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color:
                      focusNode.hasFocus
                          ? Tone.teal.withValues(alpha: 0.6)
                          : Tone.hairline,
                ),
              ),
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (pending.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final a in pending)
                            InputChip(
                              avatar: Icon(switch (a.kind) {
                                AttachmentKind.image => Icons.image_outlined,
                                AttachmentKind.pdf =>
                                  Icons.picture_as_pdf_outlined,
                                AttachmentKind.text =>
                                  Icons.description_outlined,
                              }, size: 15),
                              label: Text(
                                a.estimatedTokens == null
                                    ? a.filename
                                    : '${a.filename} · ~${formatCount(a.estimatedTokens!)} tok',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              onDeleted: () => onRemove(a),
                              backgroundColor: Tone.raised,
                              side: const BorderSide(color: Tone.hairline),
                            ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: field,
                  ),
                  Row(
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip:
                            visionKnownFalse
                                ? 'Dieses Modell kann keine Bilder verarbeiten'
                                : 'Bild anhängen',
                        onPressed: visionKnownFalse ? null : onPickImages,
                        icon: const Icon(Icons.image_outlined, size: 20),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'PDF oder Textdatei anhängen',
                        onPressed: onPickDocuments,
                        icon: const Icon(Icons.attach_file, size: 20),
                      ),
                      const Spacer(),
                      busy
                          ? IconButton.filled(
                            tooltip: 'Abbrechen',
                            style: IconButton.styleFrom(
                              backgroundColor: Tone.alert,
                              foregroundColor: Tone.ink,
                            ),
                            onPressed: onStop,
                            icon: const Icon(Icons.stop, size: 20),
                          )
                          : IconButton.filled(
                            tooltip: 'Senden',
                            onPressed: canSend ? onSend : null,
                            icon: const Icon(Icons.arrow_upward, size: 20),
                          ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({
    required this.hasModel,
    required this.onPickModel,
    required this.onSuggestion,
  });

  final bool hasModel;
  final VoidCallback onPickModel;
  final void Function(String) onSuggestion;

  static const _suggestions = [
    'Erkläre mir knapp, was ein KV-Cache ist.',
    'Schreib ein Python-Skript, das Dateien nach Datum sortiert.',
    'Fasse den angehängten Text in fünf Punkten zusammen.',
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum_outlined, size: 34, color: Tone.faint),
              const SizedBox(height: 12),
              const Text(
                'Der Verlauf liegt lokal auf diesem Gerät, das Modell rechnet '
                'auf deinem Desktop.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Tone.muted, height: 1.5),
              ),
              const SizedBox(height: 20),
              if (!hasModel)
                FilledButton.icon(
                  onPressed: onPickModel,
                  icon: const Icon(Icons.memory, size: 18),
                  label: const Text('Modell wählen'),
                )
              else
                for (final text in _suggestions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Tone.ink,
                        side: const BorderSide(color: Tone.hairline),
                        minimumSize: const Size.fromHeight(42),
                        alignment: Alignment.centerLeft,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () => onSuggestion(text),
                      child: Text(
                        text,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Freigabe für Recherche-Aufrufe.
///
/// Bis hier etwas angetippt wird, passiert nichts: das Gateway führt erst auf
/// ausdrückliche Anforderung aus. Deshalb steht hier auch, *was* genau
/// vorgeschlagen wurde — eine Zusage ohne Gegenstand wäre keine.
class _Freigabe extends StatelessWidget {
  const _Freigabe({
    required this.calls,
    required this.onApprove,
    required this.onReject,
  });

  final List<ToolCall> calls;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Tone.amber.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(10),
        color: Tone.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.travel_explore, size: 15, color: Tone.amber),
              const SizedBox(width: 6),
              Text(
                calls.length == 1
                    ? 'Das Modell möchte nachsehen'
                    : 'Das Modell möchte ${calls.length}-mal nachsehen',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Tone.amber,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final call in calls)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                call.beschreibung,
                style: const TextStyle(fontSize: 13, color: Tone.ink),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              FilledButton(
                onPressed: onApprove,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: const Text('Freigeben'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onReject,
                style: TextButton.styleFrom(minimumSize: const Size(0, 34)),
                child: const Text('Ablehnen'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
