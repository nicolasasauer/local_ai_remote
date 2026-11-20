import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme.dart';
import '../errors.dart';

/// Schmaler Hinweis über dem Chat, wenn das Gateway nicht antwortet.
///
/// Ohne ihn sieht ein abgeschalteter Desktop im Chat nur aus wie
/// "Modell derzeit nicht angeboten" — richtig, aber am falschen Ende erklärt.
class GatewayBanner extends ConsumerWidget {
  const GatewayBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(modelsProvider).valueOrNull;
    if (snapshot == null || snapshot.gatewayReachable) {
      return const SizedBox.shrink();
    }

    final notConfigured = snapshot.notConfigured;
    final hint =
        notConfigured
            ? const GatewayProblem(
              'Noch kein Gateway eingerichtet',
              fixInSettings: true,
            )
            : describeError(
              snapshot.gatewayErrorCause ?? snapshot.gatewayError!,
            );
    final color = notConfigured ? Tone.teal : Tone.amber;

    return Material(
      color: color.withValues(alpha: 0.10),
      child: InkWell(
        onTap:
            () => ref.read(shellTabProvider.notifier).state = ShellTab.settings,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: color.withValues(alpha: 0.35)),
            ),
          ),
          child: Row(
            children: [
              Icon(
                notConfigured ? Icons.link : Icons.cloud_off_outlined,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hint.headline,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (hint.detail != null)
                      Text(
                        hint.detail!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Tone.muted),
                      ),
                  ],
                ),
              ),
              Text(
                notConfigured ? 'Einrichten' : 'Einstellungen',
                style: TextStyle(fontSize: 12, color: color),
              ),
              Icon(Icons.chevron_right, size: 18, color: color),
            ],
          ),
        ),
      ),
    );
  }
}
