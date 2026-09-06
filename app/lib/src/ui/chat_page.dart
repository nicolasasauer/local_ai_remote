import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_controller.dart';
import '../data/attachment_picker.dart';
import '../models/chat.dart';
import '../models/model_entry.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'format.dart';
import 'models_page.dart';
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
  final _scroll = ScrollController();
  final _picker = const AttachmentPicker();
  final _pending = <Attachment>[];

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
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

    ref.listen(
      chatControllerProvider(widget.chat).select((s) => s.notice),
      (_, notice) {
        if (notice == null) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(notice)));
        _controller.clearNotice();
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());

    return Scaffold(
      appBar: AppBar(
        leading: widget.onOpenList == null
            ? null
            : IconButton(
                icon: const Icon(Icons.chat_bubble_outline),
                onPressed: widget.onOpenList,
              ),
        title: _Title(session: session),
        actions: [
          IconButton(
            tooltip: 'Modell wählen',
            icon: const Icon(Icons.memory),
            onPressed: () async {
              final ref0 = await showModelPicker(
                context,
                ref,
                current: session.chat.model,
              );
              if (ref0 != null) await _switchModel(session, ref0);
            },
          ),
          PopupMenuButton<String>(
            onSelected: (value) => _menu(value, session),
            itemBuilder: (context) => [
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
              const PopupMenuItem(value: 'rename', child: Text('Umbenennen')),
              const PopupMenuItem(value: 'delete', child: Text('Chat löschen')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const _MiniTelemetry(),
          Expanded(
            child: session.messages.isEmpty && !session.loading
                ? const _EmptyChat()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(top: 8, bottom: 12),
                    itemCount: session.messages.length,
                    itemBuilder: (context, i) {
                      final message = session.messages[i];
                      return MessageView(
                        message: message,
                        expectedModel: session.chat.model?.id,
                        onRetry: _controller.retryLast,
                        onToggleInclude: () =>
                            _controller.toggleInclude(message),
                        onUndoSummary: () => _controller.undoSummary(message),
                      );
                    },
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
            pending: _pending,
            canSend: session.canSend,
            visionFact: session.entry?.vision,
            onPickImages: () async => _addAttachments(await _picker.pickImages()),
            onPickDocuments: () async =>
                _addAttachments(await _picker.pickDocuments()),
            onRemove: (a) => setState(() => _pending.remove(a)),
            onSend: _send,
            onStop: _controller.cancel,
            busy: session.send.phase.isActive,
          ),
        ],
      ),
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Tone.amber.withValues(alpha: 0.9),
          content: Text(
            'Aus ${empty.map((a) => a.filename).join(', ')} konnte kein Text '
            'gelesen werden — vermutlich ein Scan ohne Textebene.',
          ),
        ),
      );
    }
  }

  Future<void> _switchModel(ChatSession session, ModelRef next) async {
    final entries = ref.read(modelsProvider).valueOrNull?.models ?? const [];
    final target = entries.where((m) => m.ref == next).firstOrNull;
    final limit = target?.effectiveContext.value;

    if (limit != null && session.budget.usedTokens > limit) {
      final proceed = await _confirm(
        'Kleineres Kontextfenster',
        'Der Verlauf umfasst ${formatCount(session.budget.usedTokens)} Tokens, '
            'das gewählte Modell fasst ${formatCount(limit)}. Ältere '
            'Nachrichten würden abgeschnitten.',
      );
      if (proceed != true) return;
    }

    final hasImages = session.messages
        .any((m) => m.attachments.any((a) => a.kind == AttachmentKind.image));
    if (hasImages && target?.vision.value == false) {
      final proceed = await _confirm(
        'Modell ohne Bildverständnis',
        'Im Verlauf sind Bilder. Dieses Modell kann sie nicht sehen und '
            'antwortet trotzdem — nur eben ohne sie.',
      );
      if (proceed != true) return;
    }

    await _controller.setModel(next);
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Tone.raised,
          title: Text(title, style: const TextStyle(fontSize: 16)),
          content: Text(body, style: const TextStyle(fontSize: 13.5, height: 1.45)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Trotzdem wechseln'),
            ),
          ],
        ),
      );

  Future<void> _menu(String value, ChatSession session) async {
    switch (value) {
      case 'research':
        await _controller.setResearch(!session.chat.researchEnabled);
      case 'compress':
        await _controller.setCompression(!session.chat.compressionEnabled);
      case 'rename':
        final name = await _askName(session.chat.title);
        if (name != null && name.trim().isNotEmpty) {
          await _controller.rename(name.trim());
          await ref.read(chatListProvider.notifier).refresh();
        }
      case 'delete':
        await ref.read(chatListProvider.notifier).delete(session.chat.id);
        ref.read(activeChatIdProvider.notifier).state = null;
    }
  }

  Future<String?> _askName(String current) {
    final field = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Tone.raised,
        title: const Text('Chat umbenennen', style: TextStyle(fontSize: 16)),
        content: TextField(controller: field, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    final attachments = List<Attachment>.from(_pending);
    _input.clear();
    setState(_pending.clear);
    await _controller.send(text, attachments: attachments);
    _scrollToEnd();
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }
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
              Text(
                model == null
                    ? 'Kein Modell gewählt'
                    // Der Chat kennt sein Modell, die Gateway-Liste nicht:
                    // Backend aus oder Modell gelöscht.
                    : '${model.id} · derzeit nicht angeboten',
                style: const TextStyle(fontSize: 11.5, color: Tone.amber),
                overflow: TextOverflow.ellipsis,
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

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.pending,
    required this.canSend,
    required this.visionFact,
    required this.onPickImages,
    required this.onPickDocuments,
    required this.onRemove,
    required this.onSend,
    required this.onStop,
    required this.busy,
  });

  final TextEditingController controller;
  final List<Attachment> pending;
  final bool canSend;
  final dynamic visionFact;
  final Future<void> Function() onPickImages;
  final Future<void> Function() onPickDocuments;
  final void Function(Attachment) onRemove;
  final Future<void> Function() onSend;
  final VoidCallback onStop;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final visionKnownFalse = visionFact?.value == false;

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Tone.hairline)),
        color: Tone.surface,
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            if (pending.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in pending)
                      InputChip(
                        label: Text(
                          a.estimatedTokens == null
                              ? a.filename
                              : '${a.filename} · ~${formatCount(a.estimatedTokens!)} tok',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        onDeleted: () => onRemove(a),
                        backgroundColor: Tone.raised,
                      ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: visionKnownFalse
                      ? 'Dieses Modell kann keine Bilder verarbeiten'
                      : 'Bild anhängen',
                  onPressed: visionKnownFalse ? null : onPickImages,
                  icon: const Icon(Icons.image_outlined),
                ),
                IconButton(
                  tooltip: 'PDF oder Textdatei anhängen',
                  onPressed: onPickDocuments,
                  icon: const Icon(Icons.attach_file),
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 6,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(
                      hintText: 'Nachricht',
                      hintStyle: TextStyle(color: Tone.faint),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                busy
                    ? IconButton.filled(
                        onPressed: onStop,
                        icon: const Icon(Icons.stop),
                      )
                    : IconButton.filled(
                        onPressed: canSend ? onSend : null,
                        icon: const Icon(Icons.arrow_upward),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(30),
        child: Text(
          'Frag etwas. Der Verlauf liegt lokal auf diesem Gerät, das Modell '
          'rechnet auf deinem Desktop.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Tone.faint, height: 1.5),
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
