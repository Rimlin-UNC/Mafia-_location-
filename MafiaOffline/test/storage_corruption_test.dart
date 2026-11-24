import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/models/role.dart';
import 'package:mafia_offline/storage/player_session_store.dart';
import 'package:mafia_offline/storage/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Отказоустойчивость сохранения партии.
//
// Сохранение — единственное, что связывает партию до и после выключения
// телефона. Оно лежит в SharedPreferences обычным JSON и переживает:
//   * смену версии приложения (поля появлялись и исчезали от релиза к релизу);
//   * внезапное выключение питания (запись могла оборваться);
//   * обновление приложения на ходу.
//
// Дефект 1.9.2: разбор делал жёсткие приведения `as String?`, `as int?`.
// На поле другого типа Dart бросал TypeError, `load()` ловил его внешним
// catch, **молча стирал сохранение** и возвращал null. Ведущий видел
// «незавершённой партии нет» и терял расклад ролей, лог и живой состав —
// из-за одного испорченного поля в конце файла.
//
// Теперь каждое поле читается проверкой типа с запасным значением, и
// повреждение одного поля не убивает восстановление целиком.
// ---------------------------------------------------------------------------

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Минимальное валидное сохранение, поверх которого ломаем поля.
  Map<String, dynamic> validSaved() => {
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'id': 'g1',
        'name': 'Игра от 10.11',
        'code': '123456',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'plannedPlayers': 8,
        'phase': 'night',
        'round': 2,
        'timeLeft': 90,
        'openCards': false,
        'introNight': false,
        'lastWord': true,
        'privateCheck': true,
        'lastWordId': null,
        'verdictId': null,
        'checks': <dynamic>[],
        'storySeen': <String>[],
        'noDeathsStreak': 0,
        'roleSetup': {'mafia': 2, 'don': 1, 'doctor': 1},
        'nightActions': <String, dynamic>{},
        'votes': <String, dynamic>{},
        'runoff': <String>[],
        'awaitingVoteConfirm': false,
        'players': [
          {
            'id': 'p1',
            'name': 'Аня',
            'color': '#FF0000',
            'role': 'mafia',
            'isAlive': true,
            'roleAck': true,
          },
          {
            'id': 'p2',
            'name': 'Боря',
            'color': '#00FF00',
            'role': 'civilian',
            'isAlive': true,
            'roleAck': true,
          },
        ],
        'log': <dynamic>[],
      };

  Future<void> putRaw(Object? json) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_session_v1',
        json is String ? json : jsonEncode(json));
  }

  group('Сохранение партии переживает порчу одного поля', () {
    test('целое сохранение читается как есть', () async {
      await putRaw(validSaved());
      final s = await SessionStore().load();
      expect(s, isNotNull);
      expect(s!.code, '123456');
      expect(s.players.length, 2);
      expect(s.round, 2);
    });

    test('число вместо строки в имени партии не рушит восстановление', () async {
      final saved = validSaved()..['name'] = 42;
      await putRaw(saved);
      final s = await SessionStore().load();
      expect(s, isNotNull,
          reason: 'одно поле другого типа не должно стирать партию');
      expect(s!.code, '123456', reason: 'остальные поля обязаны сохраниться');
    });

    // 1.12.0: пять новых полей состояния. Сохранение из 1.11.x их не знает,
    // а испорченное поле не должно стирать партию — правило то же, что для
    // остальных.
    test('партия из 1.11.0 без новых полей читается', () async {
      await putRaw(validSaved());
      final s = await SessionStore().load();
      expect(s, isNotNull);
      expect(s!.silencedId, isNull);
      expect(s.watchTargetId, isNull);
      expect(s.hunterMarkId, isNull);
      expect(s.lastGuardedId, isNull);
      expect(s.watchRound, 0);
    });

    test('новые поля 1.12.0 переживают сохранение', () async {
      final saved = validSaved()
        ..['silencedId'] = 'p2'
        ..['silencedRound'] = 2
        ..['watchTargetId'] = 'p1'
        ..['watchActed'] = true
        ..['watchRound'] = 2
        ..['hunterMarkId'] = 'p1'
        ..['lastGuardedId'] = 'p2';
      await putRaw(saved);
      final s = await SessionStore().load();
      expect(s, isNotNull);
      expect(s!.silencedId, 'p2');
      expect(s.watchTargetId, 'p1');
      expect(s.watchActed, isTrue);
      expect(s.hunterMarkId, 'p1');
      expect(s.lastGuardedId, 'p2');
    });

    test('испорченные новые поля не стирают партию', () async {
      final saved = validSaved()
        ..['silencedId'] = [1, 2]
        ..['hunterMarkId'] = {'a': 1}
        ..['watchActed'] = 'да';
      await putRaw(saved);
      final s = await SessionStore().load();
      expect(s, isNotNull);
      expect(s!.code, '123456');
      expect(s.players.length, 2);
    });

    test('массив вместо строки в коде игры', () async {
      final saved = validSaved()..['code'] = [1, 2, 3];
      await putRaw(saved);
      final s = await SessionStore().load();
      expect(s, isNotNull);
      expect(s!.players.length, 2, reason: 'состав обязан уцелеть');
    });

    test('строка вместо числа в round и timeLeft', () async {
      final saved = validSaved()
        ..['round'] = 'два'
        ..['timeLeft'] = 'много';
      await putRaw(saved);
      final s = await SessionStore().load();
      expect(s, isNotNull);
      expect(s!.round, isA<int>());
      expect(s.timeLeft, isA<int>());
    });

    test('bool как строка в правилах стола', () async {
      final saved = validSaved()
        ..['openCards'] = 'да'
        ..['lastWord'] = 1;
      await putRaw(saved);
      final s = await SessionStore().load();
      expect(s, isNotNull);
      expect(s!.openCards, isA<bool>());
    });

    test('битый игрок не уносит с собой остальных', () async {
      final saved = validSaved();
      (saved['players'] as List)[0] = {
        'id': 7, // было строкой
        'name': <String>[], // массив
        'color': true,
        'role': 42,
        'isAlive': 'да',
      };
      await putRaw(saved);
      final s = await SessionStore().load();
      expect(s, isNotNull);
      expect(s!.players.length, 2,
          reason: 'испорченный игрок должен остаться в партии, '
              'а не исчезнуть вместе с соседом');
      expect(s.players[1].name, 'Боря');
    });

    test('поле исчезло целиком (старое сохранение)', () async {
      final saved = validSaved()
        ..remove('roleSetup')
        ..remove('checks')
        ..remove('storySeen')
        ..remove('nightActions');
      await putRaw(saved);
      final s = await SessionStore().load();
      expect(s, isNotNull,
          reason: 'сохранение прежней версии должно открываться');
    });

    test('сохранение целиком не JSON — возвращается null, без исключения',
        () async {
      await putRaw('это не json {{{');
      expect(() => SessionStore().load(), returnsNormally);
      expect(await SessionStore().load(), isNull);
    });

    test('сохранение не объект JSON', () async {
      await putRaw('[1,2,3]');
      expect(await SessionStore().load(), isNull);
    });

    test('пустой объект не роняет разбор', () async {
      await putRaw({});
      expect(() => SessionStore().load(), returnsNormally);
    });
  });

  group('Игрок в сохранении: мягкий разбор', () {
    test('все поля другого типа', () {
      final p = Player.fromStorageJson({
        'id': 7,
        'name': <String>[],
        'color': true,
        'role': 42,
        'isAlive': 'да',
        'roleAck': 'нет',
        'deviceId': 3.14,
        'eliminatedRound': 'пятый',
        'reason': [],
      });
      expect(p.id, isA<String>());
      expect(p.name, isA<String>());
      expect(p.colorHex, isA<String>());
      expect(p.isAlive, isA<bool>());
      expect(p.roleAcknowledged, isA<bool>());
      expect(p.role, isNull);
    });

    test('пустой объект даёт игрока по умолчанию', () {
      final p = Player.fromStorageJson({});
      expect(p.id, '');
      expect(p.name, '—');
      expect(p.isAlive, isTrue);
    });

    test('дробное число в eliminatedRound не бросает', () {
      final p = Player.fromStorageJson({'eliminatedRound': 2.9});
      expect(p.eliminatedRound, 2);
    });
  });

  group('Сессия игрока: мягкий разбор', () {
    test('поле другого типа не мешает войти обратно', () {
      final s = PlayerSession.fromJson({
        'code': '123456',
        'name': 'Аня',
        'playerId': 42,
        'host': true,
        'port': '8088',
        'savedAt': 'вчера',
      });
      expect(s, isNotNull);
      expect(s!.code, '123456');
      expect(s.playerId, isNull, reason: 'битое поле — просто без id');
      expect(s.port, 8088);
      expect(s.savedAt, 0);
    });

    test('без кода или имени сессии нет', () {
      expect(PlayerSession.fromJson({'name': 'Аня'}), isNull);
      expect(PlayerSession.fromJson({'code': '1'}), isNull);
      expect(PlayerSession.fromJson({'code': 1, 'name': 'Аня'}), isNull);
    });

    test('нормальная сессия читается', () {
      final s = PlayerSession.fromJson({
        'code': '123456',
        'name': 'Аня',
        'playerId': 'p1',
        'host': '192.168.43.1',
        'port': 8088,
        'savedAt': 1000,
      });
      expect(s!.playerId, 'p1');
      expect(s.host, '192.168.43.1');
    });
  });

  group('Проверка самой ловушки', () {
    test('жёсткий каст, который был раньше, действительно бросает', () {
      // Фиксируем суть дефекта: именно это исключение «съедал» внешний
      // catch, стирая сохранение. Если Dart когда-нибудь станет мягче,
      // тест покажет, что причина ушла.
      final map = <String, dynamic>{'name': 42};
      expect(() => map['name'] as String?, throwsA(isA<TypeError>()));
    });

    test('роли восстанавливаются по имени типа', () {
      expect(Role.tryParse('mafia')?.type, RoleType.mafia);
      expect(Role.tryParse('не роль'), isNull);
      expect(Role.tryParse(null), isNull);
    });
  });
}
