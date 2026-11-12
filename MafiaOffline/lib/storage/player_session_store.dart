import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Сохранённая сессия игрока — чтобы он не создавал новый профиль
/// при каждом заходе в приложение.
class PlayerSession {
  final String code;
  final String name;
  final String? playerId;
  final String? host;
  final int port;
  final int savedAt;

  const PlayerSession({
    required this.code,
    required this.name,
    this.playerId,
    this.host,
    this.port = 8088,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
        'playerId': playerId,
        'host': host,
        'port': port,
        'savedAt': savedAt,
      };

  static PlayerSession? fromJson(Map<String, dynamic> j) {
    final code = j['code'];
    final name = j['name'];
    if (code is! String || name is! String) return null;
    // Мягкое чтение остальных полей: сессия лежит в JSON на телефоне
    // игрока и могла быть записана прежней версией. Отказ одного поля не
    // повод терять вход в партию — важны только код и имя, они проверены
    // выше.
    return PlayerSession(
      code: code,
      name: name,
      playerId: j['playerId'] is String ? j['playerId'] as String : null,
      host: j['host'] is String ? j['host'] as String : null,
      port: j['port'] is int
          ? j['port'] as int
          : (j['port'] is num ? (j['port'] as num).toInt() : 8088),
      savedAt: j['savedAt'] is int
          ? j['savedAt'] as int
          : (j['savedAt'] is num ? (j['savedAt'] as num).toInt() : 0),
    );
  }
}

/// Хранит, что этот телефон уже вошёл в партию как игрок.
///
/// Без него игрок, вернувшийся на стартовый экран, снова видел форму
/// «введите имя» и заводил второй профиль — в списке у ведущего
/// появлялись дубли, а рабочим оставался только последний.
class PlayerSessionStore {
  static const _key = 'player_session_v1';

  /// Сессия живёт 6 часов — дольше партии в любом случае не длятся.
  static const _maxAge = Duration(hours: 6);

  Future<void> save(PlayerSession s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(s.toJson()));
    } catch (_) {
      // Сбой записи не должен мешать игре.
    }
  }

  Future<PlayerSession?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      final s = PlayerSession.fromJson(decoded);
      if (s == null) return null;

      final age = DateTime.now().millisecondsSinceEpoch - s.savedAt;
      if (age > _maxAge.inMilliseconds) {
        await clear();
        return null;
      }
      return s;
    } catch (_) {
      await clear();
      return null;
    }
  }

  Future<bool> has() async => (await load()) != null;

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
