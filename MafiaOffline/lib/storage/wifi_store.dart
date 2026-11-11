import 'package:shared_preferences/shared_preferences.dart';

/// Тип защиты Wi-Fi — то, что подставляется в QR-код стандарта WIFI:.
enum WifiSecurity {
  wpa('WPA', 'WPA/WPA2/WPA3'),
  wep('WEP', 'WEP (устаревший)'),
  open('nopass', 'Без пароля');

  const WifiSecurity(this.wire, this.label);

  /// Значение поля T: в QR-коде.
  final String wire;
  final String label;

  static WifiSecurity fromWire(String? v) =>
      WifiSecurity.values.firstWhere((e) => e.wire == v,
          orElse: () => WifiSecurity.wpa);
}

/// Данные точки доступа ведущего.
///
/// Нужны для первого QR-кода: игрок наводит камеру и телефон сам
/// подключается к сети — не надо диктовать пароль вслух каждому.
class WifiConfig {
  final String ssid;
  final String password;
  final WifiSecurity security;

  /// Скрытая сеть (не вещает своё имя). Камера должна знать об этом,
  /// иначе подключение молча не сработает.
  final bool hidden;

  const WifiConfig({
    this.ssid = '',
    this.password = '',
    this.security = WifiSecurity.wpa,
    this.hidden = false,
  });

  /// Заполнено ли достаточно, чтобы показывать Wi-Fi QR.
  /// Открытой сети пароль не нужен, защищённой — обязателен.
  bool get isUsable =>
      ssid.trim().isNotEmpty &&
      (security == WifiSecurity.open || password.isNotEmpty);

  WifiConfig copyWith({
    String? ssid,
    String? password,
    WifiSecurity? security,
    bool? hidden,
  }) =>
      WifiConfig(
        ssid: ssid ?? this.ssid,
        password: password ?? this.password,
        security: security ?? this.security,
        hidden: hidden ?? this.hidden,
      );

  /// Строка для QR-кода по формату, который понимают камеры Android и iOS.
  ///
  /// Формат: `WIFI:T:WPA;S:имя;P:пароль;H:false;;`
  /// Спецсимволы `\ ; , : "` внутри имени и пароля обязаны экранироваться
  /// обратным слешем — иначе точка с запятой в пароле разорвёт строку
  /// и телефон прочитает мусор.
  ///
  /// [game] — необязательное поле `G:` «единого кода» (см. `JoinCode`):
  /// номер игры и адрес ведущего. Оно всегда идёт ПОСЛЕДНИМ, после
  /// стандартных полей: разборщики вроде ZXing ищут `S:` / `P:` / `T:`
  /// по первому вхождению в строке, и чужое поле не должно их опередить.
  /// Камера телефона неизвестное поле пропускает и видит обычную сеть.
  String toQrPayload({String? game}) {
    final s = _escape(ssid);
    final p = security == WifiSecurity.open ? '' : _escape(password);
    final buf = StringBuffer('WIFI:T:${security.wire};S:$s;');
    if (p.isNotEmpty) buf.write('P:$p;');
    if (hidden) buf.write('H:true;');
    if (game != null && game.isNotEmpty) buf.write('G:${_escape(game)};');
    buf.write(';');
    return buf.toString();
  }

  static String _escape(String v) {
    final out = StringBuffer();
    for (final ch in v.split('')) {
      if (ch == '\\' || ch == ';' || ch == ',' || ch == ':' || ch == '"') {
        out.write('\\');
      }
      out.write(ch);
    }
    return out.toString();
  }
}

/// Хранение параметров Wi-Fi между запусками.
///
/// Пароль лежит в обычных настройках приложения — это осознанный компромисс:
/// он и так показывается на экране в виде QR-кода всему столу, секретом
/// не является. Шифровать нечего.
class WifiStore {
  static const _kSsid = 'wifi_ssid';
  static const _kPass = 'wifi_pass';
  static const _kSec = 'wifi_sec';
  static const _kHidden = 'wifi_hidden';

  /// Показывать ли Wi-Fi QR вообще. В кафе или дома с роутером
  /// ведущий может не знать пароль — тогда шаг просто скрыт.
  static const _kEnabled = 'wifi_qr_enabled';

  /// «Единый код»: в код сети добавляется номер игры. Включено по умолчанию;
  /// выключатель оставлен на случай, если чья-то камера не примет код
  /// с дополнительным полем.
  static const _kCombined = 'wifi_qr_combined';

  Future<WifiConfig> load() async {
    final p = await SharedPreferences.getInstance();
    return WifiConfig(
      ssid: p.getString(_kSsid) ?? '',
      password: p.getString(_kPass) ?? '',
      security: WifiSecurity.fromWire(p.getString(_kSec)),
      hidden: p.getBool(_kHidden) ?? false,
    );
  }

  Future<void> save(WifiConfig c) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSsid, c.ssid.trim());
    await p.setString(_kPass, c.password);
    await p.setString(_kSec, c.security.wire);
    await p.setBool(_kHidden, c.hidden);
  }

  Future<bool> isEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kEnabled) ?? true;
  }

  Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
  }

  Future<bool> isCombined() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kCombined) ?? true;
  }

  Future<void> setCombined(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kCombined, v);
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kSsid);
    await p.remove(_kPass);
    await p.remove(_kSec);
    await p.remove(_kHidden);
  }
}
