import 'package:flutter/material.dart';

import '../theme.dart';

/// Rückfrage vor etwas, das sich nicht zurücknehmen lässt.
///
/// [destructive] färbt den bestätigenden Knopf rot — Löschen soll anders
/// aussehen als Speichern, sonst tippt man es aus Gewohnheit weg.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder:
        (context) => AlertDialog(
          backgroundColor: Tone.raised,
          title: Text(title, style: const TextStyle(fontSize: 16)),
          content: Text(
            body,
            style: const TextStyle(fontSize: 13.5, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              style:
                  destructive
                      ? FilledButton.styleFrom(
                        backgroundColor: Tone.alert,
                        foregroundColor: Tone.ink,
                      )
                      : null,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
  );
  return result ?? false;
}

/// Fragt einen Text ab. `null` heißt abgebrochen, ein leerer String ist eine
/// gültige Antwort (etwa: Systemprompt entfernen).
Future<String?> askText(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  String? help,
  String action = 'Speichern',
  bool multiline = false,
}) {
  return showDialog<String>(
    context: context,
    builder:
        (context) => _TextDialog(
          title: title,
          initial: initial,
          hint: hint,
          help: help,
          action: action,
          multiline: multiline,
        ),
  );
}

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.initial,
    required this.hint,
    required this.help,
    required this.action,
    required this.multiline,
  });

  final String title;
  final String initial;
  final String? hint;
  final String? help;
  final String action;
  final bool multiline;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _field = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_field.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Tone.raised,
      title: Text(widget.title, style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _field,
              autofocus: true,
              minLines: widget.multiline ? 4 : 1,
              maxLines: widget.multiline ? 12 : 1,
              textInputAction:
                  widget.multiline
                      ? TextInputAction.newline
                      : TextInputAction.done,
              onSubmitted: widget.multiline ? null : (_) => _submit(),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: const TextStyle(color: Tone.faint),
              ),
            ),
            if (widget.help != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.help!,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Tone.faint,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}

void showNotice(BuildContext context, String text, {bool warn = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        backgroundColor: warn ? Tone.amber.withValues(alpha: 0.9) : null,
        content: Text(text),
        duration: const Duration(seconds: 3),
      ),
    );
}
