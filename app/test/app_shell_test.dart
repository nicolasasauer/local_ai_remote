import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_remote/main.dart';
import 'package:local_ai_remote/src/data/chat_store.dart';
import 'package:local_ai_remote/src/data/gateway_client.dart';
import 'package:local_ai_remote/src/models/model_entry.dart';
import 'package:local_ai_remote/src/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Die Oberfläche als Ganzes: erster Start ohne Gateway, Chat anlegen,
/// löschen nur nach Rückfrage.
void main() {
  late ChatStore store;

  setUpAll(sqfliteFfiInit);

  Future<void> starte(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    await tester.runAsync(() async {
      store = await ChatStore.open(path: inMemoryDatabasePath);
    });
    await tester.binding.setSurfaceSize(const Size(420, 860));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(p),
          storeProvider.overrideWithValue(store),
          // Kein Netz im Test: das Gateway gilt als nicht erreichbar.
          gatewayClientProvider.overrideWithValue(
            GatewayClient(baseUrl: '', token: ''),
          ),
          if (prefs.containsKey('gateway_url'))
            modelsProvider.overrideWith(
              (ref) => Stream.value(
                const ModelsSnapshot(
                  gatewayError: 'Connection refused',
                  gatewayErrorCause: SocketException('Connection refused'),
                ),
              ),
            ),
        ],
        child: const LocalAiRemoteApp(),
      ),
    );
    await tester.pump();
  }

  /// Datenbankzugriffe laufen echt asynchron; die Testuhr allein bewegt sie
  /// nicht.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  tearDown(() async {
    await store.close();
  });

  testWidgets('erster Start führt in die Einstellungen', (tester) async {
    await starte(tester);
    await settle(tester);
    expect(find.text('Speichern und verbinden'), findsOneWidget);
  });

  testWidgets(
    'Chat anlegen, Hinweis auf fehlendes Gateway, Löschen mit Rückfrage',
    (tester) async {
      await starte(tester, prefs: {'gateway_url': 'https://x.invalid'});
      await settle(tester);

      expect(find.text('Noch kein Chat'), findsOneWidget);
      expect(find.textContaining('nicht erreichbar'), findsOneWidget);
      await tester.tap(find.text('Chat anlegen'));
      await settle(tester);

      // Leerer Chat ohne Modell bietet die Auswahl an.
      expect(find.text('Modell wählen'), findsOneWidget);
      expect(find.text('Zuerst oben ein Modell wählen'), findsOneWidget);

      // Löschen fragt nach und lässt sich abbrechen.
      await tester.tap(find.byTooltip('Mehr').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat löschen'));
      await tester.pumpAndSettle();
      expect(find.text('Chat löschen?'), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await settle(tester);
      expect(find.text('Noch kein Chat'), findsNothing);

      await tester.tap(find.byTooltip('Mehr').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat löschen'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
      await settle(tester);
      expect(find.text('Noch kein Chat'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    },
  );
}
