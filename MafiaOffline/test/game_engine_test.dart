import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/core/assets.dart';
import 'package:mafia_offline/core/game_engine.dart';
import 'package:mafia_offline/core/role_guide.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/models/role.dart';
import 'package:mafia_offline/services/synced_audio.dart';

/// Сборка тестового состояния.
GameState buildState({
  required List<({String id, RoleType role, bool alive})> spec,
  Map<String, String?> actions = const {},
  String? lastHealed,
  String? lastGuarded,
  String? hunterMark,
  // Ночная фаза по умолчанию: списки целей (`legalTargetsFor`) вне ночи
  // пусты по правилам, и без этого тесты целей проверяли бы пустоту.
  GamePhase phase = GamePhase.night,
}) {
  return GameState(
    id: 'g1',
    name: 'test',
    code: '000000',
    createdAt: DateTime(2026),
    players: [
      for (final s in spec)
        Player(
          id: s.id,
          name: s.id,
          colorHex: '#FFFFFF',
          role: Role.fromType(s.role),
          isAlive: s.alive,
        ),
    ],
    phase: phase,
    nightActions: actions,
    lastHealedId: lastHealed,
    lastGuardedId: lastGuarded,
    hunterMarkId: hunterMark,
  );
}

void main() {
  final rnd = Random(42);

  group('Разрешение ночи', () {
    test('мафия убивает, доктор не успел', () {
      final s = buildState(
        spec: [
          (id: 'm1', role: RoleType.don, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'd1', role: RoleType.doctor, alive: true),
        ],
        actions: {'m1': 'c1', 'd1': 'd1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      // Классика (v1.1.0): доктор себя не лечит. Даже если клиент прислал
      // себя целью, лечение не срабатывает — правило на сервере.
      expect(o.killedIds, ['c1']);
      expect(o.healedId, isNull);
    });

    test('доктор не спасает сам себя', () {
      final s = buildState(
        spec: [
          (id: 'm1', role: RoleType.don, alive: true),
          (id: 'd1', role: RoleType.doctor, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
        ],
        actions: {'m1': 'd1', 'd1': 'd1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.healedId, isNull);
      expect(o.killedIds, contains('d1'));
    });

    test('доктор спасает цель мафии', () {
      final s = buildState(
        spec: [
          (id: 'm1', role: RoleType.don, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'd1', role: RoleType.doctor, alive: true),
        ],
        actions: {'m1': 'c1', 'd1': 'c1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.killedIds, isEmpty);
    });

    test('проститутка блокирует доктора — лечение не срабатывает', () {
      final s = buildState(
        spec: [
          (id: 'm1', role: RoleType.don, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'd1', role: RoleType.doctor, alive: true),
          (id: 'p1', role: RoleType.prostitute, alive: true),
        ],
        actions: {'m1': 'c1', 'd1': 'c1', 'p1': 'd1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.blockedId, 'd1');
      expect(o.healedId, isNull);
      expect(o.killedIds, ['c1']);
    });

    test('проститутка блокирует мафию — убийства нет', () {
      final s = buildState(
        spec: [
          (id: 'm1', role: RoleType.don, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'p1', role: RoleType.prostitute, alive: true),
        ],
        actions: {'m1': 'c1', 'p1': 'm1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.killedIds, isEmpty);
    });

    test('комиссар видит дона как мирного', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'maf', role: RoleType.mafia, alive: true),
          (id: 'com', role: RoleType.commissioner, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
        ],
        actions: {'com': 'don'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.checkResultIsMafia, isFalse);
    });

    test('комиссар вычисляет рядовую мафию', () {
      final s = buildState(
        spec: [
          (id: 'maf', role: RoleType.mafia, alive: true),
          (id: 'com', role: RoleType.commissioner, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
        ],
        actions: {'com': 'maf'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.checkResultIsMafia, isTrue);
    });

    test('доктор не лечит одну цель две ночи подряд', () {
      final s = buildState(
        spec: [
          (id: 'm1', role: RoleType.don, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'd1', role: RoleType.doctor, alive: true),
        ],
        actions: {'m1': 'c1', 'd1': 'c1'},
        lastHealed: 'c1',
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.healedId, isNull);
      expect(o.killedIds, ['c1']);
    });

    test('голос дона перевешивает голоса рядовой мафии', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'm1', role: RoleType.mafia, alive: true),
          (id: 'm2', role: RoleType.mafia, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
        ],
        actions: {'don': 'c2', 'm1': 'c1', 'm2': 'c1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.mafiaTargetId, 'c2');
    });

    test('маньяк и мафия убивают двоих за ночь', () {
      final s = buildState(
        spec: [
          (id: 'm1', role: RoleType.don, alive: true),
          (id: 'man', role: RoleType.maniac, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
          (id: 'c3', role: RoleType.civilian, alive: true),
        ],
        actions: {'m1': 'c1', 'man': 'c2'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.killedIds.length, 2);
      expect(o.killedIds, containsAll(['c1', 'c2']));
    });
  });

  // 1.12.0: телохранитель, свидетель, охотник и шантажист. Сценарии те
  // же, что в tools/roles112.py: правило, записанное в инструкции, должно
  // срабатывать одинаково в Dart и в порте на Python.
  group('Новые роли 1.12.0', () {
    test('щит забирает удар: погибает телохранитель, прикрытый жив', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'g1', role: RoleType.bodyguard, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
          (id: 'c3', role: RoleType.civilian, alive: true),
          (id: 'c4', role: RoleType.civilian, alive: true),
        ],
        actions: {'don': 'c1', 'g1': 'c1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.killedIds, ['g1']);
      expect(o.guardDiedId, 'g1');
      expect(o.guardedId, 'c1');
    });

    test('два удара в прикрытого — один погибший', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'man', role: RoleType.maniac, alive: true),
          (id: 'g1', role: RoleType.bodyguard, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
          (id: 'c3', role: RoleType.civilian, alive: true),
        ],
        actions: {'don': 'c1', 'man': 'c1', 'g1': 'c1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.killedIds, ['g1']);
    });

    test('стреляли в самого телохранителя — щит не спасает', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'g1', role: RoleType.bodyguard, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
          (id: 'c3', role: RoleType.civilian, alive: true),
          (id: 'c4', role: RoleType.civilian, alive: true),
        ],
        actions: {'don': 'g1', 'g1': 'c1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.killedIds, ['g1']);
    });

    test('доктор спасает и телохранителя, принявшего удар', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'g1', role: RoleType.bodyguard, alive: true),
          (id: 'd1', role: RoleType.doctor, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
          (id: 'c3', role: RoleType.civilian, alive: true),
        ],
        actions: {'don': 'c1', 'g1': 'c1', 'd1': 'g1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.killedIds, isEmpty);
      expect(o.healedId, 'g1');
      expect(o.guardDiedId, 'g1');
    });

    test('телохранитель не прикрывает себя и не повторяет цель', () {
      final s = buildState(
        spec: [
          (id: 'g1', role: RoleType.bodyguard, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
        ],
        lastGuarded: 'c2',
      );
      final targets = GameEngine.legalTargetsFor(s, s.players.first);
      expect(targets.map((p) => p.id), ['c1']);
    });

    test('заблокированный телохранитель не срабатывает', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'pros', role: RoleType.prostitute, alive: true),
          (id: 'g1', role: RoleType.bodyguard, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
          (id: 'c3', role: RoleType.civilian, alive: true),
        ],
        actions: {'pros': 'g1', 'g1': 'c1', 'don': 'c1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.killedIds, ['c1']);
    });

    test('свидетель видит, выходил ли объект из дома', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'wit', role: RoleType.witness, alive: true),
          (id: 'd1', role: RoleType.doctor, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
        ],
        actions: {'wit': 'd1', 'd1': 'c1', 'don': 'c1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.watchedId, 'd1');
      expect(o.watchedActed, isTrue);
    });

    test('про мирного свидетелю достаётся «не выходил»', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'wit', role: RoleType.witness, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
        ],
        actions: {'wit': 'c1', 'don': 'c2'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.watchedId, 'c1');
      expect(o.watchedActed, isFalse);
    });

    test('метка охотника действует только со следующей ночи', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'hun', role: RoleType.hunter, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
          (id: 'c3', role: RoleType.civilian, alive: true),
          (id: 'c4', role: RoleType.civilian, alive: true),
        ],
        actions: {'hun': 'c1', 'don': 'hun'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.killedIds, ['hun']);
      expect(o.revengeIds, isEmpty);
      expect(o.hunterMarkId, isNull,
          reason: 'мёртвый охотник метку не ставит');
    });

    test('созревшая метка забирает отмеченного вместе с охотником', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'hun', role: RoleType.hunter, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
          (id: 'c3', role: RoleType.civilian, alive: true),
        ],
        actions: {'don': 'hun'},
        hunterMark: 'c1',
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.killedIds, containsAll(['hun', 'c1']));
      expect(o.revengeIds, ['c1']);
    });

    test('охотник не метит мёртвого и себя', () {
      final s = buildState(
        spec: [
          (id: 'hun', role: RoleType.hunter, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: false),
        ],
      );
      final targets = GameEngine.legalTargetsFor(s, s.players.first);
      expect(targets.map((p) => p.id), ['c1']);
    });

    test('шантаж отнимает голос, но не ночной ход', () {
      final s = buildState(
        spec: [
          (id: 'maf', role: RoleType.mafia, alive: true),
          (id: 'bm', role: RoleType.blackmailer, alive: true),
          (id: 'd1', role: RoleType.doctor, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
        ],
        actions: {'bm': 'd1', 'd1': 'c1', 'maf': 'c2'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.silencedId, 'd1');
      expect(o.healedId, 'c1');
      expect(o.killedIds, ['c2']);
    });

    test('шантажист пугает только горожан', () {
      final s = buildState(
        spec: [
          (id: 'don', role: RoleType.don, alive: true),
          (id: 'bm', role: RoleType.blackmailer, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
        ],
      );
      final targets = GameEngine.legalTargetsFor(s, s.players[1]);
      expect(targets.map((p) => p.id), ['c1']);
    });

    test('запуганный не голосует, остальные голосуют', () {
      final s = buildState(
        spec: [
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
          (id: 'c3', role: RoleType.civilian, alive: true),
        ],
      ).copyWith(silencedId: 'c2', silencedRound: 1);
      expect(s.isSilencedNow(s.byId('c2')), isTrue);
      expect(s.voters.map((p) => p.id), isNot(contains('c2')));
      expect(s.voters.map((p) => p.id), contains('c1'));
    });

    test('шантаж кончается вместе со своим днём', () {
      // Шантаж живёт один день. Если бы проверка смотрела только на id,
      // запуганный в ночь 3 игрок молчал бы до конца партии: ни ошибки,
      // ни записи в логе — просто не голосует и всё.
      final base = buildState(
        spec: [
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
        ],
      ).copyWith(silencedId: 'c2', silencedRound: 3);

      final sameRound = base.copyWith(round: 3, phase: GamePhase.voting);
      expect(sameRound.isSilencedNow(sameRound.byId('c2')), isTrue);
      expect(sameRound.voters.map((p) => p.id), isNot(contains('c2')));

      final nextDay = base.copyWith(round: 4, phase: GamePhase.voting);
      expect(nextDay.isSilencedNow(nextDay.byId('c2')), isFalse);
      expect(nextDay.voters.map((p) => p.id), contains('c2'),
          reason: 'на следующий день голос возвращается');

      // Состояние из старой сессии: раунд шантажа не записан (0).
      final legacy = base.copyWith(silencedRound: 0, round: 9);
      expect(legacy.isSilencedNow(legacy.byId('c2')), isTrue,
          reason: 'старые сохранения не должны терять шантаж');
    });

    test('шантажист не стрелок: сам он никого не убивает', () {
      final s = buildState(
        spec: [
          (id: 'bm', role: RoleType.blackmailer, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
        ],
        actions: {'bm': 'c1'},
      );
      final o = GameEngine.resolveNight(s, random: rnd);
      expect(o.killedIds, isEmpty);
      expect(o.mafiaTargetId, isNull);
    });

    test('шантажист — часть мафии для «своих» и для победы', () {
      final s = buildState(
        spec: [
          (id: 'maf', role: RoleType.mafia, alive: true),
          (id: 'bm', role: RoleType.blackmailer, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
        ],
      );
      expect(s.mafiaSiders.map((p) => p.id), containsAll(['maf', 'bm']));
      final targets = GameEngine.legalTargetsFor(s, s.players.first);
      expect(targets.map((p) => p.id), ['c1'],
          reason: 'стрелок не видит шантажиста в целях');
    });

    test('город не побеждает, пока жив шантажист', () {
      final s = buildState(
        spec: [
          (id: 'bm', role: RoleType.blackmailer, alive: true),
          (id: 'c1', role: RoleType.civilian, alive: true),
          (id: 'c2', role: RoleType.civilian, alive: true),
        ],
      );
      expect(s.checkWinner(), isNull);
    });
  });

  group('Условия победы — классические (v1.1.0)', () {
    test('город побеждает, когда мафии не осталось', () {
      final s = buildState(spec: [
        (id: 'c1', role: RoleType.civilian, alive: true),
        (id: 'c2', role: RoleType.doctor, alive: true),
        (id: 'm1', role: RoleType.don, alive: false),
      ]);
      expect(s.checkWinner(), WinnerSide.civilians);
    });

    test('город НЕ победил, пока жив маньяк', () {
      // Отличие от 1.0.4: маньяк больше не «свой». Он одиночка,
      // и партия продолжается, пока он на столе.
      final s = buildState(spec: [
        (id: 'man', role: RoleType.maniac, alive: true),
        (id: 'c1', role: RoleType.civilian, alive: true),
        (id: 'm1', role: RoleType.don, alive: false),
      ]);
      expect(s.checkWinner(), isNull);
    });

    test('маньяк побеждает, оставшись один', () {
      final s = buildState(spec: [
        (id: 'man', role: RoleType.maniac, alive: true),
        (id: 'c1', role: RoleType.civilian, alive: false),
        (id: 'm1', role: RoleType.don, alive: false),
      ]);
      expect(s.checkWinner(), WinnerSide.maniac);
    });

    test('маньяк и мирный — партия продолжается', () {
      final s = buildState(spec: [
        (id: 'man', role: RoleType.maniac, alive: true),
        (id: 'c1', role: RoleType.civilian, alive: true),
      ]);
      expect(s.checkWinner(), isNull);
    });

    test('мафия побеждает при равенстве с городом', () {
      // Классика: 1 мафия и 1 мирный — город уже не может выгнать мафию.
      final s = buildState(spec: [
        (id: 'm1', role: RoleType.don, alive: true),
        (id: 'c1', role: RoleType.civilian, alive: true),
      ]);
      expect(s.checkWinner(), WinnerSide.mafia);
    });

    test('мафия побеждает при перевесе', () {
      final s = buildState(spec: [
        (id: 'm1', role: RoleType.don, alive: true),
        (id: 'm2', role: RoleType.mafia, alive: true),
        (id: 'c1', role: RoleType.civilian, alive: true),
      ]);
      expect(s.checkWinner(), WinnerSide.mafia);
    });

    test('состав 3 на 3 — победа мафии', () {
      // В 1.0.x этот расклад продолжался до последнего игрока. В классике
      // равенство уже победа мафии: город не может переголосовать.
      // Такой состав ловится предупреждением баланса на экране настройки.
      final s = buildState(spec: [
        (id: 'don', role: RoleType.don, alive: true),
        (id: 'm1', role: RoleType.mafia, alive: true),
        (id: 'm2', role: RoleType.mafia, alive: true),
        (id: 'doc', role: RoleType.doctor, alive: true),
        (id: 'com', role: RoleType.commissioner, alive: true),
        (id: 'pro', role: RoleType.prostitute, alive: true),
      ]);
      expect(s.checkWinner(), WinnerSide.mafia);
    });

    test('2 мафии на 3 мирных — партия продолжается', () {
      final s = buildState(spec: [
        (id: 'don', role: RoleType.don, alive: true),
        (id: 'm1', role: RoleType.mafia, alive: true),
        (id: 'doc', role: RoleType.doctor, alive: true),
        (id: 'com', role: RoleType.commissioner, alive: true),
        (id: 'pro', role: RoleType.prostitute, alive: true),
      ]);
      expect(s.checkWinner(), isNull);
    });

    test('маньяк не считается городом при подсчёте перевеса', () {
      // 1 мафия, 1 маньяк, 1 мирный: мафия НЕ побеждает — маньяк не её
      // противник в этом счёте, но и не союзник города.
      final s = buildState(spec: [
        (id: 'm1', role: RoleType.don, alive: true),
        (id: 'man', role: RoleType.maniac, alive: true),
        (id: 'c1', role: RoleType.civilian, alive: true),
      ]);
      // mafia=1, civilians=1 -> мафия сравнялась с городом.
      expect(s.checkWinner(), WinnerSide.mafia);
    });

    test('все погибли — ничья', () {
      final s = buildState(spec: [
        (id: 'm1', role: RoleType.don, alive: false),
        (id: 'c1', role: RoleType.civilian, alive: false),
      ]);
      expect(s.checkWinner(), WinnerSide.nobody);
    });
  });

  group('Раздача ролей', () {
    test('каждый игрок получает ровно одну роль', () {
      final players = [
        for (var i = 0; i < 8; i++)
          Player(id: 'p$i', name: 'P$i', colorHex: '#FFFFFF'),
      ];
      final result = GameEngine.assignRoles(
        players: players,
        setup: {
          RoleType.mafia: 1,
          RoleType.don: 1,
          RoleType.doctor: 1,
          RoleType.commissioner: 1,
        },
        random: Random(1),
      );
      expect(result.length, 8);
      expect(result.every((p) => p.role != null), isTrue);
      expect(result.where((p) => p.role?.type == RoleType.don).length, 1);
      // 4 специальные роли + 4 мирных = 8 игроков.
      expect(result.where((p) => p.role?.type == RoleType.civilian).length, 4);
      expect(result.where((p) => p.role?.type == RoleType.mafia).length, 1);
    });

    test('при нехватке игроков лишние роли отбрасываются', () {
      final players = [
        for (var i = 0; i < 3; i++)
          Player(id: 'p$i', name: 'P$i', colorHex: '#FFFFFF'),
      ];
      final result = GameEngine.assignRoles(
        players: players,
        setup: {
          RoleType.mafia: 2,
          RoleType.don: 1,
          RoleType.doctor: 1,
          RoleType.maniac: 1,
        },
        random: Random(2),
      );
      expect(result.length, 3);
      expect(result.every((p) => p.role != null), isTrue);
    });

    // Регресс 1.9.2. Пресет «2 мафии + дон» на 6 пришедших давал 3 мафии
    // против 3 города. `checkWinner` объявляет победу при mafia >= city,
    // поэтому партия заканчивалась в первую секунду: город не делал ни
    // одного хода, а ведущий видел «Игра окончена» сразу после раздачи.
    test('раздача не создаёт уже выигранную партию', () {
      // Все составы, которые реально бывают за столом: от 6 до 20 игроков
      // и оба пресета ведущего плюс крайности из редактора состава.
      final setups = <Map<RoleType, int>>[
        {
          RoleType.mafia: 2,
          RoleType.don: 1,
          RoleType.doctor: 1,
          RoleType.commissioner: 1,
          RoleType.prostitute: 1,
        },
        {
          RoleType.mafia: 4,
          RoleType.don: 1,
          RoleType.doctor: 1,
          RoleType.commissioner: 1,
          RoleType.prostitute: 1,
          RoleType.maniac: 1,
        },
        {RoleType.mafia: 8, RoleType.don: 1},
        {RoleType.mafia: 1},
        {RoleType.mafia: 3, RoleType.don: 1, RoleType.maniac: 1},
      ];

      for (final setup in setups) {
        for (var n = 6; n <= 20; n++) {
          final players = [
            for (var i = 0; i < n; i++)
              Player(id: 'p$i', name: 'P$i', colorHex: '#FFFFFF'),
          ];
          // Несколько сидов: раздача перемешивается, но баланс обязан
          // держаться при любом жребии.
          for (final seed in [1, 7, 42]) {
            final dealt = GameEngine.assignRoles(
              players: players,
              setup: setup,
              random: Random(seed),
            );
            final state = GameState(
              id: 'g',
              name: 't',
              code: '000000',
              createdAt: DateTime(2026),
              players: dealt,
            );
            expect(
              state.checkWinner(),
              isNull,
              reason: 'состав $setup на $n игроков (сид $seed): партия '
                  'выиграна до первого хода — $setup, мафии '
                  '${dealt.where((p) => p.role?.side == Side.mafia).length} '
                  'из $n',
            );
          }
        }
      }
    });

    test('мафии всегда остаётся меньше, чем города', () {
      // То же свойство, но напрямую по числам: если когда-нибудь кто-то
      // поменяет условие в assignRoles, тест покажет, где именно.
      for (var n = 6; n <= 20; n++) {
        final dealt = GameEngine.assignRoles(
          players: [
            for (var i = 0; i < n; i++)
              Player(id: 'p$i', name: 'P$i', colorHex: '#FFFFFF'),
          ],
          setup: {RoleType.mafia: 2, RoleType.don: 1},
          random: Random(3),
        );
        final mafia = dealt.where((p) => p.role?.side == Side.mafia).length;
        final maniac =
            dealt.where((p) => p.role?.type == RoleType.maniac).length;
        expect(mafia, lessThan(n - mafia - maniac),
            reason: '$n игроков: мафия $mafia против ${n - mafia - maniac}');
      }
    });
  });

  group('Подсчёт голосов', () {
    test('определение ничьей', () {
      final s = buildState(spec: [
        (id: 'a', role: RoleType.civilian, alive: true),
        (id: 'b', role: RoleType.civilian, alive: true),
        (id: 'c', role: RoleType.civilian, alive: true),
        (id: 'd', role: RoleType.civilian, alive: true),
      ]).copyWith(votes: {'a': 'c', 'b': 'd', 'c': 'd', 'd': 'c'});
      expect(s.voteLeaders.length, 2);
      expect(s.voteLeaders, containsAll(['c', 'd']));
    });

    test('воздержавшиеся не влияют на подсчёт', () {
      final s = buildState(spec: [
        (id: 'a', role: RoleType.civilian, alive: true),
        (id: 'b', role: RoleType.civilian, alive: true),
        (id: 'c', role: RoleType.civilian, alive: true),
      ]).copyWith(votes: {'a': 'c', 'b': null, 'c': null});
      expect(s.voteLeaders, ['c']);
      expect(s.voteTally['c'], 1);
    });
  });

  group('Синхронизация часов для общего звука', () {
    test('свежий замер принимается и даёт смещение', () {
      final s = SyncedAudio();
      final now = DateTime.now().millisecondsSinceEpoch;
      // Ping ушёл 30 мс назад, ведущий ответил своим временем.
      // Часы ведущего опережают наши на 5000 мс.
      s.onPong(sentAtLocal: now - 30, hostTime: now + 5000);
      expect(s.sampleCount, 1);
      // Смещение примерно +5000 мс (с точностью до половины rtt).
      expect(s.offsetMs, greaterThan(4900));
      expect(s.offsetMs, lessThan(5100));
    });

    test('устаревший замер (rtt > 5 с) отбрасывается', () {
      final s = SyncedAudio();
      // sentAtLocal из далёкого прошлого — rtt получится огромным.
      s.onPong(sentAtLocal: 1000, hostTime: 1000);
      expect(s.sampleCount, 0);
    });

    test('мусорные замеры отбрасываются', () {
      final s = SyncedAudio();
      s.onPong(sentAtLocal: 0, hostTime: 0);
      s.onPong(sentAtLocal: -5, hostTime: 100);
      expect(s.sampleCount, 0);
    });

    test('окно замеров не растёт бесконечно', () {
      final s = SyncedAudio();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < 60; i++) {
        s.onPong(sentAtLocal: now - 20, hostTime: now);
      }
      expect(s.sampleCount, lessThanOrEqualTo(24));
    });

    test('оценка становится надёжной после трёх замеров', () {
      final s = SyncedAudio();
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(s.isReliable, isFalse);
      for (var i = 0; i < 3; i++) {
        s.onPong(sentAtLocal: now - 20, hostTime: now);
      }
      expect(s.isReliable, isTrue);
    });

    test('фора растёт вместе с задержкой сети', () {
      final fast = SyncedAudio.leadTimeFor(10).inMilliseconds;
      final slow = SyncedAudio.leadTimeFor(400).inMilliseconds;
      expect(slow, greaterThan(fast));
      // И не уходит в бесконечность на совсем плохой сети.
      expect(SyncedAudio.leadTimeFor(9000).inMilliseconds, lessThanOrEqualTo(1500));
    });

    test('reset очищает накопленное', () {
      final s = SyncedAudio();
      final now = DateTime.now().millisecondsSinceEpoch;
      s.onPong(sentAtLocal: now - 20, hostTime: now);
      s.reset();
      expect(s.sampleCount, 0);
      expect(s.offsetMs, 0);
    });
  });

  group('Маскировка карты', () {
    test('карта дона и мафии — разные файлы', () {
      expect(A.card(RoleType.don), isNot(A.card(RoleType.mafia)));
    });

    test('карта-обманка совпадает с картой мирного жителя', () {
      expect(A.decoyCard, A.card(RoleType.civilian));
    });

    test('для каждой роли есть своя картинка', () {
      final paths = RoleType.values.map(A.card).toSet();
      expect(paths.length, RoleType.values.length);
      for (final p in paths) {
        expect(p, startsWith('assets/cards/'));
      }
    });
  });

  group('Справка по ролям', () {
    test('для каждой роли есть непустая памятка', () {
      for (final type in RoleType.values) {
        final g = RoleGuide.of(type);
        expect(g.goal, isNotEmpty, reason: type.name);
        expect(g.atNight, isNotEmpty, reason: type.name);
        expect(g.atDay, isNotEmpty, reason: type.name);
        expect(g.winCondition, isNotEmpty, reason: type.name);
      }
    });

    test('у мирного жителя честно написано, что ночью он спит', () {
      expect(RoleGuide.of(RoleType.civilian).atNight.toLowerCase(),
          contains('спите'));
    });

    test('дон предупреждён, что комиссар видит его мирным', () {
      expect(RoleGuide.of(RoleType.don).atDay.toLowerCase(),
          contains('мирного'));
    });

    test('маньяку честно сказано: он побеждает только один', () {
      // Правило вернулось к классике в 1.1.0: раньше памятка обещала
      // ему победу вместе с городом, и игрок играл по неверным правилам.
      final g = RoleGuide.of(RoleType.maniac);
      expect(g.winCondition.toLowerCase(), contains('единственным'));
      expect(g.goal.toLowerCase(), contains('за себя'));
      // Днём он маскируется под горожанина, а не «ищет мафию за город».
      expect(g.atDay.toLowerCase(), contains('обычный житель'));
    });
  });

  group('Подтверждение роли', () {
    test('по умолчанию роль не подтверждена', () {
      const p = Player(id: 'p1', name: 'Иван', colorHex: '#FFFFFF');
      expect(p.roleAcknowledged, isFalse);
    });

    test('флаг переживает copyWith', () {
      const p = Player(id: 'p1', name: 'Иван', colorHex: '#FFFFFF');
      final acked = p.copyWith(roleAcknowledged: true);
      expect(acked.roleAcknowledged, isTrue);
      expect(acked.copyWith(isConnected: false).roleAcknowledged, isTrue);
    });

    test('флаг сохраняется и читается из хранилища', () {
      const p = Player(
          id: 'p1',
          name: 'Иван',
          colorHex: '#FFFFFF',
          roleAcknowledged: true);
      final restored = Player.fromStorageJson(p.toStorageJson());
      expect(restored.roleAcknowledged, isTrue);
    });

    test('роль не утекает в публичные данные', () {
      const p = Player(
          id: 'p1',
          name: 'Иван',
          colorHex: '#FFFFFF',
          role: Role.don);
      expect(p.toPublicJson().containsKey('role'), isFalse);
      expect(p.toPublicJson().toString(), isNot(contains('don')));
    });
  });
}
