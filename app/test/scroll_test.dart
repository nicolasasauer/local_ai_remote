import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_remote/main.dart';
import 'package:local_ai_remote/src/data/chat_store.dart';
import 'package:local_ai_remote/src/data/gateway_client.dart';
import 'package:local_ai_remote/src/models/chat.dart';
import 'package:local_ai_remote/src/models/model_entry.dart';
import 'package:local_ai_remote/src/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Gateway, dessen Stream der Test selbst füttert.
class _FakeGateway extends GatewayClient {
  _FakeGateway() : super(baseUrl: '', token: '');

  final events = StreamController<ChatEvent>();

  @override
  Stream<ChatEvent> streamChat({
    required ModelRef ref,
    required List<Map<String, dynamic>> messages,
    double? temperature,
    bool research = false,
  }) =>
      events.stream;
}

/// Das gemeldete Verhalten der alten Version: während des Streams sprang
/// der Verlauf bei jedem Token ans Ende, und eine Wischgeste nach oben
/// wurde sofort wieder abgewürgt.
void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('Scrollen während des Denkens bleibt, wo der Finger es hinlegt',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'gateway_url': 'https://x.invalid', 'active_chat': 'c'});
    final prefs = await SharedPreferences.getInstance();
    final gateway = _FakeGateway();
    late ChatStore store;

    await tester.runAsync(() async {
      store = await ChatStore.open(path: inMemoryDatabasePath);
      final t = DateTime(2026, 1, 1);
      await store.upsertChat(Chat(
        id: 'c',
        title: 'Lang',
        createdAt: t,
        updatedAt: t,
        model: const ModelRef(BackendId.ollama, 'qwen3:8b'),
      ));
      for (var i = 0; i < 20; i++) {
        await store.insertMessage(ChatMessage(
          id: 'm$i',
          chatId: 'c',
          role: i.isEven ? MessageRole.user : MessageRole.assistant,
          content: 'Nachricht $i\n\n${'Füllzeile. ' * 30}',
          status: MessageStatus.complete,
          createdAt: t.add(Duration(minutes: i)),
        ));
      }
    });

    await tester.binding.setSurfaceSize(const Size(420, 860));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        storeProvider.overrideWithValue(store),
        gatewayClientProvider.overrideWithValue(gateway),
        modelsProvider.overrideWith(
            (ref) => Stream.value(const ModelsSnapshot())),
      ],
      child: const LocalAiRemoteApp(),
    ));

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 30));
      }
    }

    await settle();

    ScrollPosition position() => tester
        .state<ScrollableState>(find.descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable)).first)
        .position;

    await tester.enterText(find.byType(TextField).last, 'Denk nach');
    await tester.pump();
    await tester.tap(find.byTooltip('Senden'));
    await settle();

    gateway.events.add(const ChatAccepted());
    Future<void> think(int n) async {
      for (var i = 0; i < n; i++) {
        gateway.events.add(ChatReasoning('Gedanke $i. ${'Überlegung ' * 8}\n'));
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await think(10);
    expect(position().pixels, closeTo(position().maxScrollExtent, 1),
        reason: 'ohne Eingriff läuft der Verlauf mit');

    // Finger auf den Verlauf, nach unten ziehen (= nach oben scrollen) und
    // dabei weiter streamen lassen — wie beim Lesen während des Denkens.
    final center = tester.getCenter(find.byType(ListView));
    final gesture = await tester.startGesture(center);
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 60));
      gateway.events.add(ChatReasoning('Noch ein Gedanke $i.\n'));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    // Kein pumpAndSettle: der Statuspunkt pulsiert, solange der Lauf läuft.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final readingAt = position().pixels;
    expect(position().maxScrollExtent - readingAt, greaterThan(300),
        reason: 'die Geste darf nicht abgewürgt werden');

    await think(15);
    expect(position().pixels, closeTo(readingAt, 1),
        reason: 'wer liest, wird nicht nach unten gerissen');
    expect(find.byTooltip('Zum Ende'), findsOneWidget);

    await tester.tap(find.byTooltip('Zum Ende'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await think(5);
    expect(position().pixels, closeTo(position().maxScrollExtent, 1),
        reason: 'nach "Zum Ende" läuft er wieder mit');

    gateway.events.add(const ChatDone(null));
    await settle();
    await tester.pumpWidget(const SizedBox());
    await settle();
    await tester.runAsync(store.close);
  });
}
