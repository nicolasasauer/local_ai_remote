import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/model_entry.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'format.dart';
import 'widgets/fact_view.dart';

class ModelsPage extends ConsumerWidget {
  const ModelsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(modelsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Modelle')),
      body: snapshot.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Problem(message: '$e'),
        data: (data) => _ModelList(data: data),
      ),
    );
  }
}

class _ModelList extends ConsumerWidget {
  const _ModelList({required this.data});

  final ModelsSnapshot data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!data.gatewayReachable) {
      return _Problem(message: data.gatewayError!);
    }

    final byBackend = <BackendId, List<ModelEntry>>{};
    for (final model in data.models) {
      byBackend.putIfAbsent(model.backend, () => []).add(model);
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final error in data.backendErrors)
          _BackendProblem(error: error),
        for (final backend in BackendId.values) ...[
          _SectionHeader(
            title: backend.label,
            count: byBackend[backend]?.length ?? 0,
          ),
          if ((byBackend[backend] ?? const []).isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 2, 16, 14),
              child: Text(
                'Keine Modelle gemeldet.',
                style: TextStyle(fontSize: 12.5, color: Tone.faint),
              ),
            ),
          for (final model in byBackend[backend] ?? const <ModelEntry>[])
            ModelTile(
              model: model,
              onTap: () => showModelDetails(context, ref, model),
            ),
        ],
      ],
    );
  }
}

class ModelTile extends StatelessWidget {
  const ModelTile({
    required this.model,
    required this.onTap,
    this.selected = false,
    super.key,
  });

  final ModelEntry model;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 11, 14, 11),
        decoration: BoxDecoration(
          color: selected ? Tone.raised : null,
          border: const Border(bottom: BorderSide(color: Tone.hairline)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: StateDot(state: model.state),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.label,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Tone.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 6,
                    runSpacing: 5,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _Tag(text: model.state.label, color: _stateColor(model.state)),
                      if (model.parameterSize.isKnown)
                        _Tag(text: model.parameterSize.value!),
                      if (model.quantization.isKnown)
                        _Tag(text: model.quantization.value!),
                      if (model.effectiveContext.isKnown)
                        _Tag(
                          text:
                              '${formatCount(model.effectiveContext.value!)} tok',
                        ),
                      CapabilityBadge(
                        fact: model.vision,
                        label: 'Bilder',
                        icon: Icons.image_outlined,
                      ),
                      CapabilityBadge(
                        fact: model.tools,
                        label: 'Tools',
                        icon: Icons.build_outlined,
                      ),
                    ],
                  ),
                  if (model.isPartiallyOffloaded)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Nur ${(model.vramFraction.value! * 100).toStringAsFixed(0)} % '
                        'auf der GPU — der Rest liegt im RAM und bremst spürbar.',
                        style: const TextStyle(fontSize: 11.5, color: Tone.amber),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (model.isLoaded)
                  FactText<int>(
                    model.vramBytes,
                    format: formatBytes,
                    mono: true,
                    style: const TextStyle(fontSize: 12, color: Tone.ink),
                  )
                else
                  FactText<int>(
                    model.diskBytes,
                    format: formatBytes,
                    mono: true,
                    style: const TextStyle(fontSize: 12, color: Tone.muted),
                  ),
                const SizedBox(height: 3),
                if (model.isLoaded)
                  Text(
                    model.unloadsAt.isKnown
                        ? 'entlädt in ${formatCountdown(model.unloadsAt.value!)}'
                        : 'kein Ablauf',
                    style: const TextStyle(fontSize: 10.5, color: Tone.faint),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Color _stateColor(ModelState state) => switch (state) {
      ModelState.loaded => Tone.amber,
      ModelState.loading || ModelState.unloading => Tone.teal,
      ModelState.error => Tone.alert,
      ModelState.notLoaded => Tone.muted,
    };

class StateDot extends StatelessWidget {
  const StateDot({required this.state, this.size = 8, super.key});

  final ModelState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = _stateColor(state);
    final hollow = state == ModelState.notLoaded;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hollow ? Colors.transparent : color,
        border: Border.all(color: color, width: 1.4),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: (color ?? Tone.muted).withValues(alpha: 0.10),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: color ?? Tone.muted),
      ),
    );
  }
}

/// Detailblatt mit allem, was das Gateway über das Modell weiß — samt der
/// Felder, die es nicht weiß.
Future<void> showModelDetails(
  BuildContext context,
  WidgetRef ref,
  ModelEntry model,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Tone.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
    ),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StateDot(state: model.state, size: 9),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    model.label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Tone.ink,
                    ),
                  ),
                ),
              ],
            ),
            Text(
              '${model.backend.label} · ${model.id}',
              style: const TextStyle(fontSize: 11.5, color: Tone.faint),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FactRow('Zustand', Text(model.state.label)),
                    FactRow('Familie',
                        FactText<String>(model.family, format: (v) => v)),
                    FactRow('Parameter',
                        FactText<String>(model.parameterSize, format: (v) => v)),
                    FactRow('Quantisierung',
                        FactText<String>(model.quantization, format: (v) => v)),
                    FactRow(
                      'Größe auf Platte',
                      FactText<int>(model.diskBytes,
                          format: formatBytes, mono: true),
                    ),
                    FactRow(
                      'Im VRAM',
                      FactText<int>(model.vramBytes,
                          format: formatBytes, mono: true),
                    ),
                    FactRow(
                      'Anteil auf GPU',
                      FactText<double>(
                        model.vramFraction,
                        format: (v) => formatPercent(v * 100),
                        mono: true,
                      ),
                    ),
                    FactRow(
                      'Kontext (Modell)',
                      FactText<int>(model.contextLength,
                          format: formatCount, mono: true),
                    ),
                    FactRow(
                      'Kontext (geladen)',
                      FactText<int>(model.loadedContextLength,
                          format: formatCount, mono: true),
                    ),
                    FactRow(
                      'Entlädt automatisch',
                      FactText<DateTime>(
                        model.unloadsAt,
                        format: (v) => '${formatClock(v)} (${formatCountdown(v)})',
                      ),
                    ),
                    FactRow(
                      'Bilder',
                      FactText<bool>(model.vision,
                          format: (v) => v ? 'unterstützt' : 'nein'),
                    ),
                    FactRow(
                      'Tools',
                      FactText<bool>(model.tools,
                          format: (v) => v ? 'unterstützt' : 'nein'),
                    ),
                    if (model.error != null)
                      FactRow(
                        'Fehler',
                        Text(model.error!,
                            style: const TextStyle(color: Tone.alert)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => _act(context, ref, model, pin: true),
                  icon: const Icon(Icons.push_pin_outlined, size: 16),
                  label: const Text('Im Speicher halten'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: () => _act(context, ref, model, pin: false),
                  icon: const Icon(Icons.eject_outlined, size: 16),
                  label: const Text('Entladen'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _act(
  BuildContext context,
  WidgetRef ref,
  ModelEntry model, {
  required bool pin,
}) async {
  final client = ref.read(gatewayClientProvider);
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (pin) {
      await client.pin(model.ref);
    } else {
      await client.unload(model.ref);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(pin
            ? '${model.label} bleibt im Speicher'
            : '${model.label} wird entladen'),
      ),
    );
  } catch (e) {
    // Häufigster Fall: LM Studio ohne CLI. Das Gateway liefert den Grund mit,
    // also wird er wörtlich gezeigt statt zu einem generischen Fehler verkürzt.
    messenger.showSnackBar(
      SnackBar(content: Text('$e'), backgroundColor: Tone.alert),
    );
  }
}

/// Auswahl des Modells für einen Chat.
Future<ModelRef?> showModelPicker(
  BuildContext context,
  WidgetRef ref, {
  ModelRef? current,
}) {
  final snapshot = ref.read(modelsProvider).valueOrNull;
  final models = snapshot?.selectable ?? const <ModelEntry>[];

  return showModalBottomSheet<ModelRef>(
    context: context,
    backgroundColor: Tone.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
    ),
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 16, 18, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Modell für diesen Chat',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Tone.ink,
                ),
              ),
            ),
          ),
          if (models.isEmpty)
            const Padding(
              padding: EdgeInsets.all(18),
              child: Text(
                'Keine Modelle verfügbar. Läuft das Gateway, und sind Ollama '
                'oder LM Studio gestartet?',
                style: TextStyle(fontSize: 13, color: Tone.muted, height: 1.45),
              ),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final model in models)
                  ModelTile(
                    model: model,
                    selected: model.ref == current,
                    onTap: () => Navigator.of(context).pop(model.ref),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 0.8,
              color: Tone.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text('$count', style: kMono.copyWith(fontSize: 11, color: Tone.faint)),
        ],
      ),
    );
  }
}

class _BackendProblem extends StatelessWidget {
  const _BackendProblem({required this.error});

  final BackendError error;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Tone.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Tone.amber.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 15, color: Tone.amber),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${error.backend.label} antwortet nicht',
                  style: const TextStyle(fontSize: 12.5, color: Tone.ink),
                ),
                Text(
                  error.message,
                  style: const TextStyle(fontSize: 11.5, color: Tone.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 32, color: Tone.faint),
            const SizedBox(height: 12),
            const Text(
              'Gateway nicht erreichbar',
              style: TextStyle(fontSize: 15, color: Tone.ink),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: Tone.muted, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
