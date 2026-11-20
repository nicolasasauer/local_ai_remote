import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../chat/chat_controller.dart';
import '../data/chat_store.dart';
import '../data/gateway_client.dart';
import '../models/chat.dart';
import '../models/load_settings.dart';
import '../models/model_entry.dart';
import '../models/telemetry.dart';

/// Beides wird in main() überschrieben, damit der Rest der App synchron
/// darauf zugreifen kann.
final prefsProvider = Provider<SharedPreferences>(
    (ref) => throw UnimplementedError('prefsProvider nicht überschrieben'));

final storeProvider = Provider<ChatStore>(
    (ref) => throw UnimplementedError('storeProvider nicht überschrieben'));

// --- Einstellungen ---------------------------------------------------------

class GatewaySettings {
  const GatewaySettings({this.baseUrl = '', this.token = ''});

  final String baseUrl;
  final String token;

  bool get isConfigured => baseUrl.trim().isNotEmpty;
}

class SettingsController extends StateNotifier<GatewaySettings> {
  SettingsController(this._prefs)
      : super(GatewaySettings(
          baseUrl: _prefs.getString(_urlKey) ?? '',
          token: _prefs.getString(_tokenKey) ?? '',
        ));

  static const _urlKey = 'gateway_url';
  static const _tokenKey = 'gateway_token';

  final SharedPreferences _prefs;

  Future<void> save({String? baseUrl, String? token}) async {
    final next = GatewaySettings(
      baseUrl: (baseUrl ?? state.baseUrl).trim(),
      token: (token ?? state.token).trim(),
    );
    await _prefs.setString(_urlKey, next.baseUrl);
    await _prefs.setString(_tokenKey, next.token);
    state = next;
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsController, GatewaySettings>(
        (ref) => SettingsController(ref.watch(prefsProvider)));

final gatewayClientProvider = Provider<GatewayClient>((ref) {
  final settings = ref.watch(settingsProvider);
  final client =
      GatewayClient(baseUrl: settings.baseUrl, token: settings.token);
  ref.onDispose(client.close);
  return client;
});

// --- Modelle ---------------------------------------------------------------

/// Pollt die Modellliste. Ein Fehler beendet den Stream nicht, sondern wird
/// als Zustand ausgeliefert — sonst verschwindet die Liste bei jedem Aussetzer.
final modelsProvider = StreamProvider<ModelsSnapshot>((ref) async* {
  final client = ref.watch(gatewayClientProvider);
  if (!client.isConfigured) {
    yield const ModelsSnapshot(
      gatewayError: 'Keine Gateway-Adresse gesetzt',
      gatewayErrorCause: GatewayNotConfigured(),
    );
    return;
  }

  while (true) {
    try {
      yield await client.models();
    } catch (e) {
      yield ModelsSnapshot(gatewayError: '$e', gatewayErrorCause: e);
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
});

final healthProvider = FutureProvider<GatewayHealth>((ref) {
  // Hängt am Polling, damit ein Reconnect auch die Health-Anzeige auffrischt.
  ref.watch(modelsProvider);
  return ref.watch(gatewayClientProvider).health();
});

// --- Telemetrie ------------------------------------------------------------

/// Hält den Verlauf und regelt die Wiederverbindung. Bei Abriss bleibt der
/// letzte Stand sichtbar, aber als veraltet markiert.
class TelemetryController extends StateNotifier<TelemetryFeed> {
  TelemetryController(this._client) : super(const TelemetryFeed()) {
    if (_client.isConfigured) _connect();
  }

  final GatewayClient _client;
  StreamSubscription<TelemetrySample>? _subscription;
  Timer? _retry;
  int _attempt = 0;

  static const _backoff = [1, 2, 5, 10, 20, 30];

  void _connect() {
    _retry?.cancel();
    try {
      _subscription = _client.telemetry().listen(
            (sample) {
              _attempt = 0;
              state = state.append(sample);
            },
            onError: (Object e) => _scheduleRetry('$e'),
            onDone: () => _scheduleRetry('Verbindung vom Gateway geschlossen'),
            cancelOnError: true,
          );
    } catch (e) {
      _scheduleRetry('$e');
    }
  }

  void _scheduleRetry(String reason) {
    _subscription?.cancel();
    _subscription = null;
    final seconds = _backoff[_attempt.clamp(0, _backoff.length - 1)];
    _attempt++;
    state = state.disconnected(reason, Duration(seconds: seconds));
    _retry = Timer(Duration(seconds: seconds), _connect);
  }

  /// Manueller Versuch, etwa nach dem Aufwecken des Desktops.
  void reconnectNow() {
    _attempt = 0;
    _subscription?.cancel();
    _connect();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _retry?.cancel();
    super.dispose();
  }
}

final telemetryProvider =
    StateNotifierProvider<TelemetryController, TelemetryFeed>(
        (ref) => TelemetryController(ref.watch(gatewayClientProvider)));

// --- Chats -----------------------------------------------------------------

class ChatListController extends StateNotifier<List<Chat>> {
  ChatListController(this._store) : super(const []) {
    refresh();
  }

  final ChatStore _store;
  static const _uuid = Uuid();

  Future<void> refresh() async => state = await _store.listChats();

  Future<Chat> create({ModelRef? model}) async {
    final now = DateTime.now();
    final chat = Chat(
      id: _uuid.v4(),
      title: 'Neuer Chat',
      createdAt: now,
      updatedAt: now,
      model: model,
    );
    await _store.upsertChat(chat);
    await refresh();
    return chat;
  }

  Future<void> delete(String id) async {
    await _store.deleteChat(id);
    await refresh();
  }

  Future<void> rename(String id, String title) async {
    final chat = state.where((c) => c.id == id).firstOrNull;
    if (chat == null) return;
    await _store.upsertChat(
        chat.copyWith(title: title, updatedAt: DateTime.now()));
    await refresh();
  }

  /// Das zuletzt benutzte Modell — damit ein neuer Chat nicht jedes Mal
  /// eine Auswahl verlangt. Die Liste ist nach `updated_at` sortiert.
  ModelRef? get lastModel => state.map((c) => c.model).nonNulls.firstOrNull;
}

final chatListProvider =
    StateNotifierProvider<ChatListController, List<Chat>>(
        (ref) => ChatListController(ref.watch(storeProvider)));

/// Der offene Chat. Überlebt einen Neustart: wer die App aus dem Speicher
/// geworfen bekommt, will danach im selben Gespräch weitermachen.
final activeChatIdProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(prefsProvider);
  ref.listenSelf((_, next) {
    if (next == null) {
      prefs.remove(_activeChatKey);
    } else {
      prefs.setString(_activeChatKey, next);
    }
  });
  return prefs.getString(_activeChatKey);
});

const _activeChatKey = 'active_chat';

/// Gewählter Bereich der Navigation. Ein Provider statt lokalem Zustand,
/// damit etwa der Verbindungshinweis im Chat direkt in die Einstellungen
/// springen kann.
enum ShellTab { chat, models, system, settings }

final shellTabProvider = StateProvider<ShellTab>((ref) => ShellTab.chat);

/// Ein Controller pro Chat. Modellliste und Kalibrierung werden **nachgereicht**
/// statt mit `watch` gelesen: ein FutureProvider wechselt von `loading` auf
/// `data`, und jedes `watch` darauf würde den Controller mitten im Stream
/// wegwerfen — die laufende Antwort stirbt dann ohne erkennbaren Grund.
final chatControllerProvider =
    StateNotifierProvider.family<ChatController, ChatSession, Chat>(
        (ref, chat) {
  final controller = ChatController(
    chat: chat,
    store: ref.watch(storeProvider),
    client: ref.watch(gatewayClientProvider),
    calibrations: const {},
    loadFor: (model) => ref.read(loadSettingsProvider.notifier).forModel(model),
  );

  ref.listen<AsyncValue<Map<String, ModelCalibration>>>(calibrationsProvider,
      (_, next) {
    final value = next.valueOrNull;
    if (value != null) controller.applyCalibrations(value);
  }, fireImmediately: true);

  ref.listen<AsyncValue<ModelsSnapshot>>(modelsProvider, (_, next) {
    final snapshot = next.valueOrNull;
    if (snapshot != null) controller.applyModels(snapshot);
  }, fireImmediately: true);

  return controller;
});

// --- Ladeoptionen und Downloads --------------------------------------------

/// Ladeoptionen pro Modell, auf dem Gerät gespeichert. Das Gateway merkt sich
/// nichts davon: es bekommt die Optionen mit jeder Anfrage.
class LoadSettingsController extends StateNotifier<Map<String, LoadSettings>> {
  LoadSettingsController(this._prefs) : super(_read(_prefs));

  static const _key = 'load_settings';
  final SharedPreferences _prefs;

  static String keyOf(ModelRef ref) => '${ref.backend.wire}|${ref.id}';

  static Map<String, LoadSettings> _read(SharedPreferences prefs) {
    try {
      final raw = jsonDecode(prefs.getString(_key) ?? '{}') as Map;
      return {
        for (final e in raw.entries)
          if (e.value is Map<String, dynamic>)
            e.key as String: LoadSettings.fromJson(e.value as Map<String, dynamic>),
      };
    } catch (_) {
      return const {};
    }
  }

  LoadSettings forModel(ModelRef ref) =>
      state[keyOf(ref)] ?? LoadSettings.standard;

  Future<void> set(ModelRef ref, LoadSettings value) async {
    final next = {...state};
    if (value.isDefault) {
      next.remove(keyOf(ref));
    } else {
      next[keyOf(ref)] = value;
    }
    state = next;
    await _prefs.setString(
        _key, jsonEncode({for (final e in next.entries) e.key: e.value.toJson()}));
  }
}

final loadSettingsProvider =
    StateNotifierProvider<LoadSettingsController, Map<String, LoadSettings>>(
        (ref) => LoadSettingsController(ref.watch(prefsProvider)));

/// Laufende und kürzlich beendete Downloads. Pollt nur, solange jemand
/// zusieht (autoDispose), und schneller, solange etwas läuft.
final pullsProvider = StreamProvider.autoDispose<PullsSnapshot>((ref) async* {
  final client = ref.watch(gatewayClientProvider);
  if (!client.isConfigured) {
    yield const PullsSnapshot();
    return;
  }
  var lief = false;
  while (true) {
    var naechste = const Duration(seconds: 10);
    try {
      final snap = await client.pulls();
      yield snap;
      // Ein Download ist gerade fertig geworden: die Modellliste soll das
      // neue Modell zeigen, ohne auf ihre nächste Runde zu warten.
      if (lief && !snap.anyRunning) ref.invalidate(modelsProvider);
      lief = snap.anyRunning;
      if (lief) naechste = const Duration(seconds: 1);
    } catch (_) {
      // Ältere Gateways kennen die Route nicht — dann gibt es eben keine
      // Downloads, statt eines Fehlers auf der Modellseite.
      yield const PullsSnapshot();
    }
    await Future<void>.delayed(naechste);
  }
});

final calibrationsProvider =
    FutureProvider<Map<String, ModelCalibration>>((ref) async =>
        ref.watch(storeProvider).calibrations());
