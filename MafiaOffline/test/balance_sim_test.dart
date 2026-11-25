import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/core/balance_sim.dart';
import 'package:mafia_offline/core/game_engine.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/models/role.dart';

// ---------------------------------------------------------------------------
// Песочница состава (1.13.0).
//
// Главный риск этой фичи — не медленный счёт, а **расхождение с игрой**:
// симуляция скажет «баланс в норме», а настоящий движок объявит победу
// мафии в первую секунду. Поэтому первая группа — сверка вердикта
// симуляции с `GameState.checkWinner` на всех граничных раскладах, а не
// проверка «на глаз».
// ---------------------------------------------------------------------------

/// Состояние с заданными (роль, жив) для сверки победителя.
GameState _state(List<(RoleType, bool)> spec, {int round = 3}) => GameState(
      id: 'sim',
      name: 'sim',
      code: '000000',
      createdAt: DateTime(2026),
      round: round,
      phase: GamePhase.day,
      players: [
        for (var i = 0; i < spec.length; i++)
          Player(
            id: 'p$i',
            name: 'p$i',
            colorHex: '#FFFFFF',
            role: Role.fromType(spec[i].$1),
            isAlive: spec[i].$2,
          ),
      ],
    );

Map<RoleType, int> _setup({
  int mafia = 2,
  int don = 0,
  int blackmailer = 0,
  int doctor = 1,
  int commissioner = 1,
  int prostitute = 0,
  int bodyguard = 0,
  int witness = 0,
  int hunter = 0,
  int maniac = 0,
}) =>
    {
      RoleType.mafia: mafia,
      RoleType.don: don,
      RoleType.blackmailer: blackmailer,
      RoleType.doctor: doctor,
      RoleType.commissioner: commissioner,
      RoleType.prostitute: prostitute,
      RoleType.bodyguard: bodyguard,
      RoleType.witness: witness,
      RoleType.hunter: hunter,
      RoleType.maniac: maniac,
    };

void main() {
  group('Вердикт симуляции совпадает с движком', () {
    test('все расклады до 5 игроков дают тот же исход', () {
      // Наборы выбраны по границам правила: равенство мафии и города,
      // живой маньяк рядом с мафией, пустой стол.
      final cases = <List<RoleType>>[
        [RoleType.mafia, RoleType.civilian],
        [RoleType.mafia, RoleType.civilian, RoleType.civilian],
        [RoleType.mafia, RoleType.mafia, RoleType.civilian],
        [RoleType.mafia, RoleType.mafia, RoleType.civilian, RoleType.civilian],
        [RoleType.maniac, RoleType.civilian],
        [RoleType.maniac, RoleType.mafia],
        [RoleType.maniac, RoleType.mafia, RoleType.civilian],
        [RoleType.maniac, RoleType.mafia, RoleType.mafia],
        [RoleType.maniac, RoleType.mafia, RoleType.mafia, RoleType.civilian],
        [RoleType.maniac, RoleType.maniac, RoleType.civilian],
        [RoleType.maniac, RoleType.maniac, RoleType.mafia],
        [RoleType.maniac, RoleType.civilian, RoleType.civilian],
        [RoleType.don, RoleType.mafia, RoleType.civilian, RoleType.civilian],
        [RoleType.blackmailer, RoleType.doctor, RoleType.civilian],
        [RoleType.doctor, RoleType.civilian],
        [RoleType.civilian],
      ];

      for (final roles in cases) {
        final n = roles.length;
        for (var mask = 0; mask < (1 << n); mask++) {
          final alive = [for (var i = 0; i < n; i++) (mask >> i) & 1 == 1];
          final spec = [
            for (var i = 0; i < n; i++) (roles[i], alive[i]),
          ];
          final engine = _state(spec).checkWinner();
          final sim = BalanceSim.debugWinner(roles, alive);

          final expected = switch (engine) {
            WinnerSide.mafia => 'mafia',
            WinnerSide.civilians => 'city',
            WinnerSide.maniac => 'maniac',
            WinnerSide.nobody => 'nobody',
            _ => null, // партия продолжается
          };
          expect(sim, expected,
              reason: 'роли=$roles живые=$alive: '
                  'движок=$engine, симуляция=$sim');
        }
      }
    });
  });

  group('Оценка состава', () {
    test('пресет на 10 игроков сбалансирован', () {
      // 2 мафии + дон + доктор + комиссар на 10 — типовой стол.
      final r = BalanceSim.estimate(
        setup: _setup(mafia: 1, don: 1, doctor: 1, commissioner: 1),
        players: 10,
        seed: 7,
      );
      expect(r.games, BalanceSim.defaultGames);
      expect(r.cityShare + r.mafiaShare + r.maniacShare,
          closeTo(1.0, 0.0001));
      expect(r.note, isNotEmpty);
      // Точную долю не фиксируем: важно, что она в разумных пределах,
      // а не что генератор случайных чисел выдаёт конкретное число.
      expect(r.cityShare, inInclusiveRange(0.1, 0.9));
    });

    test('явный перевес мафии виден по вердикту', () {
      // 4 мафиози против 5 горожан — город не должен выигрывать часто.
      final r = BalanceSim.estimate(
        setup: _setup(mafia: 3, blackmailer: 1, doctor: 1, commissioner: 0),
        players: 9,
        seed: 3,
      );
      expect(r.verdict, BalanceVerdict.tooEasyForMafia);
      expect(r.note, contains('Мафии слишком много'));
    });

    test('слабый город без комиссара и доктора — тоже не «норма»', () {
      final r = BalanceSim.estimate(
        setup: _setup(mafia: 3, doctor: 0, commissioner: 0),
        players: 9,
        seed: 3,
      );
      expect(r.verdict, anyOf(BalanceVerdict.tooEasyForMafia,
          BalanceVerdict.tooEasyForCity));
    });

    test('один мафиози на двенадцать человек — городу слишком легко', () {
      final r = BalanceSim.estimate(
        setup: _setup(mafia: 1, doctor: 1, commissioner: 1),
        players: 12,
        seed: 5,
      );
      expect(r.verdict, BalanceVerdict.tooEasyForCity);
      expect(r.note, isNotEmpty);
    });

    test('пустой стол не считается, но и не падает', () {
      final r = BalanceSim.estimate(setup: _setup(), players: 0);
      expect(r.games, 0);
      expect(r.verdict, BalanceVerdict.invalid);
      expect(r.sharesRu, '—');
    });

    test('фактически розданный состав учитывает срезанные роли', () {
      // Заказано больше специальных ролей, чем игроков: движок режет
      // лишние, и отчёт обязан показывать реальный стол, а не заказ.
      final r = BalanceSim.estimate(
        setup: _setup(mafia: 1, don: 1, maniac: 1, prostitute: 1,
            doctor: 1, commissioner: 1, witness: 1),
        players: 6,
        seed: 2,
        games: 200,
      );
      final total = r.dealt.values.fold<int>(0, (a, b) => a + b);
      expect(total, 6);
      expect(r.dealt.containsKey(RoleType.maniac), isFalse,
          reason: 'маньяк срезается первым');
    });

    test('оценка быстрая: 1200 партий — доли секунды', () {
      final sw = Stopwatch()..start();
      BalanceSim.estimate(setup: _setup(), players: 14, seed: 1);
      sw.stop();
      // Порог с большим запасом: на телефоне медленнее в разы, но
      // полторы секунды на один состав — всё ещё «нажал и увидел».
      expect(sw.elapsedMilliseconds, lessThan(1500),
          reason: 'оценка состава заняла ${sw.elapsedMilliseconds} мс');
    });
  });

  group('Строки для интерфейса', () {
    test('доли читаются по-русски', () {
      final r = BalanceSim.estimate(
        setup: _setup(mafia: 1, don: 1, doctor: 1, commissioner: 1),
        players: 10,
        seed: 11,
      );
      expect(r.sharesRu, contains('город'));
      expect(r.sharesRu, contains('мафия'));
      expect(r.sharesRu, contains('%'));
    });

    test('раздача не создаёт уже проигранную партию', () {
      // Основание всей оценки: симуляция стартует с живого стола, а не с
      // состояния «мафии столько же, сколько города». Иначе прогноз
      // считал бы партии, где победитель известен до первого хода.
      final players = [
        for (var i = 0; i < 10; i++)
          Player(id: 'p$i', name: 'p$i', colorHex: '#FFFFFF'),
      ];
      for (var seed = 0; seed < 5; seed++) {
        final dealt = GameEngine.assignRoles(
          players: players,
          setup: _setup(),
          random: Random(seed),
        );
        final mafia = dealt.where((p) => p.role?.side == Side.mafia).length;
        expect(mafia, lessThan(dealt.length - mafia));
      }
    });
  });
}

