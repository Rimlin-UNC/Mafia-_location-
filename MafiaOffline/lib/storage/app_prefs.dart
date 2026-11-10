import 'package:shared_preferences/shared_preferences.dart';

/// Мелкие настройки приложения, не относящиеся к звуку или партии.
class AppPrefs {
  static const _kPlayerMode = 'player_mode_visible';

  /// Показывать ли в главном меню кнопку «Я игрок».
  ///
  /// По умолчанию выключено: основной сценарий — игроки заходят через
  /// браузер по QR-коду, приложение нужно только ведущему. Кнопка остаётся
  /// как запасной путь, если у кого-то браузер повёл себя странно.
  static Future<bool> playerModeVisible() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kPlayerMode) ?? false;
  }

  static Future<void> setPlayerModeVisible(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kPlayerMode, v);
  }
}
