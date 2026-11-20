import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/load_estimate.dart';
import '../../models/load_settings.dart';
import '../../models/model_entry.dart';
import '../../state/providers.dart';
import '../../theme.dart';
import '../errors.dart';
import '../format.dart';

/// Ladeoptionen eines Modells: Kontextfenster, Haltedauer, GPU — und
/// "Jetzt laden", damit die erste Antwort nicht aufs Laden wartet.
///
/// Gespeichert wird sofort bei jeder Änderung; wirksam wird es bei der
/// nächsten Anfrage oder beim nächsten "Jetzt laden". Was davon bei welchem
/// Backend wann greift, steht direkt darunter — eine Einstellung, die still
/// nicht gilt, wäre schlimmer als keine.
class LoadOptionsPanel extends ConsumerStatefulWidget {
  const LoadOptionsPanel({required this.model, super.key});

  final ModelEntry model;

  @override
  ConsumerState<LoadOptionsPanel> createState() => _LoadOptionsPanelState();
}

class _LoadOptionsPanelState extends ConsumerState<LoadOptionsPanel> {
  bool _loading = false;
  String? _error;

  /// Der aktuelle Eintrag aus der Modellliste — die Detailansicht wurde mit
  /// einem Schnappschuss geöffnet, und nach "Jetzt laden" soll der neue
  /// Zustand stimmen.
  ModelEntry get model =>
      ref
          .watch(modelsProvider)
          .valueOrNull
          ?.models
          .where((m) => m.ref == widget.model.ref)
          .firstOrNull ??
      widget.model;
  bool get _lmStudio => model.backend == BackendId.lmstudio;

  @override
  Widget build(BuildContext context) {
    ref.watch(loadSettingsProvider);
    final settings =
        ref.read(loadSettingsProvider.notifier).forModel(model.ref);
    final gatewayMax = ref.watch(healthProvider).valueOrNull?.maxContext;
    final stufen = contextChoices(
      modelMax: model.contextLength.value,
      gatewayMax: gatewayMax,
    );

    Future<void> set(LoadSettings next) =>
        ref.read(loadSettingsProvider.notifier).set(model.ref, next);

    final geladen = model.loadedContextLength.value;
    final gewuenscht = settings.contextLength;
    final abweichung = model.isLoaded &&
        geladen != null &&
        gewuenscht != null &&
        geladen != gewuenscht;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Heading('Ladeoptionen'),
        _Row(
          label: 'Kontextfenster',
          child: DropdownButton<int?>(
            value: gewuenscht,
            isDense: true,
            underline: const SizedBox.shrink(),
            dropdownColor: Tone.raised,
            style: kMono.copyWith(fontSize: 13, color: Tone.ink),
            items: [
              const DropdownMenuItem(value: null, child: Text('Vorgabe')),
              for (final s in stufen)
                DropdownMenuItem(value: s, child: Text('${formatCount(s)} tok')),
              // Ein gespeicherter Wert außerhalb der Stufen (Modell
              // gewechselt, Grenze gesenkt) bleibt sichtbar, statt als
              // "Vorgabe" zu erscheinen, während er weiter gesendet wird.
              if (gewuenscht != null && !stufen.contains(gewuenscht))
                DropdownMenuItem(
                  value: gewuenscht,
                  child: Text('${formatCount(gewuenscht)} tok ⚠',
                      style: const TextStyle(color: Tone.amber)),
                ),
            ],
            onChanged: (v) => set(v == null
                ? settings.copyWith(clearContext: true)
                : settings.copyWith(contextLength: v)),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text(
            'Größer heißt: mehr Verlauf passt hinein, aber der Zwischenspeicher '
            'dafür belegt Grafikspeicher. Passt er nicht mehr hinein, wird das '
            'Modell deutlich langsamer.',
            style: TextStyle(fontSize: 11, color: Tone.faint, height: 1.4),
          ),
        ),
        const _Label('Im Speicher halten nach der letzten Anfrage'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (sekunden, text) in keepAliveChoices)
              ChoiceChip(
                label: Text(text, style: const TextStyle(fontSize: 12)),
                selected: settings.keepAliveSeconds == sekunden,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => set(sekunden == null
                    ? settings.copyWith(clearKeepAlive: true)
                    : settings.copyWith(keepAliveSeconds: sekunden)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        const _Label('Grafikkarte'),
        SegmentedButton<GpuMode>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [
            for (final m in GpuMode.values)
              ButtonSegment(
                value: m,
                label: Text(m.label, style: const TextStyle(fontSize: 12)),
              ),
          ],
          selected: {settings.gpu},
          onSelectionChanged: (s) => set(settings.copyWith(gpu: s.first)),
        ),
        const SizedBox(height: 12),
        _EstimateView(
          estimate: estimateLoad(
            model: model,
            settings: settings,
            telemetry: ref.watch(telemetryProvider).latest,
          ),
        ),
        const SizedBox(height: 10),
        if (_lmStudio)
          const _Note(
            'LM Studio übernimmt Kontextfenster und Grafikkarte nur beim '
            'Laden — also über „Jetzt laden". Im Chat gilt von hier nur die '
            'Haltedauer, und auch die nur, wenn LM Studio das Modell selbst '
            'nachlädt.',
          ),
        if (gewuenscht != null &&
            model.contextLength.value != null &&
            gewuenscht > model.contextLength.value!)
          _Note(
            'Mehr als das Modell trainiert ist '
            '(${formatCount(model.contextLength.value!)} tok). Es lädt, '
            'aber jenseits davon werden die Antworten unzuverlässig.',
            color: Tone.amber,
          ),
        if (gatewayMax != null && gewuenscht != null && gewuenscht > gatewayMax)
          _Note(
            'Über der Grenze des Gateways (${formatCount(gatewayMax)} tok) — '
            'Anfragen mit diesem Wert werden abgelehnt.',
            color: Tone.alert,
          ),
        if (abweichung)
          _Note(
            'Geladen mit ${formatCount(geladen)} tok, eingestellt '
            '${formatCount(gewuenscht)}. '
            '${_lmStudio ? 'Gilt nach „Jetzt laden".' : 'Ollama lädt bei der nächsten Anfrage neu.'}',
            color: Tone.amber,
          ),
        if (_error != null) _Note(_error!, color: Tone.alert),
        const SizedBox(height: 4),
        FilledButton.icon(
          onPressed: _loading ? null : () => _loadNow(settings),
          icon: _loading
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow_rounded, size: 18),
          label: Text(_loading ? 'Wird geladen …' : 'Jetzt laden'),
        ),
      ],
    );
  }

  Future<void> _loadNow(LoadSettings settings) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(gatewayClientProvider).loadModel(model.ref, settings);
      ref.invalidate(modelsProvider);
      messenger.showSnackBar(
        SnackBar(content: Text('${model.label} ist geladen')),
      );
    } catch (e) {
      // Der Grund des Backends (zu wenig Speicher, lms fehlt …) wird
      // wörtlich gezeigt — er ist meist genau die Information, die fehlt.
      if (mounted) setState(() => _error = describeError(e).headline);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 0.8,
            color: Tone.muted,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: const TextStyle(fontSize: 12.5, color: Tone.muted)),
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(fontSize: 12.5, color: Tone.muted)),
            ),
            child,
          ],
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.color = Tone.faint});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: TextStyle(fontSize: 11.5, color: color, height: 1.4)),
      );
}


/// Was das Modell mit diesen Einstellungen voraussichtlich belegt.
class _EstimateView extends StatelessWidget {
  const _EstimateView({required this.estimate});

  final LoadEstimate estimate;

  @override
  Widget build(BuildContext context) {
    final e = estimate;
    final gib = (int b) => '${formatGiB(b)} GiB';

    final (farbe, icon, urteil) = switch (e.fit) {
      Fit.fits => (Tone.teal, Icons.check_circle_outline,
          'Passt in den freien ${e.target}'),
      Fit.tight => (Tone.amber, Icons.warning_amber_rounded,
          'Knapp — ohne Reserve für Rechenpuffer; einzelne Schichten '
              'landen womöglich auf der CPU'),
      Fit.spills => (Tone.alert, Icons.error_outline,
          e.target == 'Grafikspeicher'
              ? 'Passt nicht — ein Teil läuft auf der CPU, Antworten werden '
                  'deutlich langsamer'
              : 'Passt nicht in den freien Arbeitsspeicher — der Desktop '
                  'beginnt auszulagern'),
      Fit.unknown => (Tone.muted, Icons.help_outline,
          'Nicht abschätzbar'),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: farbe.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: farbe.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Geschätzter Bedarf',
                  style: TextStyle(fontSize: 12, color: Tone.muted)),
              const Spacer(),
              Text(
                e.totalBytes == null ? '—' : '≈ ${gib(e.totalBytes!)}',
                style: kMono.copyWith(
                    fontSize: 13.5, color: Tone.ink, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              'Gewichte ${e.weightBytes == null ? '—' : gib(e.weightBytes!)}',
              'Kontext ${e.kvBytes == null ? '—' : gib(e.kvBytes!)}'
                  '${e.contextTokens == null ? '' : ' (${formatCount(e.contextTokens!)} tok)'}',
              if (e.availableBytes != null)
                'frei ${gib(e.availableBytes!.clamp(0, 1 << 62))}',
            ].join(' · '),
            style: kMono.copyWith(fontSize: 11, color: Tone.muted),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 15, color: farbe),
              const SizedBox(width: 7),
              Expanded(
                child: Text(urteil,
                    style: TextStyle(fontSize: 12, color: farbe, height: 1.35)),
              ),
            ],
          ),
          for (final r in e.reasons)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 22),
              child: Text(r,
                  style: const TextStyle(
                      fontSize: 11, color: Tone.faint, height: 1.35)),
            ),
        ],
      ),
    );
  }
}
