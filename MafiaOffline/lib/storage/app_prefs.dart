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

  static const _kAutoStartNight = 'auto_start_first_night';

  /// Начинать первую ночь автоматически, когда все прочитали роль.
  ///
  /// По умолчанию да: это снимает с ведущего лишний шаг и не даёт начать
  /// ночь «мимо» читающих. Опытные столы, которые читают роли за 5 секунд,
  /// могут выключить — тогда ведущий нажимает «Начать ночь» сам, когда
  /// увидит, что все готовы. Гейт (ночь не стартует до 100%) не отключается
  /// ни в каком случае.
  static Future<bool> autoStartFirstNight() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kAutoStartNight) ?? true;
  }

  static Future<void> setAutoStartFirstNight(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kAutoStartNight, v);
  }

  static const _kKeepScreenOn = 'keep_screen_on';

  /// Держать экран ведущего включённым (по умолчанию да).
  static Future<bool> keepScreenOn() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kKeepScreenOn) ?? true;
  }

  static Future<void> setKeepScreenOn(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kKeepScreenOn, v);
  }
}
