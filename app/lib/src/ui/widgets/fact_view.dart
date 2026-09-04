import 'package:flutter/material.dart';

import '../../models/fact.dart';
import '../../theme.dart';

/// Zeigt einen [Fact] an. Fehlt der Wert, erscheint ein Gedankenstrich mit
/// antippbarer Begründung — nie eine erfundene Null.
class FactText<T> extends StatelessWidget {
  const FactText(
    this.fact, {
    required this.format,
    this.style,
    this.mono = false,
    super.key,
  });

  final Fact<T> fact;
  final String Function(T value) format;
  final TextStyle? style;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final base = (style ?? DefaultTextStyle.of(context).style);
    final effective = mono
        ? base.merge(kMono).copyWith(color: base.color)
        : base;

    if (fact.isKnown) {
      return Text(format(fact.value as T), style: effective);
    }

    return _MissingValue(fact: fact, style: effective);
  }
}

class _MissingValue extends StatelessWidget {
  const _MissingValue({required this.fact, required this.style});

  final Fact<Object?> fact;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showFactReason(context, fact),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('—', style: style.copyWith(color: Tone.faint)),
            const SizedBox(width: 3),
            Icon(
              Icons.help_outline,
              size: (style.fontSize ?? 13) * 0.85,
              color: Tone.faint,
            ),
          ],
        ),
      ),
    );
  }
}

/// Begründung als Dialog, damit sie auch auf Android ohne Hover ankommt.
Future<void> showFactReason(BuildContext context, Fact<Object?> fact) {
  final unsupported = fact.certainty == Certainty.unsupported;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: Tone.raised,
      title: Text(
        unsupported ? 'Gibt es hier nicht' : 'Nicht ermittelbar',
        style: const TextStyle(fontSize: 16),
      ),
      content: Text(
        fact.note ??
            (unsupported
                ? 'Dieses Backend liefert den Wert prinzipiell nicht.'
                : 'Der Wert konnte nicht gelesen werden. Das Gateway hat keinen Grund mitgeliefert.'),
        style: const TextStyle(fontSize: 13.5, height: 1.45),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Verstanden'),
        ),
      ],
    ),
  );
}

/// Kleines Label-Wert-Paar für Detailansichten.
class FactRow extends StatelessWidget {
  const FactRow(this.label, this.child, {super.key});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 148,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 13.5, color: Tone.ink),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// Badge für Ja/Nein-Fähigkeiten. Unbekannt heißt Fragezeichen, nicht "nein" —
/// ein Modell fälschlich als textonly zu markieren wäre schlechter.
class CapabilityBadge extends StatelessWidget {
  const CapabilityBadge({
    required this.fact,
    required this.label,
    required this.icon,
    super.key,
  });

  final Fact<bool> fact;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final known = fact.certainty == Certainty.known;
    final yes = fact.value == true;
    if (known && !yes) return const SizedBox.shrink();

    final color = known ? Tone.teal : Tone.muted;
    return InkWell(
      onTap: known ? null : () => showFactReason(context, fact),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              known ? label : '$label?',
              style: TextStyle(fontSize: 11, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
