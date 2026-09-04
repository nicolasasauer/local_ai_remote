import 'package:flutter/material.dart';

import '../../models/chat.dart';
import '../../theme.dart';
import '../format.dart';
import 'fact_view.dart';

class MessageView extends StatelessWidget {
  const MessageView({
    required this.message,
    required this.onRetry,
    required this.onToggleInclude,
    required this.onUndoSummary,
    super.key,
  });

  final ChatMessage message;
  final VoidCallback onRetry;
  final VoidCallback onToggleInclude;
  final VoidCallback onUndoSummary;

  @override
  Widget build(BuildContext context) {
    if (message.isSummary) {
      return _SummaryMarker(message: message, onUndo: onUndoSummary);
    }

    final isUser = message.role == MessageRole.user;
    final dimmed = !message.includeInContext;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Opacity(
            opacity: dimmed ? 0.45 : 1,
            child: GestureDetector(
              onLongPress: onToggleInclude,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 720),
                padding: isUser
                    ? const EdgeInsets.symmetric(horizontal: 13, vertical: 10)
                    : EdgeInsets.zero,
                decoration: isUser
                    ? BoxDecoration(
                        color: Tone.raised,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(10),
                          topRight: Radius.circular(10),
                          bottomLeft: Radius.circular(10),
                          bottomRight: Radius.circular(3),
                        ),
                      )
                    : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.attachments.isNotEmpty)
                      _Attachments(message: message),
                    if (message.hasReasoning)
                      _Reasoning(
                        text: message.reasoning!,
                        running: message.isRunning,
                      ),
                    if (message.content.isNotEmpty)
                      SelectableText(
                        message.content,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: Tone.ink,
                        ),
                      ),
                    if (message.isRunning &&
                        message.content.isEmpty &&
                        !message.hasReasoning)
                      const Text(
                        '…',
                        style: TextStyle(fontSize: 14, color: Tone.faint),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (dimmed)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Nicht im Kontext — bleibt im Verlauf, wird aber nicht mitgesendet',
                style: TextStyle(fontSize: 11, color: Tone.faint),
              ),
            ),
          if (message.status == MessageStatus.interrupted)
            _Interrupted(reason: message.error, onRetry: onRetry),
          if (message.status == MessageStatus.failed)
            _Failed(error: message.error, onRetry: onRetry),
          if (message.status == MessageStatus.cancelled)
            const Padding(
              padding: EdgeInsets.only(top: 5),
              child: Text(
                'Abgebrochen',
                style: TextStyle(fontSize: 11.5, color: Tone.muted),
              ),
            ),
          if (message.metrics != null && !message.isRunning)
            _MetricsRow(metrics: message.metrics!),
        ],
      ),
    );
  }
}

class _MetricsRow extends StatelessWidget {
  const _MetricsRow({required this.metrics});

  final ChatMetrics metrics;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 11, color: Tone.faint);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        children: [
          _Metric(
            label: 'Tempo',
            child: FactText<double>(
              metrics.tokensPerSecond,
              format: (v) => '${v.toStringAsFixed(1)} tok/s',
              mono: true,
              style: style,
            ),
          ),
          _Metric(
            label: 'Erster Token',
            child: FactText<double>(
              metrics.timeToFirstTokenMs,
              format: formatMillis,
              mono: true,
              style: style,
            ),
          ),
          _Metric(
            label: 'Prompt',
            child: FactText<int>(
              metrics.promptTokens,
              format: (v) => '${formatCount(v)} tok',
              mono: true,
              style: style,
            ),
          ),
          if (metrics.loadMs.isKnown && metrics.loadMs.value! > 50)
            _Metric(
              label: 'Modell geladen',
              child: FactText<double>(
                metrics.loadMs,
                format: formatMillis,
                mono: true,
                style: style,
              ),
            ),
          if (metrics.stopReason.isKnown &&
              metrics.stopReason.value != 'stop')
            _Metric(
              label: 'Ende',
              child: Text(metrics.stopReason.value!, style: style),
            ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: const TextStyle(fontSize: 11, color: Tone.faint)),
        DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 11, color: Tone.muted),
          child: child,
        ),
      ],
    );
  }
}

/// Halbe Antwort nach einem Absturz. Der Text bleibt stehen, damit nichts
/// stillschweigend verschwindet.
class _Interrupted extends StatelessWidget {
  const _Interrupted({required this.onRetry, this.reason});

  final VoidCallback onRetry;

  /// Der beim Abbruch festgehaltene Grund. Ein Abriss mitten in der Sitzung
  /// ist etwas anderes als ein Absturz der App — den Unterschied kennt nur
  /// diese Zeile, also wird sie angezeigt statt eines pauschalen Satzes.
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final text = (reason == null || reason!.trim().isEmpty)
        ? 'Unterbrochen'
        : reason!;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.link_off, size: 13, color: Tone.amber),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(fontSize: 11.5, color: Tone.amber),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('Neu generieren', style: TextStyle(fontSize: 11.5)),
          ),
        ],
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.error, required this.onRetry});

  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: Tone.alert.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Tone.alert.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 14, color: Tone.alert),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              error ?? 'Unbekannter Fehler',
              style: const TextStyle(fontSize: 11.5, color: Tone.ink, height: 1.4),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(minimumSize: const Size(0, 30)),
            child: const Text('Erneut', style: TextStyle(fontSize: 11.5)),
          ),
        ],
      ),
    );
  }
}

/// Marke für verdichteten Verlauf. Die Originale liegen weiter in der
/// Datenbank, deshalb ist das jederzeit umkehrbar.
class _SummaryMarker extends StatelessWidget {
  const _SummaryMarker({required this.message, required this.onUndo});

  final ChatMessage message;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Tone.violet.withValues(alpha: 0.4)),
          color: Tone.violet.withValues(alpha: 0.06),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.compress, size: 14, color: Tone.violet),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${message.summaryOf.length} Nachrichten zusammengefasst',
                    style: const TextStyle(fontSize: 12.5, color: Tone.ink),
                  ),
                ),
                TextButton(
                  onPressed: onUndo,
                  style: TextButton.styleFrom(minimumSize: const Size(0, 30)),
                  child: const Text('Zurücknehmen',
                      style: TextStyle(fontSize: 11.5)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              message.content,
              style: const TextStyle(fontSize: 12.5, color: Tone.muted, height: 1.45),
            ),
            const SizedBox(height: 6),
            const Text(
              'Die Originale bleiben gespeichert und werden nur nicht mitgesendet.',
              style: TextStyle(fontSize: 11, color: Tone.faint),
            ),
          ],
        ),
      ),
    );
  }
}

class _Attachments extends StatelessWidget {
  const _Attachments({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final a in message.attachments)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: Tone.base,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Tone.hairline),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    switch (a.kind) {
                      AttachmentKind.image => Icons.image_outlined,
                      AttachmentKind.pdf => Icons.picture_as_pdf_outlined,
                      AttachmentKind.text => Icons.description_outlined,
                    },
                    size: 13,
                    color: Tone.muted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    a.filename,
                    style: const TextStyle(fontSize: 11.5, color: Tone.ink),
                  ),
                  if (a.estimatedTokens != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '~${formatCount(a.estimatedTokens!)} tok',
                      style: kMono.copyWith(fontSize: 10.5, color: Tone.faint),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}


/// Denkschritte eines Reasoning-Modells.
///
/// Standardmäßig eingeklappt — sie sind oft länger als die Antwort. Während
/// der Generierung aber offen, weil sie dann der einzige Beleg sind, dass
/// etwas passiert: bei diesen Modellen bleibt der Antworttext lange leer.
class _Reasoning extends StatefulWidget {
  const _Reasoning({required this.text, required this.running});

  final String text;
  final bool running;

  @override
  State<_Reasoning> createState() => _ReasoningState();
}

class _ReasoningState extends State<_Reasoning> {
  bool? _open;

  bool get _expanded => _open ?? widget.running;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 15,
                    color: Tone.faint,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    widget.running ? 'Denkt …' : 'Denkschritte',
                    style: const TextStyle(fontSize: 11.5, color: Tone.faint),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: Tone.hairline, width: 2)),
              ),
              child: SelectableText(
                widget.text,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: Tone.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
