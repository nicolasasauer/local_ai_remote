import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../chat/chat_controller.dart';
import '../data/chat_store.dart';
import '../data/gateway_client.dart';
import '../models/chat.dart';
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
    yield const ModelsSnapshot(gatewayError: 'Keine Gateway-Adresse gesetzt');
    return;
  }

  while (true) {
    try {
      yield await client.models();
    } catch (e) {
      yield ModelsSnapshot(gatewayError: '$e');
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
}

final chatListProvider =
    StateNotifierProvider<ChatListController, List<Chat>>(
        (ref) => ChatListController(ref.watch(storeProvider)));

final activeChatIdProvider = StateProvider<String?>((ref) => null);

/// Ein Controller pro Chat. Die Modellliste wird hineingereicht, damit der
/// Controller Kontextgrenze und Ladezustand kennt, ohne selbst zu pollen.
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

final calibrationsProvider =
    FutureProvider<Map<String, ModelCalibration>>((ref) async =>
        ref.watch(storeProvider).calibrations());
