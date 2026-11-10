import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/storage/wifi_store.dart';

void main() {
  group('QR-код Wi-Fi', () {
    test('обычная сеть с паролем', () {
      const c = WifiConfig(ssid: 'Mafia-Host', password: 'game2024');
      expect(c.toQrPayload(), 'WIFI:T:WPA;S:Mafia-Host;P:game2024;;');
    });

    test('открытая сеть — без поля пароля', () {
      const c = WifiConfig(ssid: 'FreeWiFi', security: WifiSecurity.open);
      expect(c.toQrPayload(), 'WIFI:T:nopass;S:FreeWiFi;;');
    });

    test('скрытая сеть помечается H:true', () {
      const c = WifiConfig(ssid: 'Secret', password: '123', hidden: true);
      expect(c.toQrPayload(), contains('H:true;'));
    });

    // Самая коварная ошибка: точка с запятой в пароле обрывает строку,
    // и телефон читает мусор вместо сети. Такие пароли встречаются.
    test('точка с запятой в пароле экранируется', () {
      const c = WifiConfig(ssid: 'Net', password: 'pa;ss');
      expect(c.toQrPayload(), 'WIFI:T:WPA;S:Net;P:pa\\;ss;;');
    });

    test('двоеточие и обратный слеш экранируются', () {
      const c = WifiConfig(ssid: 'My:Net', password: r'a\b');
      expect(c.toQrPayload(), r'WIFI:T:WPA;S:My\:Net;P:a\\b;;');
    });

    test('запятая и кавычка экранируются', () {
      const c = WifiConfig(ssid: 'A,B', password: 'q"w');
      expect(c.toQrPayload(), r'WIFI:T:WPA;S:A\,B;P:q\"w;;');
    });

    test('русское имя сети сохраняется как есть', () {
      const c = WifiConfig(ssid: 'Мафия', password: 'пароль');
      expect(c.toQrPayload(), 'WIFI:T:WPA;S:Мафия;P:пароль;;');
    });
  });

  group('готовность конфигурации', () {
    test('пустое имя — код не показываем', () {
      expect(const WifiConfig(password: '123').isUsable, isFalse);
    });

    test('защищённая сеть без пароля — код не показываем', () {
      expect(const WifiConfig(ssid: 'Net').isUsable, isFalse);
    });

    test('открытой сети пароль не нужен', () {
      expect(
        const WifiConfig(ssid: 'Net', security: WifiSecurity.open).isUsable,
        isTrue,
      );
    });

    test('имя из одних пробелов не считается заполненным', () {
      expect(const WifiConfig(ssid: '   ', password: '1').isUsable, isFalse);
    });
  });

  group('разбор типа защиты', () {
    test('неизвестное значение превращается в WPA', () {
      expect(WifiSecurity.fromWire('какая-то чушь'), WifiSecurity.wpa);
      expect(WifiSecurity.fromWire(null), WifiSecurity.wpa);
    });

    test('известные значения читаются', () {
      expect(WifiSecurity.fromWire('nopass'), WifiSecurity.open);
      expect(WifiSecurity.fromWire('WEP'), WifiSecurity.wep);
    });
  });
}
