import '../core/constants.dart';
import '../storage/wifi_store.dart';

/// Результат сканирования QR-кода ведущего.
class ScannedGame {
  final String code;
  final String? host;
  final int port;

  /// Сеть ведущего — есть только в «едином коде». По ней приложение само
  /// подключает телефон к Wi-Fi, прежде чем входить в игру.
  final WifiConfig? wifi;

  const ScannedGame({
    required this.code,
    this.host,
    this.port = Net.gamePort,
    this.wifi,
  });

  static final _six = RegExp(r'^\d{6}$');

  /// Разбор строки QR. Понимаем единый код, полный адрес и просто шесть цифр.
  static ScannedGame? tryParse(String raw) {
    final value = raw.trim();

    // Код сети разбираем первым и отдельно: в пароле Wi-Fi легко найдутся
    // шесть цифр подряд, и общий поиск ниже принял бы их за номер игры.
    if (JoinCode.looksLikeWifi(value)) {
      final join = JoinCode.parse(value);
      final code = join?.code;
      if (join == null || code == null) return null;
      return ScannedGame(code: code, host: join.host, wifi: join.wifi);
    }

    final uri = Uri.tryParse(value);

    if (uri != null) {
      // Формат ссылки: http://IP:PORT/?g=482913
      final q = uri.queryParameters['g'];
      if (q != null && _six.hasMatch(q)) {
        return ScannedGame(
          code: q,
          host: uri.host.isEmpty ? null : uri.host,
          port: uri.hasPort ? uri.port : Net.gamePort,
        );
      }
      // Старый формат: mafia://IP:PORT/482913
      if (uri.scheme == 'mafia' && uri.pathSegments.isNotEmpty) {
        final code = uri.pathSegments.last;
        if (_six.hasMatch(code)) {
          return ScannedGame(
            code: code,
            host: uri.host.isEmpty ? null : uri.host,
            port: uri.hasPort ? uri.port : Net.gamePort,
          );
        }
      }
    }

    if (_six.hasMatch(value)) return ScannedGame(code: value);

    final m = RegExp(r'\b(\d{6})\b').firstMatch(value);
    if (m != null) return ScannedGame(code: m.group(1)!);

    return null;
  }
}

/// «Единый код»: сеть Wi-Fi и вход в игру в одном QR.
///
/// Это обычный код сети `WIFI:…;;` с одним дополнительным полем:
///
///     WIFI:T:WPA;S:Mafia-Host;P:game2024;G:482913@192.168.43.1;;
///
/// * Камера телефона поле `G:` не знает, пропускает его и предлагает
///   подключиться к сети — как и с обычным кодом Wi-Fi.
/// * Сканер приложения читает всё: подключает телефон к сети и сразу
///   входит в игру `482913` по адресу `192.168.43.1`.
///
/// Почему не ссылка: один QR несёт одну строку, а камера делает с ней одно
/// действие — либо подключает к сети, либо открывает адрес. Адрес игры
/// до подключения к сети недоступен, поэтому основой может быть только
/// код сети.
///
/// В значении `G:` — только цифры, точки и `@`. Двоеточий и букв там нет
/// намеренно: ZXing ищет поля вроде `P:` по всей строке, а не по границам.
class JoinCode {
  final WifiConfig wifi;

  /// Шесть цифр. `null` — это обычный код сети, без игры.
  final String? code;

  /// IPv4-адрес ведущего. `null` — адрес найдётся поиском по сети.
  final String? host;

  const JoinCode({required this.wifi, this.code, this.host});

  static final _six = RegExp(r'^\d{6}$');
  static final _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
  static final _game = RegExp(r'^(\d{6})(?:@(.*))?$');

  static bool isIpv4(String v) {
    final m = _ipv4.firstMatch(v);
    if (m == null) return false;
    for (var i = 1; i <= 4; i++) {
      if (int.parse(m.group(i)!) > 255) return false;
    }
    return true;
  }

  static bool looksLikeWifi(String raw) {
    final v = raw.trimLeft();
    return v.length >= 5 && v.substring(0, 5).toUpperCase() == 'WIFI:';
  }

  /// Значение поля `G:`. `null`, если номер игры не шесть цифр.
  /// Адрес попадает в код, только если это IPv4: иное значение пришлось бы
  /// экранировать, а без адреса игра всё равно найдётся поиском по сети.
  static String? gameField({required String code, String? host}) {
    if (!_six.hasMatch(code)) return null;
    if (host != null && isIpv4(host)) return '$code@$host';
    return code;
  }

  /// Строка единого кода для экрана ведущего.
  static String build({
    required WifiConfig wifi,
    required String code,
    String? host,
  }) =>
      wifi.toQrPayload(game: gameField(code: code, host: host));

  /// Разбор кода сети — и единого, и обычного. `null`, если это не код
  /// сети или в нём не хватает данных, чтобы подключиться.
  static JoinCode? parse(String raw) {
    final value = raw.trim();
    if (!looksLikeWifi(value)) return null;

    // Первое вхождение ключа побеждает — так же читают код телефоны.
    final fields = <String, String>{};
    for (final part in _split(value.substring(5))) {
      final i = part.indexOf(':');
      if (i <= 0) continue;
      fields.putIfAbsent(
          part.substring(0, i).toUpperCase(), () => part.substring(i + 1));
    }

    final ssid = _unescape(fields['S'] ?? '');
    final password = _unescape(fields['P'] ?? '');
    final type = _unescape(fields['T'] ?? '').toUpperCase();

    final WifiSecurity security;
    if (type == 'WEP') {
      security = WifiSecurity.wep;
    } else if (type == 'NOPASS' || (type.isEmpty && password.isEmpty)) {
      security = WifiSecurity.open;
    } else {
      security = WifiSecurity.wpa;
    }

    final wifi = WifiConfig(
      ssid: ssid,
      password: security == WifiSecurity.open ? '' : password,
      security: security,
      hidden: _unescape(fields['H'] ?? '').toLowerCase() == 'true',
    );
    if (!wifi.isUsable) return null;

    String? code;
    String? host;
    final m = _game.firstMatch(_unescape(fields['G'] ?? ''));
    if (m != null) {
      code = m.group(1);
      final h = m.group(2);
      if (h != null && isIpv4(h)) host = h;
    }

    return JoinCode(wifi: wifi, code: code, host: host);
  }

  /// Делит строку по `;`, не трогая экранированные `\;`.
  static List<String> _split(String body) {
    final parts = <String>[];
    final cur = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (ch == r'\' && i + 1 < body.length) {
        cur
          ..write(ch)
          ..write(body[i + 1]);
        i++;
      } else if (ch == ';') {
        parts.add(cur.toString());
        cur.clear();
      } else {
        cur.write(ch);
      }
    }
    if (cur.isNotEmpty) parts.add(cur.toString());
    return parts;
  }

  /// Снимает экранирование и необязательные кавычки вокруг значения.
  static String _unescape(String v) {
    var s = v;
    if (s.length >= 2 &&
        s.startsWith('"') &&
        s.endsWith('"') &&
        !s.endsWith(r'\"')) {
      s = s.substring(1, s.length - 1);
    }
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == r'\' && i + 1 < s.length) {
        out.write(s[i + 1]);
        i++;
      } else {
        out.write(ch);
      }
    }
    return out.toString();
  }
}
