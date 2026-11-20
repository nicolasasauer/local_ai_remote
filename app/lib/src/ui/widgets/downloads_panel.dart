import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/load_settings.dart';
import '../../state/providers.dart';
import '../../theme.dart';
import '../dialogs.dart';
import '../errors.dart';
import '../format.dart';

/// Neue Modelle über Ollama herunterladen.
///
/// Erscheint nur, wenn das Gateway es erlaubt (`GATEWAY_ALLOW_PULL=1`). Der
/// Download läuft im Gateway weiter, auch wenn die App geschlossen wird —
/// hier wird nur der Stand abgefragt.
class DownloadsPanel extends ConsumerWidget {
  const DownloadsPanel({super.key});

  static const libraryUrl = 'https://ollama.com/library';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(pullsProvider).valueOrNull;
    if (snap == null || (!snap.enabled && snap.jobs.isEmpty)) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      decoration: BoxDecoration(
        color: Tone.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Tone.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.download_outlined, size: 17, color: Tone.teal),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Herunterladen (Ollama)',
                  style: TextStyle(
                      fontSize: 13.5,
                      color: Tone.ink,
                      fontWeight: FontWeight.w600),
                ),
              ),
              if (snap.enabled)
                TextButton.icon(
                  onPressed: snap.anyRunning ? null : () => _start(context, ref),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Modell'),
                ),
            ],
          ),
          if (snap.jobs.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                'Lädt ein Modell aus der Ollama-Bibliothek auf den Desktop. '
                'Läuft weiter, auch wenn die App geschlossen ist.',
                style: TextStyle(fontSize: 11.5, color: Tone.faint, height: 1.4),
              ),
            ),
          for (final job in snap.jobs) _JobRow(job: job),
          if (snap.enabled)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: openLibrary,
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('Namen in der Ollama-Bibliothek suchen',
                    style: TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final name = await askText(
      context,
      title: 'Modell herunterladen',
      hint: 'z. B. qwen3:8b',
      help: 'Name wie in der Ollama-Bibliothek, mit Größe nach dem '
          'Doppelpunkt. Große Modelle brauchen viele Gigabyte Platz auf dem '
          'Desktop.',
      action: 'Herunterladen',
    );
    final model = name?.trim() ?? '';
    if (model.isEmpty || !context.mounted) return;
    try {
      await ref.read(gatewayClientProvider).startPull(model);
      ref.invalidate(pullsProvider);
    } catch (e) {
      if (context.mounted) {
        showNotice(context, describeError(e).headline, warn: true);
      }
    }
  }

  static Future<void> openLibrary() => launchUrl(
        Uri.parse(libraryUrl),
        mode: LaunchMode.externalApplication,
      );
}

class _JobRow extends ConsumerWidget {
  const _JobRow({required this.job});

  final PullJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (farbe, text) = switch (job.state) {
      PullState.running => (Tone.teal, _laufend(job)),
      PullState.done => (Tone.teal, 'Fertig'),
      PullState.failed => (Tone.alert, job.error ?? 'Fehlgeschlagen'),
      PullState.cancelled => (Tone.muted, 'Abgebrochen'),
    };

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  job.model,
                  style: kMono.copyWith(fontSize: 12.5, color: Tone.ink),
                ),
              ),
              if (job.state == PullState.running)
                IconButton(
                  tooltip: 'Download abbrechen',
                  visualDensity: VisualDensity.compact,
                  iconSize: 17,
                  onPressed: () async {
                    try {
                      await ref.read(gatewayClientProvider).cancelPull(job.model);
                      ref.invalidate(pullsProvider);
                    } catch (e) {
                      if (context.mounted) {
                        showNotice(context, describeError(e).headline, warn: true);
                      }
                    }
                  },
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
          if (job.state == PullState.running) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              // Ohne bekannte Größe ein unbestimmter Balken statt einer
              // erfundenen Prozentzahl.
              child: LinearProgressIndicator(
                value: job.fraction,
                minHeight: 4,
                backgroundColor: Tone.hairline,
                color: Tone.teal,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Text(text, style: TextStyle(fontSize: 11.5, color: farbe, height: 1.4)),
        ],
      ),
    );
  }

  static String _laufend(PullJob job) {
    final f = job.fraction;
    if (f == null || job.total == null) {
      return job.status.isEmpty ? 'Startet …' : job.status;
    }
    return '${(f * 100).toStringAsFixed(0)} % · '
        '${formatBytes(job.completed)} von ${formatBytes(job.total!)}';
  }
}
