import 'package:flutter/material.dart';

import '../../data/token_budget.dart';
import '../../theme.dart';
import '../format.dart';
import 'fact_view.dart';
import 'sparkline.dart';

/// Füllstand des Kontextfensters. Ist die Grenze unbekannt, gibt es bewusst
/// keinen Balken — ein Balken gegen einen geratenen Maximalwert wäre eine
/// Behauptung, die die App nicht belegen kann.
class ContextBar extends StatelessWidget {
  const ContextBar({required this.budget, this.onTap, super.key});

  final ContextBudget budget;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fill = budget.fill;
    final color = fill == null
        ? Tone.muted
        : fill >= 1
            ? Tone.alert
            : fill >= 0.75
                ? Tone.amber
                : Tone.teal;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Kontext',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(width: 8),
                Text(
                  budget.usedLabel,
                  style: kMono.copyWith(fontSize: 11.5, color: Tone.ink),
                ),
                const Text(' / ', style: TextStyle(fontSize: 11.5, color: Tone.faint)),
                FactText<int>(
                  budget.limit,
                  format: formatCount,
                  mono: true,
                  style: const TextStyle(fontSize: 11.5, color: Tone.muted),
                ),
                const Spacer(),
                if (budget.droppedTokens > 0)
                  Text(
                    '${formatCount(budget.droppedTokens)} nicht gesendet',
                    style: const TextStyle(fontSize: 11, color: Tone.faint),
                  ),
                if (fill != null && budget.droppedTokens == 0)
                  Text(
                    formatPercent(fill * 100),
                    style: kMono.copyWith(fontSize: 11.5, color: color),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            FillBar(fraction: fill, color: color, height: 3),
            if (fill != null && fill >= 1)
              const Padding(
                padding: EdgeInsets.only(top: 5),
                child: Text(
                  'Überlauf: der Server schneidet ältere Nachrichten ab. '
                  'Verdichtung einschalten oder Nachrichten abwählen.',
                  style: TextStyle(fontSize: 11, color: Tone.alert, height: 1.35),
                ),
              ),
            if (!budget.measured && fill != null)
              const Padding(
                padding: EdgeInsets.only(top: 5),
                child: Text(
                  'Geschätzt — nach der ersten Antwort dieses Modells wird der '
                  'Wert anhand der gemeldeten Prompt-Tokens korrigiert.',
                  style: TextStyle(fontSize: 11, color: Tone.faint, height: 1.35),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
