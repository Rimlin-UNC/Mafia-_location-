import 'dart:convert';
import '../models/phase_timings.dart';
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

  // ---------- принятие оферты ----------

  static const _kOfferAccepted = 'offer_accepted_v1';

  /// Принял ли пользователь условия оферты **текущей** редакции.
  ///
  /// Сверяем не только факт отметки, но и номер редакции. Согласие даётся на
  /// конкретный текст, а не на любой, который появится позже: если условия
  /// переработали по существу, галочка должна быть спрошена заново.
  ///
  /// [currentVersion] — редакция, которую показывает приложение. Раньше здесь
  /// проверялся только флаг, и после смены редакции человек проскакивал по
  /// старой отметке: в веб-клиенте сверка была, в приложении — нет.
  static Future<bool> offerAccepted({String? currentVersion}) async {
    final p = await SharedPreferences.getInstance();
    if (!(p.getBool(_kOfferAccepted) ?? false)) return false;
    if (currentVersion == null) return true;
    // Отметка есть, но записанной редакции нет — это след старой версии
    // приложения, где номер не сохранялся. Такую отметку не засчитываем.
    return p.getString(_kOfferVersion) == currentVersion;
  }

  /// Сохраняет факт принятия: дату, время и номер редакции.
  ///
  /// Хранится только на устройстве и никуда не отправляется — программа
  /// работает офлайн. Смысл записи в том, чтобы при споре было чем
  /// подтвердить: условия приняты такого-то числа, в такой-то редакции.
  static Future<void> setOfferAccepted({String? offerVersion, String? playerName}) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kOfferAccepted, true);
    await p.setString(_kOfferAcceptedAt, DateTime.now().toIso8601String());
    if (offerVersion != null) await p.setString(_kOfferVersion, offerVersion);
    if (playerName != null && playerName.trim().isNotEmpty) {
      await p.setString(_kOfferName, playerName.trim());
    }
  }

  static const _kOfferAcceptedAt = 'offer_accepted_at';
  static const _kOfferVersion = 'offer_version';
  static const _kOfferName = 'offer_player_name';

  /// Когда принята оферта (ISO-8601), `null` — не принята.
  static Future<String?> offerAcceptedAt() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kOfferAcceptedAt);
  }

  /// Номер редакции, который был принят.
  static Future<String?> offerVersionAccepted() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kOfferVersion);
  }

  /// Имя, под которым принята оферта.
  static Future<String?> offerAcceptedName() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kOfferName);
  }

  /// Сбросить принятие (для тестов и для «показать условия снова»).
  static Future<void> resetOfferAccepted() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kOfferAccepted);
    await p.remove(_kOfferAcceptedAt);
    await p.remove(_kOfferVersion);
    await p.remove(_kOfferName);
  }

  // ---------- правила стола (v1.2.0) ----------

  static const _kOpenCards = 'rule_open_cards';
  static const _kIntroNight = 'rule_intro_night';
  static const _kLastWord = 'rule_last_word';
  static const _kPrivateCheck = 'rule_private_check';

  /// Правила стола, выбранные в прошлый раз.
  ///
  /// Компания играет по одним и тем же правилам из вечера в вечер.
  /// Заставлять ведущего каждый раз заново щёлкать четыре переключателя —
  /// верный способ однажды забыть один из них и узнать об этом на втором
  /// круге.
  static Future<TableRulePrefs> tableRules() async {
    final p = await SharedPreferences.getInstance();
    Object? timingData;
    try { timingData = jsonDecode(p.getString('rule_timings') ?? 'null'); } catch (_) {}
    return TableRulePrefs(
      timings: PhaseTimings.fromJson(timingData),
      piercingShot: p.getBool('rule_piercing_shot') ?? false,
      openCards: p.getBool(_kOpenCards) ?? false,
      introNight: p.getBool(_kIntroNight) ?? false,
      lastWord: p.getBool(_kLastWord) ?? true,
      privateCheck: p.getBool(_kPrivateCheck) ?? true,
    );
  }

  static Future<void> setTableRules(TableRulePrefs r) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('rule_timings', jsonEncode(r.timings.toJson()));
    await p.setBool('rule_piercing_shot', r.piercingShot);
    await p.setBool(_kOpenCards, r.openCards);
    await p.setBool(_kIntroNight, r.introNight);
    await p.setBool(_kLastWord, r.lastWord);
    await p.setBool(_kPrivateCheck, r.privateCheck);
  }
}

/// Четыре переключателя экрана создания партии.
class TableRulePrefs {
  final PhaseTimings timings;
  final bool piercingShot;
  final bool openCards;
  final bool introNight;
  final bool lastWord;
  final bool privateCheck;

  const TableRulePrefs({
    this.timings = const PhaseTimings(),
    this.piercingShot = false,
    this.openCards = false,
    this.introNight = false,
    this.lastWord = true,
    this.privateCheck = true,
  });
}
