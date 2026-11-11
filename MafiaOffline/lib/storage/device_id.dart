import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Постоянный идентификатор устройства.
///
/// Нужен ровно для одного: отличить «человек вернулся со второго телефона»
/// от «кто-то ввёл то же имя». Без него сервер не может решить, чей слот
/// настоящий, и вытесняет того, кто пришёл позже.
///
/// Это **не** аппаратный ID и не рекламный идентификатор: случайная строка,
/// сгенерированная один раз и лежащая в обычных настройках приложения.
/// Никуда не уходит за пределы локальной сети, удаляется вместе с данными
/// приложения (NFR-10: данные не покидают устройства).
class DeviceId {
  static const _key = 'device_id_v1';
  static String? _cached;

  static Future<String> get() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_key);
    if (id == null || id.length < 8) {
      id = _generate();
      await prefs.setString(_key, id);
    }
    _cached = id;
    return id;
  }

  /// Синхронная версия для тестов и для случаев, когда ждать нельзя.
  static String? get cached => _cached;

  static String _generate() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(12, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Только для тестов: подменить значение, не трогая настройки.
  static void overrideForTests(String? value) => _cached = value;
}
