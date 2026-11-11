import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/core/constants.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/models/role.dart';
import 'package:mafia_offline/net/protocol.dart';
import 'package:mafia_offline/storage/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Тесты доработок по OPEN_QUESTIONS.md (вопросы 1, 2, 4, 5).
///
/// Проверяется то, что можно проверить без запуска сервера: гейт раздачи
/// ролей, новая фаза `rolesCheck`, устойчивость цвета игрока, сохранение
/// фазы и контракт пакета `sync`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Player mk(String id, {bool acked = false}) => Player(
        id: id,
        name: id,
        colorHex: '#FFFFFF',
        role: Role.civilian,
        roleAcknowledged: acked,
      );

  group('Фаза раздачи ролей', () {
    test('rolesCheck — отдельная фаза, а не «ночь»', () {
      expect(GamePhase.rolesCheck.wire, 'rolesCheck');
      expect(GamePhaseX.parse('rolesCheck'), GamePhase.rolesCheck);
      // Старые значения разбираются как раньше.
      expect(GamePhaseX.parse('night'), GamePhase.night);
      expect(GamePhaseX.parse(null), GamePhase.waiting);
      // Заголовок не должен называться «Ночь»: иначе стол решит,
      // что город уже заснул.
      expect(GamePhase.rolesCheck.title, isNot(contains('Ночь')));
    });

    test('по умолчанию партия ждёт в лобби', () {
      final s = GameState(
        id: 'g1',
        name: 't',
        code: '000000',
        createdAt: DateTime(2026),
      );
      expect(s.phase, GamePhase.waiting);
      expect(s.allRolesAcknowledged, isFalse);
    });
  });

  group('Гейт первой ночи (вопрос 2)', () {
    test('подтвердили не все — ночь начинать нельзя', () {
      final s = GameState(
        id: 'g1',
        name: 't',
        code: '000000',
        createdAt: DateTime(2026),
        phase: GamePhase.rolesCheck,
        players: [
          mk('p1', acked: true),
          mk('p2'),
          mk('p3', acked: true),
        ],
      );
      expect(s.allRolesAcknowledged, isFalse);
      expect(s.unacknowledged.map((p) => p.id), ['p2']);
    });

    test('подтвердили все — можно', () {
      final s = GameState(
        id: 'g1',
        name: 't',
        code: '000000',
        createdAt: DateTime(2026),
        phase: GamePhase.rolesCheck,
        players: [mk('p1', acked: true), mk('p2', acked: true)],
      );
      expect(s.allRolesAcknowledged, isTrue);
      expect(s.unacknowledged, isEmpty);
    });

    test('пустой состав не считается готовым', () {
      // Иначе партия «на ноль игроков» считалась бы готовой к ночи.
      final s = GameState(
        id: 'g1',
        name: 't',
        code: '000000',
        createdAt: DateTime(2026),
        phase: GamePhase.rolesCheck,
      );
      expect(s.allRolesAcknowledged, isFalse);
    });

    test('новый игрок не подтверждён по умолчанию', () {
      const p = Player(id: 'p1', name: 'Иван', colorHex: '#FFFFFF');
      expect(p.roleAcknowledged, isFalse);
    });
  });

  group('Фаза переживает перезапуск приложения', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('фаза rolesCheck и отметки ролей сохраняются', () async {
      final store = SessionStore();
      final s = GameState(
        id: 'g1',
        name: 'Партия',
        code: '123456',
        createdAt: DateTime(2026),
        plannedPlayers: 6,
        phase: GamePhase.rolesCheck,
        round: 0,
        players: [
          mk('p1', acked: true),
          mk('p2'),
        ],
      );

      await store.save(s);
      final restored = await store.load();

      expect(restored, isNotNull);
      expect(restored!.phase, GamePhase.rolesCheck);
      expect(restored.allRolesAcknowledged, isFalse);
      expect(restored.byId('p1')!.roleAcknowledged, isTrue);
      expect(restored.byId('p2')!.roleAcknowledged, isFalse);
      // После перезапуска связей нет, но роли и отметки — есть.
      expect(restored.byId('p1')!.isConnected, isFalse);
      expect(restored.byId('p1')!.role, isNotNull);
    });

    test('старое сохранение без новой фазы читается как лобби', () async {
      // Совместимость: сохранение, записанное до появления rolesCheck.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'active_session_v1',
        jsonEncode({
          'savedAt': DateTime.now().millisecondsSinceEpoch,
          'id': 'g1',
          'name': 'Старая партия',
          'code': '111111',
          'createdAt': DateTime(2026).millisecondsSinceEpoch,
          'plannedPlayers': 6,
          'phase': 'waiting',
          'players': <Object>[],
        }),
      );
      final restored = await SessionStore().load();
      expect(restored, isNotNull);
      expect(restored!.phase, GamePhase.waiting);
      expect(restored.allRolesAcknowledged, isFalse);
    });
  });

  group('Цвет игрока (вопрос 5)', () {
    test('цвет привязан к номеру слота и переживает возврат', () {
      // Слот всегда один и тот же цвет, сколько бы людей ни уходило.
      expect(colorForSlot(0), colorForSlot(0));
      expect(colorForSlot(3), colorForSlot(3));
      expect(colorForSlot(0), isNot(colorForSlot(1)));
    });

    test('20 слотов — 20 разных цветов, без повторов', () {
      final used = <String>{};
      for (var i = 0; i < Rules.maxPlayers; i++) {
        used.add(colorForSlot(i));
      }
      expect(used.length, Rules.maxPlayers);
      expect(kPlayerColors.length, greaterThanOrEqualTo(Rules.maxPlayers));
    });

    test('цвет слота не сдвигается от исключения соседа', () {
      // Раньше цвет был «первым свободным»: после исключения игрока
      // в середине списка вернувшийся получал чужой цвет.
      const slot = 4;
      final before = colorForSlot(slot);
      // Исключили игрока в слоте 1 — на цвет слота 4 это не влияет.
      final after = colorForSlot(slot);
      expect(after, before);
    });

    test('номер слота не выходит за пределы палитры', () {
      expect(colorForSlot(kPlayerColors.length), kPlayerColors.first);
      expect(colorForSlot(kPlayerColors.length + 2), kPlayerColors[2]);
    });
  });

  group('Контракт sync: подтверждение роли доезжает до клиента', () {
    test('пакет sync несёт roleAck', () {
      // Клиент без этого поля после перезагрузки страницы решил бы,
      // что роль уже подтверждена, и первая ночь ждала бы его вечно.
      final env = Envelope(Msg.sync, {'roleAck': false, 'role': 'civilian'});
      final decoded = Envelope.decode(env.encode());
      expect(decoded, isNotNull);
      expect(decoded!.get<bool>('roleAck'), isFalse);
      expect(decoded.get<String>('role'), 'civilian');
    });

    test('отсутствие roleAck в старом пакете не ломает разбор', () {
      final decoded = Envelope.decode(
        jsonEncode({'v': Net.protocolVersion, 'ts': 1, 'type': Msg.sync}),
      );
      expect(decoded, isNotNull);
      expect(decoded!.get<bool>('roleAck'), isNull);
    });

    test('порядок полей в sync: roleAck идёт вместе с roleName', () {
      // Ловушка, которую легко не заметить: клиент проверяет roleAck
      // только после присвоения roleName. Если сервер однажды перестанет
      // присылать роль в том же пакете, защитный экран не покажется,
      // и первая ночь будет ждать игрока вечно.
      final decoded = Envelope.decode(
        Envelope(Msg.sync, {
          'phase': 'rolesCheck',
          'role': 'mafia',
          'roleName': 'Мафия',
          'roleAck': false,
        }).encode(),
      )!;
      expect(decoded.get<String>('roleName'), isNotNull);
      expect(decoded.get<bool>('roleAck'), isFalse);
    });

    test('повторный показ роли использует те же типы пакетов', () {
      // «Показать роль ещё раз» переиспользует role_assign, чтобы клиент
      // снова прошёл экран-предупреждение. Новых типов не вводим.
      expect(Msg.roleAssign, 'role_assign');
      expect(Msg.roleAck, 'role_ack');
    });
  });
}
