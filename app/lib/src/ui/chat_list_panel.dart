import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'dialogs.dart';
import 'format.dart';

/// Legt einen Chat mit dem zuletzt benutzten Modell an und öffnet ihn.
Future<void> startNewChat(WidgetRef ref) async {
  final list = ref.read(chatListProvider.notifier);
  final chat = await list.create(model: list.lastModel);
  ref.read(activeChatIdProvider.notifier).state = chat.id;
}

/// Löscht nach Rückfrage. Ist es der offene Chat, rückt der nächste nach —
/// sonst stünde man vor einer leeren Seite, obwohl es weitere Chats gibt.
Future<void> deleteChatWithConfirm(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
) async {
  final ok = await confirm(
    context,
    title: 'Chat löschen?',
    body:
        '„${chat.title}" wird mit allen Nachrichten und Anhängen von diesem '
        'Gerät entfernt. Das lässt sich nicht zurücknehmen.',
    action: 'Löschen',
    destructive: true,
  );
  if (!ok) return;

  final wasActive = ref.read(activeChatIdProvider) == chat.id;
  await ref.read(chatListProvider.notifier).delete(chat.id);
  if (wasActive) {
    final rest = ref.read(chatListProvider);
    ref.read(activeChatIdProvider.notifier).state =
        rest.isEmpty ? null : rest.first.id;
  }
}

Future<void> renameChatWithDialog(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
) async {
  final name = await askText(
    context,
    title: 'Chat umbenennen',
    initial: chat.title,
  );
  if (name == null || name.trim().isEmpty) return;
  await ref.read(chatListProvider.notifier).rename(chat.id, name.trim());
}

class ChatListPanel extends ConsumerStatefulWidget {
  const ChatListPanel({this.onSelected, super.key});

  /// Wird auf schmalen Layouts gebraucht, um den Drawer zu schließen.
  final VoidCallback? onSelected;

  @override
  ConsumerState<ChatListPanel> createState() => _ChatListPanelState();
}

class _ChatListPanelState extends ConsumerState<ChatListPanel> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatListProvider);
    final activeId =
        ref.watch(activeChatIdProvider) ??
        (chats.isEmpty ? null : chats.first.id);

    final q = _query.trim().toLowerCase();
    final visible =
        q.isEmpty
            ? chats
            : chats
                .where(
                  (c) =>
                      c.title.toLowerCase().contains(q) ||
                      (c.model?.id.toLowerCase().contains(q) ?? false),
                )
                .toList();
    final groups = groupByAge(visible, DateTime.now());

    return Container(
      color: Tone.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Chats',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Tone.ink,
                      ),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      backgroundColor: Tone.teal.withValues(alpha: 0.14),
                      foregroundColor: Tone.teal,
                    ),
                    onPressed: () async {
                      await startNewChat(ref);
                      widget.onSelected?.call();
                    },
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('Neu', style: TextStyle(fontSize: 12.5)),
                  ),
                ],
              ),
            ),
            if (chats.length > 4)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Suchen',
                    hintStyle: const TextStyle(color: Tone.faint),
                    prefixIcon: const Icon(Icons.search, size: 17),
                    suffixIcon:
                        _query.isEmpty
                            ? null
                            : IconButton(
                              icon: const Icon(Icons.close, size: 16),
                              onPressed:
                                  () => setState(() {
                                    _search.clear();
                                    _query = '';
                                  }),
                            ),
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child:
                  chats.isEmpty
                      ? const _Hint('Noch keine Chats.')
                      : visible.isEmpty
                      ? _Hint('Nichts gefunden für „$_query".')
                      : ListView(
                        padding: const EdgeInsets.only(bottom: 12),
                        children: [
                          for (final group in groups) ...[
                            _GroupHeader(group.label),
                            for (final chat in group.chats)
                              _ChatRow(
                                chat: chat,
                                active: chat.id == activeId,
                                onTap: () {
                                  ref
                                      .read(activeChatIdProvider.notifier)
                                      .state = chat.id;
                                  widget.onSelected?.call();
                                },
                                onRename:
                                    () => renameChatWithDialog(
                                      context,
                                      ref,
                                      chat,
                                    ),
                                onDelete:
                                    () => deleteChatWithConfirm(
                                      context,
                                      ref,
                                      chat,
                                    ),
                              ),
                          ],
                        ],
                      ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatGroup {
  const ChatGroup(this.label, this.chats);
  final String label;
  final List<Chat> chats;
}

/// Teilt eine nach Aktualität sortierte Liste in Zeitabschnitte. Die
/// Reihenfolge innerhalb bleibt unangetastet.
List<ChatGroup> groupByAge(List<Chat> chats, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final week = today.subtract(const Duration(days: 7));
  final month = today.subtract(const Duration(days: 30));

  String bucket(DateTime t) {
    if (!t.isBefore(today)) return 'Heute';
    if (!t.isBefore(yesterday)) return 'Gestern';
    if (!t.isBefore(week)) return 'Letzte 7 Tage';
    if (!t.isBefore(month)) return 'Letzte 30 Tage';
    return 'Älter';
  }

  final groups = <ChatGroup>[];
  for (final chat in chats) {
    final label = bucket(chat.updatedAt);
    if (groups.isEmpty || groups.last.label != label) {
      groups.add(ChatGroup(label, [chat]));
    } else {
      groups.last.chats.add(chat);
    }
  }
  return groups;
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 10.5,
          letterSpacing: 0.8,
          color: Tone.faint,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12.5, color: Tone.faint),
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.chat,
    required this.active,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Chat chat;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: active ? Tone.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          // Langes Drücken öffnet dasselbe Menü wie der Knopf — früher hat es
          // ohne Rückfrage gelöscht.
          onLongPress: () => _openMenu(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          color:
                              active
                                  ? Tone.ink
                                  : Tone.ink.withValues(alpha: 0.85),
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Text(
                            formatAgo(
                              DateTime.now().difference(chat.updatedAt),
                            ),
                            style: const TextStyle(
                              fontSize: 11,
                              color: Tone.faint,
                            ),
                          ),
                          if (chat.model != null) ...[
                            const Text(
                              ' · ',
                              style: TextStyle(fontSize: 11, color: Tone.faint),
                            ),
                            Flexible(
                              child: Text(
                                chat.model!.id,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Tone.faint,
                                ),
                              ),
                            ),
                          ],
                          if (chat.researchEnabled) ...[
                            const SizedBox(width: 5),
                            const Icon(
                              Icons.travel_explore,
                              size: 11,
                              color: Tone.amber,
                            ),
                          ],
                          if (chat.compressionEnabled) ...[
                            const SizedBox(width: 5),
                            const Icon(
                              Icons.compress,
                              size: 11,
                              color: Tone.violet,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                _RowMenu(onRename: onRename, onDelete: onDelete),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(
      Offset(box.size.width - 40, 0),
      ancestor: overlay,
    );
    final value = await showMenu<String>(
      context: context,
      color: Tone.raised,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy,
        overlay.size.width - origin.dx,
        overlay.size.height - origin.dy,
      ),
      items: _RowMenu.items,
    );
    if (value == 'rename') onRename();
    if (value == 'delete') onDelete();
  }
}

class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.onRename, required this.onDelete});

  final VoidCallback onRename;
  final VoidCallback onDelete;

  static const items = [
    PopupMenuItem(
      value: 'rename',
      child: ListTile(
        dense: true,
        leading: Icon(Icons.edit_outlined, size: 18),
        title: Text('Umbenennen'),
      ),
    ),
    PopupMenuItem(
      value: 'delete',
      child: ListTile(
        dense: true,
        leading: Icon(Icons.delete_outline, size: 18, color: Tone.alert),
        title: Text('Löschen', style: TextStyle(color: Tone.alert)),
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Mehr',
      color: Tone.raised,
      icon: const Icon(Icons.more_vert, size: 17, color: Tone.faint),
      onSelected: (v) => v == 'rename' ? onRename() : onDelete(),
      itemBuilder: (_) => items,
    );
  }
}
