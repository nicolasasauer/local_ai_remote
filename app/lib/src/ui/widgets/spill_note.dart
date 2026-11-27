import 'package:flutter/material.dart';

import '../../models/telemetry.dart';
import '../../theme.dart';
import '../format.dart';

/// Warnt, wenn die Grafikkarte in den System-RAM auslagert.
///
/// Der VRAM sieht in dem Fall voll, aber unauffällig aus — die Ursache für
/// zähe Antworten ist allein hier zu sehen.
class SpillNote extends StatelessWidget {
  const SpillNote({required this.gpu, this.compact = false, super.key});

  final GpuSample gpu;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (!gpu.spillsToRam) return const SizedBox.shrink();
    final menge = '${formatGiB(gpu.sharedUsedBytes.value!)} GiB';
    final text =
        compact
            ? '$menge im System-RAM — das Modell passt nicht ganz in den VRAM'
            : '$menge liegen im System-RAM statt im VRAM. Die Karte liest diesen '
                'Teil über PCIe, Antworten werden dadurch deutlich langsamer. '
                'Abhilfe: kleineres Kontextfenster, KV-Cache quantisieren, '
                'MoE-Experten gezielt auf die CPU legen oder ein kleineres Quant.';

    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(top: compact ? 4 : 12),
      padding: EdgeInsets.fromLTRB(10, compact ? 5 : 9, 10, compact ? 5 : 9),
      decoration: BoxDecoration(
        color: Tone.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Tone.amber.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.swap_vert, size: compact ? 13 : 16, color: Tone.amber),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: compact ? 11.5 : 12.5,
                color: Tone.amber,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
