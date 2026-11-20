import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme.dart';
import 'chat_list_panel.dart';
import 'chat_page.dart';
import 'models_page.dart';
import 'settings_page.dart';
import 'telemetry_page.dart';
import 'widgets/gateway_banner.dart';

/// Ab 900 px feste Chatspalte (Windows), darunter Drawer (Android). Dasselbe
/// Panel-Widget, nur anders montiert.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  static const _destinations = [
    (Icons.forum_outlined, Icons.forum, 'Chat'),
    (Icons.memory_outlined, Icons.memory, 'Modelle'),
    (Icons.speed_outlined, Icons.speed, 'System'),
    (Icons.settings_outlined, Icons.settings, 'Einstellungen'),
  ];

  @override
  void initState() {
    super.initState();
    // Beim allerersten Start gibt es nichts zu chatten — direkt dorthin, wo
    // die Adresse eingetragen wird.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ref.read(settingsProvider).isConfigured) {
        ref.read(shellTabProvider.notifier).state = ShellTab.settings;
      }
    });
  }

  void _select(int i) =>
      ref.read(shellTabProvider.notifier).state = ShellTab.values[i];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final tab = ref.watch(shellTabProvider);
    final chats = ref.watch(chatListProvider);
    final activeId = ref.watch(activeChatIdProvider);
    final active =
        chats.where((c) => c.id == activeId).firstOrNull ??
        (chats.isEmpty ? null : chats.first);

    Widget page() => switch (tab) {
      ShellTab.models => const ModelsPage(),
      ShellTab.system => const TelemetryPage(),
      ShellTab.settings => const SettingsPage(),
      ShellTab.chat =>
        active == null
            ? _NoChat(
              onOpenList:
                  wide ? null : () => _scaffoldKey.currentState?.openDrawer(),
            )
            : ChatPage(
              key: ValueKey(active.id),
              chat: active,
              onOpenList:
                  wide ? null : () => _scaffoldKey.currentState?.openDrawer(),
            ),
    };

    final Widget shell;
    if (wide) {
      shell = Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: tab.index,
              onDestinationSelected: _select,
              labelType: NavigationRailLabelType.all,
              leading: const Padding(
                padding: EdgeInsets.only(top: 6, bottom: 10),
                child: _Logo(),
              ),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.$1),
                    selectedIcon: Icon(d.$2),
                    label: Text(d.$3),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            if (tab == ShellTab.chat) ...[
              const SizedBox(width: 280, child: ChatListPanel()),
              const VerticalDivider(width: 1),
            ],
            Expanded(child: page()),
          ],
        ),
      );
    } else {
      shell = Scaffold(
        key: _scaffoldKey,
        drawer:
            tab == ShellTab.chat
                ? Drawer(
                  backgroundColor: Tone.surface,
                  child: ChatListPanel(
                    onSelected: () => Navigator.of(context).pop(),
                  ),
                )
                : null,
        body: page(),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab.index,
          onDestinationSelected: _select,
          labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
          destinations: [
            for (final d in _destinations)
              NavigationDestination(
                icon: Icon(d.$1),
                selectedIcon: Icon(d.$2),
                label: d.$3,
              ),
          ],
        ),
      );
    }

    // Tastenkürzel für den Desktop. Strg+N wie überall, Strg+1…4 für die
    // Bereiche.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
          ref.read(shellTabProvider.notifier).state = ShellTab.chat;
          startNewChat(ref);
        },
        for (var i = 0; i < ShellTab.values.length; i++)
          SingleActivator(
                LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i),
                control: true,
              ):
              () => _select(i),
      },
      child: Focus(autofocus: true, child: shell),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: Tone.teal.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.developer_board, size: 20, color: Tone.teal),
    );
  }
}

class _NoChat extends ConsumerWidget {
  const _NoChat({this.onOpenList});

  final VoidCallback? onOpenList;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        leading:
            onOpenList == null
                ? null
                : IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: onOpenList,
                ),
        title: const Text('Local AI Remote'),
      ),
      body: Column(
        children: [
          const GatewayBanner(),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.forum_outlined,
                      size: 38,
                      color: Tone.faint,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Noch kein Chat',
                      style: TextStyle(fontSize: 16, color: Tone.ink),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Fragen gehen an die Modelle auf deinem Desktop — über '
                      'Tailscale, ohne Cloud dazwischen.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Tone.muted,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: () => startNewChat(ref),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Chat anlegen'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
