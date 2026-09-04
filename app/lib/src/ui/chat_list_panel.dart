import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'format.dart';

class ChatListPanel extends ConsumerWidget {
  const ChatListPanel({this.onSelected, super.key});

  /// Wird auf schmalen Layouts gebraucht, um den Drawer zu schließen.
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatListProvider);
    final activeId = ref.watch(activeChatIdProvider);

    return Container(
      color: Tone.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 10, 10),
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
                  IconButton(
                    tooltip: 'Neuer Chat',
                    icon: const Icon(Icons.add),
                    onPressed: () async {
                      // Das zuletzt benutzte Modell übernehmen, damit man nicht
                      // bei jedem neuen Chat neu auswählen muss.
                      final last = chats
                          .map((c) => c.model)
                          .whereType<dynamic>()
                          .cast<dynamic>()
                          .firstOrNull;
                      final chat = await ref
                          .read(chatListProvider.notifier)
                          .create(model: last);
                      ref.read(activeChatIdProvider.notifier).state = chat.id;
                      onSelected?.call();
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: chats.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(18),
                      child: Text(
                        'Noch keine Chats.',
                        style: TextStyle(fontSize: 12.5, color: Tone.faint),
                      ),
                    )
                  : ListView.builder(
                      itemCount: chats.length,
                      itemBuilder: (context, i) => _ChatRow(
                        chat: chats[i],
                        active: chats[i].id == activeId,
                        onTap: () {
                          ref.read(activeChatIdProvider.notifier).state =
                              chats[i].id;
                          onSelected?.call();
                        },
                        onDelete: () => ref
                            .read(chatListProvider.notifier)
                            .delete(chats[i].id),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.chat,
    required this.active,
    required this.onTap,
    required this.onDelete,
  });

  final Chat chat;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onDelete,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        color: active ? Tone.raised : null,
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
                      color: active ? Tone.ink : Tone.ink.withValues(alpha: 0.85),
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        formatAgo(DateTime.now().difference(chat.updatedAt)),
                        style: const TextStyle(fontSize: 11, color: Tone.faint),
                      ),
                      if (chat.model != null) ...[
                        const Text(' · ',
                            style: TextStyle(fontSize: 11, color: Tone.faint)),
                        Flexible(
                          child: Text(
                            chat.model!.id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontSize: 11, color: Tone.faint),
                          ),
                        ),
                      ],
                      if (chat.compressionEnabled) ...[
                        const SizedBox(width: 5),
                        const Icon(Icons.compress, size: 11, color: Tone.violet),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
