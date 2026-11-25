import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/core/constants.dart';
import 'package:mafia_offline/core/game_engine.dart';
import 'package:mafia_offline/core/protocol_export.dart';
import 'package:mafia_offline/models/game_event.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/models/role.dart';
import 'package:mafia_offline/net/protocol.dart';
import 'package:mafia_offline/ui/history_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Тесты рекомендаций разработчика (РЕКОМЕНДАЦИИ_РАЗРАБОТЧИКА.md §5).
///
/// Проверяется чистая логика, ради которой рекомендации и выносились
/// из контроллера: правила ролей, валидация состава, таймер первой ночи,
/// текстовый протокол и контракт версии протокола.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Player mk(String id,
          {bool acked = false, bool alive = true, RoleType? role}) =>
      Player(
        id: id,
        name: id,
        colorHex: '#FFFFFF',
        role: Role.fromType(role ?? RoleType.civilian),
        isAlive: alive,
        roleAcknowledged: acked,
      );

  GameState state({
    GamePhase phase = GamePhase.rolesCheck,
    List<Player>? players,
    int round = 1,
    Map<RoleType, int> setup = const {},
  }) =>
      GameState(
        id: 'g1',
        name: 't',
        code: '000000',
        createdAt: DateTime(2026),
        phase: phase,
        round: round,
        roleSetup: setup,
        players: players ?? [mk('p1'), mk('p2')],
      );

  group('§5.2 — правило подтверждения роли (GameEngine.applyRoleAck)', () {
    test('первое подтверждение принимается и меняет состояние', () {
      final s = state();
      final r = GameEngine.applyRoleAck(s, 'p1');
      expect(r.accepted, isTrue);
      expect(r.state!.byId('p1')!.roleAcknowledged, isTrue);
      // Исходное состояние не мутируется (модель неизменяемая).
      expect(s.byId('p1')!.roleAcknowledged, isFalse);
      expect(r.state!.byId('p2')!.roleAcknowledged, isFalse);
    });

    test('повторное подтверждение ничего не ломает', () {
      final s = state(players: [mk('p1', acked: true), mk('p2')]);
      final r = GameEngine.applyRoleAck(s, 'p1');
      expect(r.accepted, isFalse);
      expect(r.already, isTrue);
      // Сервер по этому флагу не должен писать лог второй раз.
      expect(r.reason, isNull);
    });

    test('неизвестный игрок — отказ, а не исключение', () {
      final r = GameEngine.applyRoleAck(state(), 'nobody');
      expect(r.accepted, isFalse);
      expect(r.reason, isNotNull);
    });

    test('игрок без роли (лобби) подтвердить не может', () {
      final s = state(phase: GamePhase.waiting, players: [
        const Player(id: 'p1', name: 'p1', colorHex: '#FFFFFF'),
      ]);
      final r = GameEngine.applyRoleAck(s, 'p1');
      expect(r.accepted, isFalse);
      expect(r.reason!.toLowerCase(), contains('роли'));
    });

    test('ночь начинается только в фазе раздачи и при 100%', () {
      final waiting = state(players: [mk('p1', acked: true), mk('p2')]);
      expect(GameEngine.canStartNight(waiting), isFalse);

      final ready = state(players: [mk('p1', acked: true), mk('p2', acked: true)]);
      expect(GameEngine.canStartNight(ready), isTrue);

      // Даже если все подтвердили, но фаза уже не rolesCheck —
      // начинать «первую ночь» повторно нельзя.
      final alreadyNight = state(
        phase: GamePhase.night,
        players: [mk('p1', acked: true), mk('p2', acked: true)],
      );
      expect(GameEngine.canStartNight(alreadyNight), isFalse);
    });

    test('ведущий видит имена тех, кого оставляет позади', () {
      final s = state(players: [
        mk('p1', acked: true),
        mk('p2'),
        mk('p3'),
      ]);
      expect(GameEngine.pendingRoleNames(s), ['p2', 'p3']);
    });
  });

  group('§2.3 — валидация состава (GameEngine.validateSetup)', () {
    Map<RoleType, int> setup({
      int mafia = 2,
      int don = 0,
      int doctor = 1,
      int commissioner = 1,
    }) =>
        {
          RoleType.mafia: mafia,
          RoleType.don: don,
          RoleType.doctor: doctor,
          RoleType.commissioner: commissioner,
        };

    test('корректный состав проходит', () {
      expect(
        GameEngine.validateSetup(setup: setup(), players: 8),
        isNull,
      );
    });

    test('специальных ролей больше, чем игроков — отказ', () {
      final err = GameEngine.validateSetup(
        setup: setup(mafia: 4, don: 1, doctor: 1, commissioner: 1),
        players: 6,
      );
      expect(err, contains('больше'));
    });

    test('меньше шести и больше двадцати — отказ', () {
      expect(GameEngine.validateSetup(setup: setup(), players: 5),
          contains('6'));
      expect(GameEngine.validateSetup(setup: setup(), players: 21),
          contains('20'));
    });

    test('без мафии играть нельзя', () {
      final err = GameEngine.validateSetup(
        setup: setup(mafia: 0, don: 0),
        players: 8,
      );
      expect(err, contains('мафиоз'));
    });

    test('мирных нельзя задать вручную', () {
      final err = GameEngine.validateSetup(
        setup: {...setup(), RoleType.civilian: 3},
        players: 8,
      );
      expect(err, contains('Мирных'));
    });

    test('отрицательное число ролей — отказ', () {
      final err = GameEngine.validateSetup(
        setup: {...setup(), RoleType.don: -1},
        players: 8,
      );
      expect(err, isNotNull);
    });

    test('состав, проходящий дальше, не считается ошибкой', () {
      // Ровно 6 специальных на 8 игроков — валидно, но баланс плохой.
      final s = setup(mafia: 3, don: 1, doctor: 1, commissioner: 1);
      expect(GameEngine.validateSetup(setup: s, players: 8), isNull);
      expect(GameEngine.balanceWarning(setup: s, players: 8), isNotNull);
    });

    test('предупреждение о балансе: город против одного игрока', () {
      expect(
        GameEngine.balanceWarning(
          setup: {RoleType.mafia: 5},
          players: 6,
        ),
        contains('проиграет'),
      );
    });

    test('предупреждение о балансе молчит на здоровом составе', () {
      expect(
        GameEngine.balanceWarning(
          setup: {RoleType.mafia: 2, RoleType.doctor: 1},
          players: 10,
        ),
        isNull,
      );
    });
  });

  group('§1.2 — первая ночь длиннее', () {
    test('первая ночь в 1.5 раза длиннее обычной', () {
      final players = [
        for (var i = 0; i < 3; i++)
          mk('m$i', role: RoleType.mafia),
        mk('c1'),
      ];
      final first = state(players: players, round: 1).nightDuration;
      final third = state(players: players, round: 3).nightDuration;
      expect(first, greaterThan(third));
      expect(first, (third * Rules.firstNightFactor).round());
    });

    test('первая ночь без активных ролей всё равно имеет запас', () {
      final s = state(players: [mk('p1'), mk('p2')], round: 1);
      expect(s.nightDuration, greaterThan(Rules.nightBaseSeconds));
    });
  });

  group('§2.1 — протокол партии (ProtocolExport)', () {
    test('заголовок, состав и хронология на месте', () {
      final text = ProtocolExport.build(
        name: 'Пятница',
        createdAt: DateTime(2026, 11, 10),
        rounds: 3,
        winnerTitle: 'Победили мирные',
        players: <Map<String, dynamic>>[
          {
            'name': 'Аня',
            'role': 'doctor',
            'isAlive': true,
          },
          {
            'name': 'Боря',
            'role': 'mafia',
            'isAlive': false,
          },
        ],
        log: [
          GameEvent(
            round: 1,
            phase: GamePhase.night,
            type: EventType.kill,
            text: 'Ночь 1: погиб Вася',
          ),
          GameEvent(
            round: 1,
            phase: GamePhase.day,
            type: EventType.info,
            text: 'День 1 начался',
          ),
        ],
      );

      expect(text, contains('Пятница'));
      expect(text, contains('10.11.2026'));
      expect(text, contains('Победили мирные'));
      expect(text, contains('Аня — Доктор (выжил)'));
      expect(text, contains('Боря — Мафия (выбыл)'));
      expect(text, contains('── Ночь 1 ──'));
      expect(text, contains('погиб Вася'));
      expect(text, contains('Ночь 1: погиб Вася'));
      // Секция дня — отдельным заголовком.
      expect(text, contains('── День 1 ──'));
    });

    test('скрытые события помечаются замком', () {
      final text = ProtocolExport.build(
        name: 'x',
        createdAt: DateTime(2026),
        rounds: 1,
        winnerTitle: '—',
        players: const [],
        log: [
          GameEvent(
            round: 1,
            phase: GamePhase.night,
            type: EventType.check,
            text: 'Проверка: Петя — мафия',
            visibleToPlayers: false,
          ),
        ],
      );
      expect(text, contains('🔒'));
      expect(text, contains('Проверка: Петя — мафия'));
    });

    test('скрытые события можно не печатать', () {
      final text = ProtocolExport.build(
        name: 'x',
        createdAt: DateTime(2026),
        rounds: 1,
        winnerTitle: '—',
        players: const [],
        log: [
          GameEvent(
            round: 1,
            phase: GamePhase.night,
            type: EventType.check,
            text: 'Проверка: Петя — мафия',
            visibleToPlayers: false,
          ),
        ],
        includeHidden: false,
      );
      expect(text, isNot(contains('Петя')));
    });

    test('пустая партия не падает', () {
      final text = ProtocolExport.build(
        name: '',
        createdAt: DateTime(2026),
        rounds: 0,
        winnerTitle: 'Не завершена',
        players: const [],
        log: const [],
      );
      expect(text, contains('Мафия'));
      expect(text, contains('Протокол пуст'));
    });

    test('новые роли 1.12.0 печатаются по-русски, а не служебным именем', () {
      // Ровно то, что пришло со скриншота: в истории лежит RoleType.name,
      // и после партии игроки видели «hunter», «blackmailer», «civilian».
      final text = ProtocolExport.build(
        name: 'x',
        createdAt: DateTime(2026),
        rounds: 1,
        winnerTitle: 'Победила мафия',
        players: <Map<String, dynamic>>[
          {'name': 'Снежана', 'role': 'hunter', 'isAlive': true},
          {'name': 'Кристина', 'role': 'blackmailer', 'isAlive': false},
          {'name': 'Гоша', 'role': 'witness', 'isAlive': true},
          {'name': 'Тимофей', 'role': 'bodyguard', 'isAlive': true},
          {'name': 'Ведущий', 'role': 'civilian', 'isAlive': true},
        ],
        log: const [],
      );
      expect(text, contains('Снежана — Охотник (выжил)'));
      expect(text, contains('Кристина — Шантажист (выбыл)'));
      expect(text, contains('Гоша — Свидетель (выжил)'));
      expect(text, contains('Тимофей — Телохранитель (выжил)'));
      expect(text, contains('Ведущий — Мирный житель (выжил)'));
      for (final wire in ['hunter', 'blackmailer', 'witness', 'bodyguard']) {
        expect(text, isNot(contains(wire)), reason: wire);
      }
    });

    test('счётчики в истории склоняются по-русски', () {
      // «7 раундов» и «20 игроков» читались в интерфейсе как ошибка.
      expect(HistoryScreen.roundsRu(1), '1 раунд');
      expect(HistoryScreen.roundsRu(2), '2 раунда');
      expect(HistoryScreen.roundsRu(5), '5 раундов');
      expect(HistoryScreen.roundsRu(7), '7 раундов');
      expect(HistoryScreen.roundsRu(11), '11 раундов');
      expect(HistoryScreen.roundsRu(21), '21 раунд');
      expect(HistoryScreen.roundsRu(22), '22 раунда');
      expect(HistoryScreen.playersRu(1), '1 игрок');
      expect(HistoryScreen.playersRu(3), '3 игрока');
      expect(HistoryScreen.playersRu(20), '20 игроков');
      expect(HistoryScreen.playersRu(0), '0 игроков');
      expect(HistoryScreen.playersRu(111), '111 игроков');
    });

    test('боты и ведущий помечены в протоколе', () {
      final text = ProtocolExport.build(
        name: 'С ботом',
        createdAt: DateTime(2026),
        rounds: 2,
        winnerTitle: 'Победила мафия',
        players: <Map<String, dynamic>>[
          {'name': 'Ведущий', 'role': 'civilian', 'isAlive': true, 'isLocal': true},
          {'name': 'Марк', 'role': 'mafia', 'isAlive': false, 'isBot': true},
          {'name': 'Аня', 'role': 'doctor', 'isAlive': true},
        ],
        log: const [],
      );
      expect(text, contains('Ведущий (ведущий) — Мирный житель (выжил)'));
      expect(text, contains('Марк (бот) — Мафия (выбыл)'));
      expect(text, contains('Аня — Доктор (выжил)'));
    });

    test('неизвестная роль не ломает вывод', () {
      final text = ProtocolExport.build(
        name: 'x',
        createdAt: DateTime(2026),
        rounds: 1,
        winnerTitle: '—',
        players: <Map<String, dynamic>>[
          {'name': 'Икс', 'role': 'some_new_role', 'isAlive': true},
        ],
        log: const [],
      );
      expect(text, contains('some_new_role'));
    });
  });

  group('§3.2 — версия протокола', () {
    test('пакет чужой версии не разбирается, но версия запоминается', () {
      final raw = jsonEncode({'v': 99, 'ts': 1, 'type': Msg.register});
      expect(Envelope.decode(raw), isNull);
      expect(Envelope.lastRejectedVersion, 99);
    });

    test('успешный разбор сбрасывает прошлую ошибку версии', () {
      Envelope.decode(jsonEncode({'v': 99, 'ts': 1, 'type': Msg.ping}));
      expect(Envelope.lastRejectedVersion, 99);

      final ok = Envelope.decode(
        jsonEncode({'v': Net.protocolVersion, 'ts': 1, 'type': Msg.ping}),
      );
      expect(ok, isNotNull);
      expect(Envelope.lastRejectedVersion, isNull);
    });

    test('битый JSON не считается проблемой версии', () {
      expect(Envelope.decode('{не json'), isNull);
      expect(Envelope.lastRejectedVersion, isNull);
    });

    test('причина отказа объявлена и не совпадает с другими', () {
      const all = {
        DenyReason.nameTaken,
        DenyReason.gameFull,
        DenyReason.gameStarted,
        DenyReason.badCode,
        DenyReason.badVersion,
      };
      expect(all.length, 5);
    });
  });

  group('§5.6 — deviceId в пакете register', () {
    test('deviceId доезжает до сервера как строка', () {
      final env = Envelope(Msg.register, {
        'name': 'Аня',
        'code': '123456',
        'deviceId': 'abc123def456',
      });
      final decoded = Envelope.decode(env.encode())!;
      expect(decoded.get<String>('deviceId'), 'abc123def456');
    });

    test('старый клиент без deviceId не ломает регистрацию', () {
      final decoded = Envelope.decode(
        jsonEncode({
          'v': Net.protocolVersion,
          'ts': 1,
          'type': Msg.register,
          'name': 'Аня',
        }),
      )!;
      expect(decoded.get<String>('deviceId'), isNull);
    });
  });

  group('§3.1 — правило «свой слот» (GameEngine.resolveRegister)', () {
    // Правило вынесено из HostController после релиза 1.0.6: там оно занимало
    // ~90 строк внутри сетевого обработчика и не было покрыто ни одним тестом.
    // Ошибка в порядке проверок стоит игроку роли посреди партии.

    Player named(String id, {String? device}) => Player(
          id: id,
          name: id,
          colorHex: '#FFFFFF',
          deviceId: device,
        );

    RegisterVerdict ask(
      GameState s, {
      required String name,
      String? deviceId,
      Set<String> online = const {},
    }) =>
        resolveRegister(
          name: name,
          deviceId: deviceId,
          state: s,
          isOnline: online.contains,
        );

    test('новое имя в лобби — создаём', () {
      final s = state(phase: GamePhase.waiting, players: [named('p1')]);
      expect(ask(s, name: 'Аня', online: {'p1'}), RegisterVerdict.create);
    });

    test('имя занято живым игроком с другого устройства — отказ', () {
      final s = state(phase: GamePhase.waiting, players: [named('Аня')]);
      expect(
        ask(s, name: 'Аня', deviceId: 'device-0002', online: {'Аня'}),
        RegisterVerdict.denyNameTaken,
      );
    });

    test('офлайн-слот без доказательства нельзя захватить по имени', () {
      final s = state(phase: GamePhase.waiting, players: [named('Аня')]);
      expect(ask(s, name: 'Аня', online: {}), RegisterVerdict.denyNameTaken);
    });

    test('тот же deviceId с другого устройства — слот его же', () {
      final s = state(
          phase: GamePhase.waiting, players: [named('Аня', device: 'device-0001')]);
      expect(
        ask(s, name: 'Аня', deviceId: 'device-0001', online: {'Аня'}),
        RegisterVerdict.reclaimOtherDevice,
      );
    });

    test('другой deviceId при живой связи — отказ, а не захват слота', () {
      final s = state(
          phase: GamePhase.waiting, players: [named('Аня', device: 'device-0001')]);
      expect(
        ask(s, name: 'Аня', deviceId: 'device-0002', online: {'Аня'}),
        RegisterVerdict.denyNameTaken,
      );
    });

    test('РЕГРЕССИЯ: посреди партии своё имя не блокируется фазой', () {
      // Главный смысл правила: возврат в свой слот проверяется ДО фазы.
      // Если порядок перепутать, игрок с разрядившимся телефоном получит
      // «игра уже началась» и потеряет роль.
      final s = state(phase: GamePhase.night, players: [named('Аня', device: 'device-0001')]);
      expect(ask(s, name: 'Аня', deviceId: 'device-0001', online: {}), RegisterVerdict.reclaim);
    });

    test('чужое имя посреди партии — «игра уже началась»', () {
      final s = state(phase: GamePhase.night, players: [named('Аня')]);
      expect(ask(s, name: 'Боря', online: {'Аня'}),
          RegisterVerdict.denyGameStarted);
    });

    test('фаза проверки ролей уже не пускает новых', () {
      final s = state(phase: GamePhase.rolesCheck, players: [named('Аня')]);
      expect(ask(s, name: 'Боря'), RegisterVerdict.denyGameStarted);
    });

    test('мест нет — game_full (а не nameTaken)', () {
      final s = state(
        phase: GamePhase.waiting,
        players: [for (var i = 0; i < Rules.maxPlayers; i++) named('p$i')],
      );
      expect(ask(s, name: 'Новый'), RegisterVerdict.denyGameFull);
    });

    test('имя сравнивается без учёта регистра и пробелов', () {
      final s = state(phase: GamePhase.waiting, players: [named('Аня')]);
      expect(
        ask(s, name: '  аня ', deviceId: 'x', online: {'Аня'}),
        RegisterVerdict.denyNameTaken,
      );
    });
  });
}
