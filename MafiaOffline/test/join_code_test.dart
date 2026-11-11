import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/net/join_code.dart';
import 'package:mafia_offline/net/wifi_joiner.dart';
import 'package:mafia_offline/storage/wifi_store.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Как код сети читают телефоны.
//
// Единый код обязан оставаться для камеры обычным кодом Wi-Fi. Проверить это
// на живых телефонах в тестах нельзя, но можно повторить их алгоритмы разбора
// и убедиться, что поле G: ничего в них не меняет. Ниже — три таких
// алгоритма, перенесённых из исходников:
//   * ZXing, WifiResultParser + ResultParser.matchPrefixedField;
//   * Android 10–13, Settings: WifiQrCode.parseZxingWifiQrCode;
//   * Android 14+, модуль Wi-Fi: WifiUriParser.parseZxingUri.
// ---------------------------------------------------------------------------

/// ZXing: поле ищется по первому вхождению префикса ГДЕ УГОДНО в строке.
String? _zxingField(String prefix, String payload) {
  final text = payload.substring('WIFI:'.length);
  var i = 0;
  while (i < text.length) {
    i = text.indexOf(prefix, i);
    if (i < 0) break;
    i += prefix.length;
    final start = i;
    while (true) {
      i = text.indexOf(';', i);
      if (i < 0) {
        i = text.length;
        break;
      }
      var slashes = 0;
      for (var k = i - 1; k >= 0 && text[k] == r'\'; k--) {
        slashes++;
      }
      if (slashes.isOdd) {
        i++;
        continue;
      }
      final element = _zxingUnescape(text.substring(start, i));
      if (element.isNotEmpty) return element;
      i++;
      break;
    }
  }
  return null;
}

String _zxingUnescape(String v) {
  final out = StringBuffer();
  var escaped = false;
  for (final ch in v.split('')) {
    if (escaped || ch != r'\') {
      out.write(ch);
      escaped = false;
    } else {
      escaped = true;
    }
  }
  return out.toString();
}

Map<String, String?> _zxing(String payload) => {
      for (final k in ['S', 'P', 'T', 'H', 'PH2', 'I', 'A', 'E'])
        k: _zxingField('$k:', payload),
    };

/// Android 10–13: строка делится по неэкранированным `;`, поле — это
/// элемент, который начинается с префикса.
Map<String, String?> _aospOld(String payload) {
  final parts = payload.substring('WIFI:'.length).split(RegExp(r'(?<!\\);'));
  String? value(String prefix) {
    for (final p in parts) {
      if (p.startsWith(prefix)) return p.substring(prefix.length);
    }
    return null;
  }

  return {for (final k in ['S', 'P', 'T', 'H']) k: value('$k:')};
}

/// Android 14+: строка читается слева направо; неизвестное поле
/// пропускается до следующего неэкранированного `;`.
Map<String, String?> _aospNew(String payload) {
  final text = payload.substring('WIFI:'.length);
  final out = <String, String?>{'S': null, 'P': null, 'T': null, 'H': null};
  final unknown = <String>[];

  // Возвращает (сколько символов съедено, значение).
  (int, String) element(String sub, int prefixLen) {
    final sb = StringBuffer();
    var handled = 0;
    var escaped = false;
    for (var i = prefixLen; i < sub.length; i++) {
      final ch = sub[i];
      handled++;
      if (ch == r'\') {
        if (escaped) {
          sb.write(ch);
          escaped = false;
          continue;
        }
        escaped = true;
      } else if (ch == ';') {
        if (!escaped) break;
        sb.write(ch);
        escaped = false;
      } else {
        sb.write(ch);
        escaped = false;
      }
    }
    return (handled, sb.toString());
  }

  var start = 0;
  while (start < text.length) {
    final sub = text.substring(start);
    final ch = text[start];
    String? key;
    for (final k in ['S', 'T', 'P', 'H', 'R']) {
      if (sub.startsWith('$k:')) key = k;
    }
    if (key != null) {
      final (n, v) = element(sub, 2);
      out[key] = v;
      start += n + 2;
    } else if (ch.trim().isEmpty || ch == ';') {
      start++;
    } else {
      final (n, v) = element(sub, 0);
      unknown.add(v);
      start += n;
    }
  }
  out['unknown'] = unknown.join('|');
  return out;
}

void main() {
  const plainNet = WifiConfig(ssid: 'Mafia-Host', password: 'game2024');

  group('единый код: сборка', () {
    test('сеть, номер игры и адрес ведущего в одной строке', () {
      expect(
        JoinCode.build(wifi: plainNet, code: '482913', host: '192.168.43.1'),
        'WIFI:T:WPA;S:Mafia-Host;P:game2024;G:482913@192.168.43.1;;',
      );
    });

    test('без адреса остаётся только номер игры', () {
      expect(
        JoinCode.build(wifi: plainNet, code: '482913'),
        'WIFI:T:WPA;S:Mafia-Host;P:game2024;G:482913;;',
      );
    });

    test('адрес не IPv4 в код не попадает', () {
      for (final host in ['host.local', 'fe80::1', '999.1.1.1', '1.2.3', '']) {
        expect(
          JoinCode.build(wifi: plainNet, code: '482913', host: host),
          'WIFI:T:WPA;S:Mafia-Host;P:game2024;G:482913;;',
          reason: host,
        );
      }
    });

    test('номер игры не из шести цифр — получается обычный код сети', () {
      for (final code in ['', '12345', '1234567', '12a456']) {
        expect(
          JoinCode.build(wifi: plainNet, code: code, host: '192.168.43.1'),
          plainNet.toQrPayload(),
          reason: code,
        );
      }
    });

    test('поле игры всегда последнее — после скрытой сети тоже', () {
      const c = WifiConfig(ssid: 'Secret', password: '12345678', hidden: true);
      expect(
        JoinCode.build(wifi: c, code: '482913', host: '10.0.0.5'),
        'WIFI:T:WPA;S:Secret;P:12345678;H:true;G:482913@10.0.0.5;;',
      );
    });

    test('открытая сеть', () {
      const c = WifiConfig(ssid: 'FreeWiFi', security: WifiSecurity.open);
      expect(
        JoinCode.build(wifi: c, code: '482913', host: '10.0.0.5'),
        'WIFI:T:nopass;S:FreeWiFi;G:482913@10.0.0.5;;',
      );
    });

    test('обычный код сети не изменился', () {
      expect(plainNet.toQrPayload(), 'WIFI:T:WPA;S:Mafia-Host;P:game2024;;');
      expect(plainNet.toQrPayload(game: ''), plainNet.toQrPayload());
    });
  });

  group('единый код: камера телефона видит обычную сеть', () {
    const nets = [
      plainNet,
      WifiConfig(ssid: 'Net', password: 'pa;ss;word'),
      WifiConfig(ssid: 'My:Net, 5G', password: r'p:a,s\s"x'),
      WifiConfig(ssid: 'Кафе «У Дона»', password: 'пароль123'),
      // Имя и пароль, похожие на служебные поля.
      WifiConfig(ssid: 'S:P:T:H:', password: 'G:123456@1.2.3.4'),
      WifiConfig(ssid: 'Hidden', password: '12345678', hidden: true),
      WifiConfig(ssid: 'Open', security: WifiSecurity.open),
      WifiConfig(ssid: 'Old', password: 'abcde', security: WifiSecurity.wep),
    ];

    for (final net in nets) {
      final plain = net.toQrPayload();
      final single =
          JoinCode.build(wifi: net, code: '482913', host: '192.168.43.1');

      test('«${net.ssid}»: ZXing читает те же поля', () {
        expect(single, isNot(plain));
        expect(_zxing(single), _zxing(plain));
        expect(_zxing(single)['S'], net.ssid);
      });

      test('«${net.ssid}»: Android 10–13 читает те же поля', () {
        expect(_aospOld(single), _aospOld(plain));
      });

      test('«${net.ssid}»: Android 14+ читает те же поля', () {
        final a = _aospNew(single);
        final b = _aospNew(plain);
        expect(a['unknown'], 'G:482913@192.168.43.1');
        expect(b['unknown'], '');
        a.remove('unknown');
        b.remove('unknown');
        expect(a, b);
        expect(a['S'], net.ssid);
      });
    }

    test('ZXing не находит в поле игры чужих полей', () {
      final z = _zxing(
          JoinCode.build(wifi: plainNet, code: '482913', host: '192.168.43.1'));
      expect(z['S'], 'Mafia-Host');
      expect(z['P'], 'game2024');
      expect(z['T'], 'WPA');
      expect(z['H'], isNull);
      expect(z['PH2'], isNull);
      expect(z['I'], isNull);
      expect(z['A'], isNull);
      expect(z['E'], isNull);
    });
  });

  group('единый код: помещается в QR', () {
    int version(String data) {
      final r = QrValidator.validate(
        data: data,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
      );
      expect(r.status, QrValidationStatus.valid, reason: data);
      return r.qrCode!.typeNumber;
    }

    test('обычная сеть — мелкий код, читается с экрана телефона', () {
      final data =
          JoinCode.build(wifi: plainNet, code: '482913', host: '192.168.43.1');
      expect(version(data), lessThanOrEqualTo(5));
    });

    test('самые длинные имя и пароль всё ещё помещаются', () {
      final net = WifiConfig(ssid: 'S' * 32, password: 'p' * 63);
      final data =
          JoinCode.build(wifi: net, code: '482913', host: '192.168.100.200');
      expect(version(data), lessThanOrEqualTo(10));
    });
  });

  group('единый код: разбор', () {
    test('туда и обратно — сеть, игра и адрес сохраняются', () {
      const nets = [
        plainNet,
        WifiConfig(ssid: 'Net', password: 'pa;ss;word'),
        WifiConfig(ssid: 'My:Net, 5G', password: r'p:a,s\s"x'),
        WifiConfig(ssid: 'Кафе «У Дона»', password: 'пароль123'),
        WifiConfig(ssid: 'S:P:T:H:', password: 'G:123456@1.2.3.4'),
        WifiConfig(ssid: r'tail\', password: r'\\;;'),
        WifiConfig(ssid: 'Hidden', password: '12345678', hidden: true),
        WifiConfig(ssid: 'Open', security: WifiSecurity.open),
        WifiConfig(ssid: 'Old', password: 'abcde', security: WifiSecurity.wep),
      ];
      for (final net in nets) {
        final j = JoinCode.parse(
            JoinCode.build(wifi: net, code: '482913', host: '192.168.43.1'));
        expect(j, isNotNull, reason: net.ssid);
        expect(j!.wifi.ssid, net.ssid);
        expect(j.wifi.password, net.password, reason: net.ssid);
        expect(j.wifi.security, net.security, reason: net.ssid);
        expect(j.wifi.hidden, net.hidden, reason: net.ssid);
        expect(j.code, '482913', reason: net.ssid);
        expect(j.host, '192.168.43.1', reason: net.ssid);
      }
    });

    test('обычный код сети: сеть есть, игры нет', () {
      final j = JoinCode.parse(plainNet.toQrPayload());
      expect(j, isNotNull);
      expect(j!.wifi.ssid, 'Mafia-Host');
      expect(j.code, isNull);
      expect(j.host, isNull);
    });

    test('без адреса — только номер игры', () {
      final j = JoinCode.parse('WIFI:T:WPA;S:Net;P:12345678;G:482913;;');
      expect(j!.code, '482913');
      expect(j.host, isNull);
    });

    test('порядок полей и регистр префикса не важны', () {
      final j = JoinCode.parse(
          ' wifi:G:482913@10.0.0.5;P:12345678;S:Net;T:WPA2;H:TRUE;; ');
      expect(j, isNotNull);
      expect(j!.wifi.ssid, 'Net');
      expect(j.wifi.password, '12345678');
      expect(j.wifi.security, WifiSecurity.wpa);
      expect(j.wifi.hidden, isTrue);
      expect(j.code, '482913');
      expect(j.host, '10.0.0.5');
    });

    test('тип защиты: пусто без пароля — открытая, с паролем — WPA', () {
      expect(JoinCode.parse('WIFI:S:Net;;')!.wifi.security, WifiSecurity.open);
      expect(JoinCode.parse('WIFI:S:Net;P:12345678;;')!.wifi.security,
          WifiSecurity.wpa);
      expect(JoinCode.parse('WIFI:T:SAE;S:Net;P:12345678;;')!.wifi.security,
          WifiSecurity.wpa);
      expect(JoinCode.parse('WIFI:T:WEP;S:Net;P:abcde;;')!.wifi.security,
          WifiSecurity.wep);
    });

    test('имя сети в кавычках читается без кавычек', () {
      expect(JoinCode.parse('WIFI:T:WPA;S:"Net";P:12345678;;')!.wifi.ssid,
          'Net');
    });

    test('испорченное поле игры — сеть читается, игры нет', () {
      for (final g in ['12345', '1234567', 'abcdef', '@10.0.0.5', '']) {
        final j = JoinCode.parse('WIFI:T:WPA;S:Net;P:12345678;G:$g;;');
        expect(j, isNotNull, reason: g);
        expect(j!.code, isNull, reason: g);
      }
    });

    test('негодный адрес отбрасывается, номер игры остаётся', () {
      for (final h in ['999.1.1.1', 'host', '1.2.3', '']) {
        final j = JoinCode.parse('WIFI:T:WPA;S:Net;P:12345678;G:482913@$h;;');
        expect(j!.code, '482913', reason: h);
        expect(j.host, isNull, reason: h);
      }
    });

    test('не код сети и неполный код сети — null', () {
      expect(JoinCode.parse(''), isNull);
      expect(JoinCode.parse('482913'), isNull);
      expect(JoinCode.parse('http://192.168.43.1:8088/?g=482913'), isNull);
      expect(JoinCode.parse('WIFI:'), isNull);
      expect(JoinCode.parse('WIFI:T:WPA;P:12345678;;'), isNull);
      // Защищённая сеть без пароля: подключиться по такому коду нельзя.
      expect(JoinCode.parse('WIFI:T:WPA;S:Net;G:482913;;'), isNull);
    });
  });

  group('сканер: что считается кодом игры', () {
    test('единый код даёт номер игры, адрес и сеть', () {
      final g = ScannedGame.tryParse(
          'WIFI:T:WPA;S:Mafia-Host;P:game2024;G:482913@192.168.43.1;;');
      expect(g, isNotNull);
      expect(g!.code, '482913');
      expect(g.host, '192.168.43.1');
      expect(g.port, 8088);
      expect(g.wifi, isNotNull);
      expect(g.wifi!.ssid, 'Mafia-Host');
      expect(g.wifi!.password, 'game2024');
    });

    test('ссылка на игру читается как раньше, сети в ней нет', () {
      final g = ScannedGame.tryParse('http://192.168.43.1:8088/?g=482913');
      expect(g!.code, '482913');
      expect(g.host, '192.168.43.1');
      expect(g.port, 8088);
      expect(g.wifi, isNull);
    });

    test('старый формат и просто шесть цифр читаются как раньше', () {
      final old = ScannedGame.tryParse('mafia://10.0.0.5:9000/482913');
      expect(old!.code, '482913');
      expect(old.host, '10.0.0.5');
      expect(old.port, 9000);

      final digits = ScannedGame.tryParse(' 482913 ');
      expect(digits!.code, '482913');
      expect(digits.host, isNull);
      expect(digits.wifi, isNull);
    });

    // До 1.4.0 сканер искал в любой строке шесть цифр подряд и принял бы
    // пароль Wi-Fi за номер игры.
    test('код сети без игры — не код игры, даже с цифрами в пароле', () {
      expect(ScannedGame.tryParse('WIFI:T:WPA;S:Net;P:123456;;'), isNull);
      expect(ScannedGame.tryParse('WIFI:T:WPA;S:Net;P:key 482913 x;;'), isNull);
      expect(ScannedGame.tryParse('WIFI:T:WPA;S:482913;P:12345678;;'), isNull);
    });

    test('посторонний код — null', () {
      expect(ScannedGame.tryParse('https://example.com/'), isNull);
      expect(ScannedGame.tryParse('привет'), isNull);
    });
  });

  group('подключение к сети: обмен с системой', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    final calls = <MethodCall>[];
    void answer(Object? Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(WifiJoiner.channel, (call) async {
        calls.add(call);
        return handler(call);
      });
    }

    setUp(calls.clear);
    tearDown(
        () => messenger.setMockMethodCallHandler(WifiJoiner.channel, null));

    test('в систему уходят имя, пароль, тип защиты и признак скрытой сети',
        () async {
      answer((_) => 'saved');
      const net = WifiConfig(ssid: 'Net', password: '12345678', hidden: true);
      expect(await WifiJoiner.addNetwork(net), WifiJoinResult.saved);
      expect(calls.single.method, 'addNetwork');
      expect(calls.single.arguments, {
        'ssid': 'Net',
        'password': '12345678',
        'security': 'wpa',
        'hidden': true,
      });
    });

    test('открытая сеть уходит без пароля', () async {
      answer((_) => 'saved');
      const net = WifiConfig(
          ssid: 'Open', password: 'лишний', security: WifiSecurity.open);
      await WifiJoiner.addNetwork(net);
      final args = calls.single.arguments as Map;
      expect(args['password'], '');
      expect(args['security'], 'open');
    });

    test('ответы системы переводятся в исход', () async {
      const net = WifiConfig(ssid: 'Net', password: '12345678');
      const expected = {
        'saved': WifiJoinResult.saved,
        'exists': WifiJoinResult.exists,
        'cancelled': WifiJoinResult.cancelled,
        'unsupported': WifiJoinResult.unsupported,
        'failed': WifiJoinResult.failed,
        'что-то новое': WifiJoinResult.failed,
      };
      for (final e in expected.entries) {
        answer((_) => e.key);
        expect(await WifiJoiner.addNetwork(net), e.value, reason: e.key);
      }
      answer((_) => null);
      expect(await WifiJoiner.addNetwork(net), WifiJoinResult.failed);
    });

    test('WEP и неполная сеть до системы не доходят', () async {
      answer((_) => 'saved');
      const wep =
          WifiConfig(ssid: 'Old', password: 'abcde', security: WifiSecurity.wep);
      expect(await WifiJoiner.addNetwork(wep), WifiJoinResult.unsupported);
      expect(await WifiJoiner.addNetwork(const WifiConfig(ssid: 'NoPass')),
          WifiJoinResult.failed);
      expect(calls, isEmpty);
    });

    test('нет нативной части (iPhone) — «не поддерживается», без падения',
        () async {
      const net = WifiConfig(ssid: 'Net', password: '12345678');
      expect(await WifiJoiner.addNetwork(net), WifiJoinResult.unsupported);
      expect(await WifiJoiner.openWifiSettings(), isFalse);
    });

    test('ошибка системы — «не удалось», без падения', () async {
      answer((_) => throw PlatformException(code: 'boom'));
      const net = WifiConfig(ssid: 'Net', password: '12345678');
      expect(await WifiJoiner.addNetwork(net), WifiJoinResult.failed);
      expect(await WifiJoiner.openWifiSettings(), isFalse);
    });

    test('открытие списка сетей возвращает ответ системы', () async {
      answer((_) => true);
      expect(await WifiJoiner.openWifiSettings(), isTrue);
      expect(calls.single.method, 'openWifiSettings');
    });
  });

  group('настройка «единый код»', () {
    test('по умолчанию включена и запоминается', () async {
      SharedPreferences.setMockInitialValues({});
      final store = WifiStore();
      expect(await store.isCombined(), isTrue);
      await store.setCombined(false);
      expect(await store.isCombined(), isFalse);
      // Соседняя настройка не задета.
      expect(await store.isEnabled(), isTrue);
    });
  });
}
