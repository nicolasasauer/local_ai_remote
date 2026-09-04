import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/model_entry.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'widgets/fact_view.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _url = TextEditingController(text: settings.baseUrl);
    _token = TextEditingController(text: settings.token);
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final health = ref.watch(healthProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
        children: [
          const _Label('Gateway'),
          TextField(
            controller: _url,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: const InputDecoration(
              hintText: 'https://desktop.tailnet.ts.net',
              prefixIcon: Icon(Icons.link, size: 18),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Die Adresse aus "tailscale serve status". Ohne Tailscale-Zertifikat '
            'weigert sich Android bei reinem HTTP.',
            style: TextStyle(fontSize: 11.5, color: Tone.faint, height: 1.4),
          ),
          const SizedBox(height: 16),
          const _Label('Token'),
          TextField(
            controller: _token,
            obscureText: true,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: const InputDecoration(
              hintText: 'GATEWAY_TOKEN',
              prefixIcon: Icon(Icons.key, size: 18),
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _dirty
                  ? () async {
                      await ref.read(settingsProvider.notifier).save(
                            baseUrl: _url.text,
                            token: _token.text,
                          );
                      setState(() => _dirty = false);
                      ref.invalidate(healthProvider);
                      ref.read(telemetryProvider.notifier).reconnectNow();
                    }
                  : null,
              child: const Text('Speichern und verbinden'),
            ),
          ),
          const SizedBox(height: 26),
          const _Label('Verbindung'),
          health.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: LinearProgressIndicator(minHeight: 2),
            ),
            error: (e, _) => _Card(
              accent: Tone.alert,
              child: Text(
                '$e',
                style: const TextStyle(fontSize: 12.5, color: Tone.ink, height: 1.45),
              ),
            ),
            data: (data) => _Health(health: data),
          ),
        ],
      ),
    );
  }
}

class _Health extends StatelessWidget {
  const _Health({required this.health});

  final GatewayHealth health;

  @override
  Widget build(BuildContext context) {
    return _Card(
      accent: Tone.teal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FactRow('Host', Text(health.hostname)),
          FactRow('Gateway-Version', Text(health.gatewayVersion)),
          const SizedBox(height: 6),
          for (final backend in health.backends)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    backend.reachable ? Icons.check_circle : Icons.cancel,
                    size: 15,
                    color: backend.reachable ? Tone.teal : Tone.muted,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              backend.backend.label,
                              style: const TextStyle(
                                  fontSize: 13, color: Tone.ink),
                            ),
                            const SizedBox(width: 8),
                            FactText<String>(
                              backend.version,
                              format: (v) => v,
                              mono: true,
                              style: const TextStyle(
                                  fontSize: 11.5, color: Tone.muted),
                            ),
                          ],
                        ),
                        if (backend.message != null)
                          Text(
                            backend.message!,
                            style: const TextStyle(
                                fontSize: 11.5, color: Tone.muted, height: 1.4),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.accent});

  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: Tone.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: child,
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
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
}
