import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/chat.dart';
import '../../theme.dart';
import '../format.dart';

/// Macht sichtbar, wo ein Sendevorgang gerade steht. Jede Stufe hat ein
/// echtes Signal als Auslöser — kein erfundener Fortschrittsbalken.
class PhaseBar extends StatefulWidget {
  const PhaseBar({
    required this.send,
    required this.onCancel,
    required this.onRetry,
    super.key,
  });

  final SendState send;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  State<PhaseBar> createState() => _PhaseBarState();
}

class _PhaseBarState extends State<PhaseBar> {
  Timer? _ticker;

  static const _stages = [
    SendPhase.connecting,
    SendPhase.accepted,
    SendPhase.loadingModel,
    SendPhase.processingPrompt,
    SendPhase.generating,
  ];

  @override
  void initState() {
    super.initState();
    // Die verstrichene Zeit muss laufen, auch wenn keine Events kommen —
    // gerade dann ist sie die einzige Information, die man hat.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.send.phase.isActive) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final send = widget.send;
    if (send.phase == SendPhase.idle || send.phase == SendPhase.done) {
      return const SizedBox.shrink();
    }

    final failed = send.phase == SendPhase.failed;
    final stalled = send.phase == SendPhase.stalled;
    final accent = failed
        ? Tone.alert
        : stalled
            ? Tone.amber
            : Tone.teal;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: Tone.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusDot(color: accent, pulsing: send.phase.isActive && !stalled),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  send.phase.label,
                  style: TextStyle(
                    fontSize: 13,
                    color: failed ? Tone.alert : Tone.ink,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (send.startedAt != null)
                Text(
                  formatDuration(send.elapsed),
                  style: kMono.copyWith(fontSize: 12, color: Tone.muted),
                ),
              if (send.phase.isActive)
                IconButton(
                  tooltip: 'Abbrechen',
                  icon: const Icon(Icons.stop_circle_outlined, size: 19),
                  onPressed: widget.onCancel,
                ),
              if (failed)
                TextButton(
                  onPressed: widget.onRetry,
                  child: const Text('Erneut'),
                ),
            ],
          ),
          if (send.phase.isActive) ...[
            const SizedBox(height: 8),
            _Stages(current: send.phase, accent: accent),
          ],
          if (_subtitle(send) != null) ...[
            const SizedBox(height: 7),
            Text(
              _subtitle(send)!,
              style: TextStyle(
                fontSize: 11.5,
                color: failed ? Tone.alert : Tone.muted,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String? _subtitle(SendState send) {
    if (send.error != null) return send.error;
    if (send.phase == SendPhase.stalled) {
      final since = send.lastEventAt == null
          ? null
          : DateTime.now().difference(send.lastEventAt!);
      return 'Seit ${since == null ? 'einer Weile' : formatDuration(since)} kein '
          'Lebenszeichen vom Gateway. Die Anfrage läuft möglicherweise weiter.';
    }
    if (send.note != null) return send.note;
    if (send.phase == SendPhase.processingPrompt) {
      final tokens = send.promptTokenEstimate;
      if (tokens == null) return null;
      final prefix = send.estimateIsMeasured ? '' : '~';
      final expected = send.expectedPromptSeconds;
      final tail = expected == null
          ? 'Dauer noch nicht abschätzbar — für dieses Modell wurde noch nicht gemessen.'
          : 'erfahrungsgemäß etwa ${expected.toStringAsFixed(0)} s';
      return 'Prompt $prefix${formatCount(tokens)} Tokens, $tail';
    }
    return null;
  }
}

class _Stages extends StatelessWidget {
  const _Stages({required this.current, required this.accent});

  final SendPhase current;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final index = _PhaseBarState._stages.indexOf(current);
    return Row(
      children: [
        for (var i = 0; i < _PhaseBarState._stages.length; i++) ...[
          Expanded(
            child: Container(
              height: 3,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: index < 0 || i > index
                    ? Tone.hairline
                    : accent.withValues(alpha: i == index ? 1 : 0.45),
              ),
            ),
          ),
          if (i < _PhaseBarState._stages.length - 1) const SizedBox(width: 3),
        ],
      ],
    );
  }
}

class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.color, required this.pulsing});

  final Color color;
  final bool pulsing;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(
            alpha: widget.pulsing ? 0.35 + 0.65 * _controller.value : 1,
          ),
        ),
      ),
    );
  }
}
