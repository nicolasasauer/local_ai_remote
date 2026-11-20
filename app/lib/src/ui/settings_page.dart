import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/model_entry.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'errors.dart';
import 'widgets/fact_view.dart';

/// Wird von der CI per `--dart-define=APP_VERSION=…` gesetzt.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  bool _dirty = false;
  bool _showToken = false;
  String? _urlError;

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

  Future<void> _save() async {
    final url = normalizeGatewayUrl(_url.text);
    final problem = validateGatewayUrl(url);
    if (problem != null) {
      setState(() => _urlError = problem);
      return;
    }
    if (url != _url.text) _url.text = url;
    await ref.read(settingsProvider.notifier).save(
          baseUrl: url,
          token: _token.text,
        );
    if (!mounted) return;
    setState(() => _dirty = false);
    ref.invalidate(healthProvider);
    ref.read(telemetryProvider.notifier).reconnectNow();
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
            keyboardType: TextInputType.url,
            autocorrect: false,
            onChanged: (_) => setState(() {
              _dirty = true;
              _urlError = null;
            }),
            decoration: InputDecoration(
              hintText: 'https://desktop.tailnet.ts.net',
              prefixIcon: const Icon(Icons.link, size: 18),
              errorText: _urlError,
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
            obscureText: !_showToken,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: InputDecoration(
              hintText: 'GATEWAY_TOKEN',
              prefixIcon: const Icon(Icons.key, size: 18),
              suffixIcon: IconButton(
                tooltip: _showToken ? 'Verbergen' : 'Anzeigen',
                icon: Icon(
                  _showToken ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () => setState(() => _showToken = !_showToken),
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Liegt nur auf diesem Gerät und wird nicht in Backups übernommen.',
            style: TextStyle(fontSize: 11.5, color: Tone.faint, height: 1.4),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _dirty ? _save : null,
                child: const Text('Speichern und verbinden'),
              ),
              OutlinedButton.icon(
                onPressed: ref.watch(settingsProvider).isConfigured
                    ? () {
                        ref.invalidate(healthProvider);
                        ref.invalidate(modelsProvider);
                        ref.read(telemetryProvider.notifier).reconnectNow();
                      }
                    : null,
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('Erneut prüfen'),
              ),
            ],
          ),
          const SizedBox(height: 26),
          const _Label('Verbindung'),
          health.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: LinearProgressIndicator(minHeight: 2),
            ),
            error: (e, _) {
              final problem = describeError(e);
              return _Card(
                accent: Tone.alert,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.error_outline,
                            size: 16, color: Tone.alert),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            problem.headline,
                            style: const TextStyle(
                                fontSize: 13,
                                color: Tone.ink,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    if (problem.detail != null) ...[
                      const SizedBox(height: 6),
                      SelectableText(
                        problem.detail!,
                        style: const TextStyle(
                            fontSize: 11.5, color: Tone.muted, height: 1.45),
                      ),
                    ],
                  ],
                ),
              );
            },
            data: (data) => _Health(health: data),
          ),
          const SizedBox(height: 26),
          const _Label('Über'),
          const _Card(
            accent: Tone.hairline,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FactRow('App-Version', Text(appVersion)),
                SizedBox(height: 8),
                Text(
                  'Tastenkürzel am Desktop: Strg+N neuer Chat, Strg+1…4 '
                  'Bereiche, Enter sendet, Umschalt+Enter neue Zeile.',
                  style: TextStyle(
                      fontSize: 11.5, color: Tone.faint, height: 1.4),
                ),
              ],
            ),
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
