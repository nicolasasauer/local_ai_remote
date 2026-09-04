import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme.dart';
import 'chat_list_panel.dart';
import 'chat_page.dart';
import 'models_page.dart';
import 'settings_page.dart';
import 'telemetry_page.dart';

/// Ab 900 px feste Chatspalte (Windows), darunter Drawer (Android). Dasselbe
/// Panel-Widget, nur anders montiert.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final chats = ref.watch(chatListProvider);
    final activeId = ref.watch(activeChatIdProvider);
    final active = chats.where((c) => c.id == activeId).firstOrNull ??
        (chats.isEmpty ? null : chats.first);

    final destinations = const [
      (Icons.forum_outlined, Icons.forum, 'Chat'),
      (Icons.memory_outlined, Icons.memory, 'Modelle'),
      (Icons.speed_outlined, Icons.speed, 'System'),
      (Icons.settings_outlined, Icons.settings, 'Einstellungen'),
    ];

    Widget page() => switch (_index) {
          1 => const ModelsPage(),
          2 => const TelemetryPage(),
          3 => const SettingsPage(),
          _ => active == null
              ? const _NoChat()
              : ChatPage(
                  key: ValueKey(active.id),
                  chat: active,
                  onOpenList:
                      wide ? null : () => _scaffoldKey.currentState?.openDrawer(),
                ),
        };

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in destinations)
                  NavigationRailDestination(
                    icon: Icon(d.$1),
                    selectedIcon: Icon(d.$2),
                    label: Text(d.$3),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            if (_index == 0) ...[
              const SizedBox(width: 268, child: ChatListPanel()),
              const VerticalDivider(width: 1),
            ],
            Expanded(child: page()),
          ],
        ),
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      drawer: _index == 0
          ? Drawer(
              backgroundColor: Tone.surface,
              child: ChatListPanel(
                onSelected: () => Navigator.of(context).pop(),
              ),
            )
          : null,
      body: page(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in destinations)
            NavigationDestination(
              icon: Icon(d.$1),
              selectedIcon: Icon(d.$2),
              label: d.$3,
            ),
        ],
      ),
    );
  }
}

class _NoChat extends ConsumerWidget {
  const _NoChat();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.forum_outlined, size: 34, color: Tone.faint),
            const SizedBox(height: 14),
            const Text(
              'Noch kein Chat',
              style: TextStyle(fontSize: 15, color: Tone.ink),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                final chat = await ref.read(chatListProvider.notifier).create();
                ref.read(activeChatIdProvider.notifier).state = chat.id;
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Chat anlegen'),
            ),
          ],
        ),
      ),
    );
  }
}
