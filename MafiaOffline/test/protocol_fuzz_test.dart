import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/core/constants.dart';
import 'package:mafia_offline/net/protocol.dart';

// ---------------------------------------------------------------------------
// Стресс-тест протокола: что бы клиент ни прислал, ведущий не должен упасть.
//
// Порт 8088 открыт в локальной сети и принимает WebSocket от кого угодно.
// За столом это не только 20 игроков: это ещё и телефон, у которого
// приложение обновилось посреди партии, и старый кеш браузера, и
// случайный сканер портов, и просто баг в чужом клиенте.
//
// `Envelope.decode` — единственная дверь между сетевым мусором и игровой
// логикой. Если он бросает исключение, сообщение роняет подписку сервера
// (исправлено в 1.9.2 try/catch в HostController), а до этого просто
// валило обработку. Здесь проверяется более строгое свойство: decode
// НИКОГДА не бросает исключение — на любом входе он либо возвращает
// конверт, либо null.
// ---------------------------------------------------------------------------

void main() {
  group('Envelope.decode не падает на мусоре', () {
    /// Всё, что реально может прийти в сокет.
    const garbage = <String>[
      '', ' ', '\n', '\t\t',                               // пустота
      'null', 'true', 'false', '[]', '{}', '[1,2,3]',     // не тот тип
      '"строка"', '42', '-1', '3.14', 'NaN', 'Infinity',  // не объект
      '{', '}', '[[[', '{"a":', '{"a"',                   // обрезанный JSON
      '{}garbage', '{"type":"sync"}trailing',             // мусор после
      '\u0000\u0001\u0002', '💥🎭🔪',                     // бинарные и эмодзи
      '{"type":1}', '{"type":null}', '{"type":[]}',       // тип не строка
      '{"type":"sync","v":"1"}',                          // версия строкой
      '{"type":"sync","v":1.5}',                          // версия дробью
      '{"type":"sync","v":null}', '{"type":"sync","v":[]}',
      '{"type":"sync","ts":"вчера"}',                     // время строкой
      '{"type":"sync","ts":1.5}', '{"type":"sync","ts":[]}',
      '{"v":1,"type":"sync","data":{"__proto__":{"x":1}}}',
      '{"type":"sync","v":999999999999999999999999}',      // огромное число
      '{"type":"${List.filled(100000, 'A').join()}"}',      // гигантский тип
      '${List.filled(2000, '[').join()}'
      '${List.filled(2000, ']').join()}',                 // глубокая вложенность
    ];

    for (final raw in garbage) {
      test('не падает на: ${raw.length > 40 ? '${raw.substring(0, 40)}…' : raw}', () {
        expect(() => Envelope.decode(raw), returnsNormally,
            reason: 'исключение на входе: ${raw.length > 200 ? 'длинный' : raw}');
      });
    }

    test('настоящий пакет по-прежнему разбирается', () {
      // Контроль: мы не «починили» разбор, отключив его.
      final env = Envelope(Msg.ping, {'t': 12345, 'rtt': 40});
      final decoded = Envelope.decode(env.encode());
      expect(decoded, isNotNull);
      expect(decoded!.type, Msg.ping);
      expect(decoded.get<int>('t'), 12345);
      expect(decoded.get<int>('rtt'), 40);
    });

    test('чужая версия протокола даёт null и запоминается', () {
      Envelope.lastRejectedVersion = null;
      final decoded = Envelope.decode(
        jsonEncode({'v': Net.protocolVersion + 1, 'type': 'sync', 'ts': 1}),
      );
      expect(decoded, isNull);
      expect(Envelope.lastRejectedVersion, Net.protocolVersion + 1,
          reason: 'серверу нужно знать версию, чтобы ответить bad_version');
    });

    test('версия строкой не считается «нашей» и не бросает', () {
      // Реальный случай: клиент из кеша сериализовал число как строку.
      Envelope.lastRejectedVersion = null;
      expect(() => Envelope.decode('{"type":"sync","v":"1"}'),
          returnsNormally);
      final decoded = Envelope.decode('{"type":"sync","v":"1"}');
      expect(decoded, isNull);
    });
  });

  group('Envelope.get терпим к типу поля', () {
    test('число вместо строки не бросает', () {
      final env = Envelope(Msg.vote, {'playerId': 42, 'target': null});
      expect(() => env.get<String>('playerId'), returnsNormally);
      expect(env.get<String>('playerId'), isNull);
      expect(env.get<int>('playerId'), 42);
    });

    test('поле отсутствует', () {
      final env = Envelope(Msg.vote, const {});
      expect(env.get<String>('нет такого'), isNull);
      expect(env.get<int>('нет такого'), isNull);
      expect(env.get<bool>('нет такого'), isNull);
    });
  });

  group('Фаззинг: 3000 случайных пакетов', () {
    test('ни один не бросает исключение', () {
      // Детерминированный сид: если тест когда-нибудь упадёт, вход
      // воспроизводится. Случайность здесь — не «надеюсь на удачу»,
      // а способ перебрать формы, которые лень придумывать руками.
      final rnd = Random(20261);
      const alphabet = '{}[]":,0123456789truefalsnlvtype sync\\/.абв💥';

      var ok = 0;
      for (var i = 0; i < 3000; i++) {
        final len = rnd.nextInt(120);
        final buf = StringBuffer();
        // Половина пакетов — валидная основа с испорченным полем,
        // половина — просто случайная строка.
        if (i.isEven) {
          buf.write('{"v":${Net.protocolVersion},"type":"sync"');
          final fields = rnd.nextInt(4);
          for (var f = 0; f < fields; f++) {
            final key = ['ts', 'role', 'data', 'v', 'type'][rnd.nextInt(5)];
            final val = [
              '1',
              '"x"',
              'null',
              '[]',
              '{}',
              '1.5',
              'true'
            ][rnd.nextInt(7)];
            buf.write(',"$key":$val');
          }
          buf.write('}');
        } else {
          for (var c = 0; c < len; c++) {
            buf.write(alphabet[rnd.nextInt(alphabet.length)]);
          }
        }

        final raw = buf.toString();
        try {
          Envelope.decode(raw);
          ok++;
        } catch (e) {
          fail('decode бросил исключение на:\n$raw\n$e');
        }
      }
      expect(ok, 3000);
    });
  });
}
