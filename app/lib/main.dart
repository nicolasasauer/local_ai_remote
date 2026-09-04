import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/data/chat_store.dart';
import 'src/state/providers.dart';
import 'src/theme.dart';
import 'src/ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  // Öffnet die Datenbank und setzt dabei alle beim letzten Beenden noch
  // laufenden Antworten auf "unterbrochen" — halbe Antworten bleiben sichtbar,
  // statt als hängender Stream weiterzugelten.
  final store = await ChatStore.open();

  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        storeProvider.overrideWithValue(store),
      ],
      child: const LocalAiRemoteApp(),
    ),
  );
}

class LocalAiRemoteApp extends StatelessWidget {
  const LocalAiRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local AI Remote',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const AppShell(),
    );
  }
}
