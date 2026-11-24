import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/core/bot_engine.dart';
import 'package:mafia_offline/core/constants.dart';
import 'package:mafia_offline/core/game_engine.dart';
import 'package:mafia_offline/core/lobby_plan.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/models/role.dart';

GameState _state(
  List<Player> players, {
  GamePhase phase = GamePhase.night,
  int round = 1,
  Map<String, String?> actions = const {},
  Map<String, String?> votes = const {},
  List<CheckRecord> checks = const [],
  String? verdictId,
}) =>
    GameState(
      id: 'bots-test',
      name: 'Боты',
      code: '000000',
      createdAt: DateTime(2026),
      players: players,
      phase: phase,
      round: round,
      nightActions: actions,
      votes: votes,
      checks: checks,
      verdictId: verdictId,
    );

/// [name] по умолчанию совпадает с id — так проще проверять голоса.
/// В тестах про реплики имена задаются отдельно: иначе бот честно назовёт
/// в реплике имя «doctor», и проверка «в тексте нет названий ролей»
/// провалится не из-за утечки роли, а из-за фикстуры.
Player _player(
  String id,
  RoleType type, {
  String? name,
  bool bot = false,
  bool local = false,
  bool alive = true,
}) =>
    Player(
      id: id,
      name: name ?? id,
      colorHex: '#FFFFFF',
      role: Role.fromType(type),
      isBot: bot,
      isLocal: local,
      isAlive: alive,
    );

/// Шесть игроков с человеческими именами: бот в реплике называет
/// собеседника по имени, а не по роли.
List<Player> _six() => [
      _player('human', RoleType.civilian, name: 'Вы', local: true),
      _player('mafia', RoleType.mafia, name: 'Марк', bot: true),
      _player('doctor', RoleType.doctor, name: 'Дина', bot: true),
      _player('commissioner', RoleType.commissioner, name: 'Кир', bot: true),
      _player('prostitute', RoleType.prostitute, name: 'Лера', bot: true),
      _player('maniac', RoleType.maniac, name: 'Макс', bot: true),
    ];

void main() {
  group('Добавление ботов в лобби', () {
    test('имена, id и цвета уникальны, флаги не теряются', () {
      var s = _state([], phase: GamePhase.waiting);
      s = BotEngine.addBots(s, 5);
      expect(s.bots.length, 5);
      expect(s.players.map((p) => p.id).toSet().length, 5);
      expect(s.players.map((p) => p.name).toSet().length, 5);
      expect(s.players.map((p) => p.colorHex).toSet().length, 5);
      expect(s.players.every((p) => p.isBot && p.isConnected), isTrue);
      expect(s.humans, isEmpty);
      expect(s.localPlayer, isNull);
    });

    test('лимит стола не нарушается даже большим запросом', () {
      var s = _state([], phase: GamePhase.waiting);
      s = BotEngine.addBots(s, 99);
      expect(s.players.length, Rules.maxPlayers);
      expect(s.bots.length, Rules.maxPlayers);
    });

    test('после старта ботов нельзя добавить', () {
      final s = _state(_six(), phase: GamePhase.night);
      expect(BotEngine.addBots(s, 3), same(s));
    });

    test('флаги бота и локального игрока переживают сохранение', () {
      final bot = _player('b1', RoleType.civilian, bot: true);
      final local = _player('l1', RoleType.don, local: true);
      final restoredBot = Player.fromStorageJson(bot.toStorageJson());
      final restoredLocal = Player.fromStorageJson(local.toStorageJson());
      expect(restoredBot.isBot, isTrue);
      expect(restoredBot.isLocal, isFalse);
      expect(restoredLocal.isLocal, isTrue);
      expect(restoredLocal.isBot, isFalse);
      expect(bot.toPublicJson()['isBot'], isTrue);
      expect(local.toPublicJson()['isLocal'], isTrue);
      expect(bot.toPublicJson().containsKey('role'), isFalse);
    });

    test('соло-день короткий, а обычный день не меняется', () {
      final solo = _state([
        _player('h', RoleType.civilian, local: true),
        ...List.generate(5, (i) => _player('b$i', RoleType.civilian, bot: true)),
      ]);
      final company = _state([
        _player('h1', RoleType.civilian),
        _player('h2', RoleType.civilian),
        ...List.generate(4, (i) => _player('b$i', RoleType.civilian, bot: true)),
      ]);
      expect(solo.dayDuration, Rules.soloDaySeconds);
      expect(company.dayDuration, 6 * Rules.dayPerPlayerSeconds);
    });
  });

  group('План лобби', () {
    test('пустой стол: кнопка неактивна и объясняет, что делать', () {
      const plan = LobbyPlan(players: 0, planned: 10, bots: 0);
      expect(plan.canStart, isFalse);
      expect(plan.startHint, contains('Играть одному'));
      expect(plan.startLabel, 'Ждём игроков');
      expect(plan.missing, Rules.minPlayers);
    });

    test('один человек без ботов: старт разрешён, но добираются боты', () {
      const plan = LobbyPlan(players: 1, planned: 10, bots: 0);
      expect(plan.canStart, isTrue);
      expect(plan.enough, isFalse);
      expect(plan.startLabel, 'Начать — добрать 5 ботов');
      expect(plan.startHint, 'При старте автоматически добавится 5 ботов');
    });

    test('склонение по числу не выдаёт «5 бота»', () {
      expect(botWord(1), 'бот');
      expect(botWord(2), 'бота');
      expect(botWord(4), 'бота');
      expect(botWord(5), 'ботов');
      expect(botWord(11), 'ботов');
      expect(botWord(21), 'бот');
      expect(botWord(22), 'бота');
      expect(LobbyPlan(players: 5, planned: 10, bots: 0).startLabel,
          'Начать — добрать 1 бот');
    });

    test('полный стол: обычная кнопка без упоминания ботов', () {
      const plan = LobbyPlan(players: 10, planned: 10, bots: 3);
      expect(plan.full, isTrue);
      expect(plan.startLabel, 'Старт игры — раздать роли');
      expect(plan.startHint, isNull);
      expect(plan.composition, 'людей: 7 · ботов: 3');
    });

    test('боты считаются за места, но одни за столом не играют', () {
      const plan = LobbyPlan(players: 6, planned: 10, bots: 6);
      expect(plan.enough, isTrue);
      expect(plan.humans, 0);
      // Партия из одних автоматов — это не игра, а наблюдение.
      expect(plan.canStart, isFalse);
      expect(plan.startHint, contains('Играть одному'));
      expect(plan.startLabel, contains('Играть одному'));
    });

    test('боты не выходят за размер стола, выбранный при создании', () {
      expect(botRoomFor(players: 5, planned: 8), 3);
      expect(botRoomFor(players: 8, planned: 8), 0);
      expect(botRoomFor(players: 8, planned: 0), Rules.maxPlayers - 8);
      // План больше жёсткого лимита не расширяет стол.
      expect(botRoomFor(players: 19, planned: 40), 1);
      expect(const LobbyPlan(players: 5, planned: 8, bots: 0).botRoom, 3);
    });

    test('человек + боты до полного стола: старт обычный', () {
      const plan = LobbyPlan(players: 6, planned: 6, bots: 5);
      expect(plan.humans, 1);
      expect(plan.canStart, isTrue);
      expect(plan.full, isTrue);
      expect(plan.startLabel, 'Старт игры — раздать роли');
    });
  });

  group('Ночные ходы', () {
    test('бот-мафия не стреляет по своей команде и не читает чужие роли', () {
      final players = [
        _player('don', RoleType.don, bot: true),
        _player('m1', RoleType.mafia, bot: true),
        _player('c1', RoleType.civilian),
        _player('c2', RoleType.doctor),
        _player('c3', RoleType.commissioner),
        _player('x', RoleType.maniac),
      ];
      final s = _state(players);
      final actions = BotEngine.nightActionsFor(s, Random(1));
      expect(actions.keys, containsAll(['don', 'm1']));
      final team = s.mafiaTeam.map((p) => p.id).toSet();
      expect(team, containsAll(['don', 'm1']));
      expect(team.contains(actions['don']), isFalse);
      expect(team.contains(actions['m1']), isFalse);
      expect(actions['don'], isNot('don'));
      expect(actions['m1'], isNot('m1'));
    });

    test('доктор, комиссар, проститутка и маньяк не выбирают себя', () {
      final s = _state(_six());
      final actions = BotEngine.nightActionsFor(s, Random(7));
      for (final id in ['doctor', 'commissioner', 'prostitute', 'maniac']) {
        expect(actions.keys, contains(id));
        expect(actions[id], isNot(id));
      }
    });

    test('доктор не повторяет прошлую цель', () {
      final s = _state(_six()).copyWith(lastHealedId: 'human');
      final actions = BotEngine.nightActionsFor(s, Random(11));
      expect(actions['doctor'], isNot('human'));
    });

    test('комиссар сначала проверяет тех, кого ещё не проверял', () {
      final s = _state(_six(), checks: const [
        CheckRecord(
          round: 1,
          commissionerId: 'commissioner',
          targetId: 'human',
          isMafia: false,
        ),
      ]);
      final actions = BotEngine.nightActionsFor(s, Random(3));
      expect(actions['commissioner'], isNot('human'));
    });

    // 1.12.0: боты четырёх новых ролей. Проверяем главное — они ходят
    // законно и не читают чужие роли (то есть не выбирают цель «по
    // настоящей роли», а по тем уликам, что есть у живого игрока).
    test('боты новых ролей ходят только по законным целям', () {
      final players = [
        _player('guard', RoleType.bodyguard, bot: true),
        _player('wit', RoleType.witness, bot: true),
        _player('hun', RoleType.hunter, bot: true),
        _player('bm', RoleType.blackmailer, bot: true),
        _player('m1', RoleType.mafia),
        _player('c1', RoleType.civilian),
        _player('c2', RoleType.civilian),
        _player('c3', RoleType.civilian),
      ];
      final s = _state(players);
      final actions = BotEngine.nightActionsFor(s, Random(5));
      for (final id in ['guard', 'wit', 'hun', 'bm']) {
        expect(actions.keys, contains(id), reason: id);
        final bot = s.byId(id)!;
        final legal =
            GameEngine.legalTargetsFor(s, bot).map((p) => p.id).toSet();
        expect(legal, contains(actions[id]), reason: id);
      }
      // Шантажист не пугает своих: мафия в его целях не появляется.
      expect(actions['bm'], isNot('m1'));
      expect(actions['bm'], isNot('bm'));
    });

    test('бот-телохранитель не прикрывает того, кого прикрывал вчера', () {
      final s = _state(_six()).copyWith(lastGuardedId: 'human');
      final guard = _player('guard', RoleType.bodyguard, bot: true);
      final s2 = _state([...s.players, guard])
          .copyWith(lastGuardedId: 'human');
      final actions = BotEngine.nightActionsFor(s2, Random(11));
      expect(actions['guard'], isNot('human'));
    });

    test('бот-свидетель не смотрит второй раз за тем же', () {
      final wit = _player('wit', RoleType.witness, bot: true);
      final s = _state([..._six(), wit]).copyWith(watchTargetId: 'human');
      final actions = BotEngine.nightActionsFor(s, Random(4));
      expect(actions['wit'], isNot('human'));
    });

    test('бот-охотник не метит себя и ходит законно', () {
      final hun = _player('hun', RoleType.hunter, bot: true);
      final s = _state([..._six(), hun]);
      final actions = BotEngine.nightActionsFor(s, Random(2));
      expect(actions['hun'], isNotNull);
      expect(actions['hun'], isNot('hun'));
    });

    test('бот-мафия считает шантажиста своим и не голосует против него', () {
      final players = [
        _player('m1', RoleType.mafia, bot: true),
        _player('don', RoleType.don),
        _player('bm', RoleType.blackmailer),
        _player('c1', RoleType.civilian),
        _player('c2', RoleType.civilian),
        _player('c3', RoleType.civilian),
        _player('c4', RoleType.civilian),
      ];
      final s = _state(players, phase: GamePhase.voting);
      final votes = BotEngine.votesFor(s, Random(3));
      expect(votes['m1'], isNot('bm'),
          reason: 'шантажист — свой, его не сдают');
      expect(votes['m1'], isNot('don'));
      // Голос всё равно отдан: мафия не воздерживается, когда есть город.
      expect(votes['m1'], isNotNull);
    });

    test('маньяк не может выбрать себя через общий список целей', () {
      final man = _player('maniac', RoleType.maniac, bot: true);
      final target = _player('c', RoleType.civilian);
      final s = _state([man, target]);
      final legal = GameEngine.legalTargetsFor(s, man);
      expect(legal.map((p) => p.id), isNot(contains('maniac')));
      expect(legal.single.id, 'c');
    });
  });

  group('Голоса', () {
    test('бот не голосует за себя и мафия не сдаёт свою команду', () {
      final s = _state(_six(), phase: GamePhase.voting);
      final votes = BotEngine.votesFor(s, Random(5));
      expect(votes.keys, containsAll(['mafia', 'doctor', 'commissioner',
          'prostitute', 'maniac']));
      for (final entry in votes.entries) {
        expect(entry.value, isNot(entry.key));
        if (entry.key == 'mafia') {
          expect(entry.value, isNot('mafia'));
        }
      }
    });

    test('комиссар голосует за найденную им мафию, а не за чистого', () {
      final players = [
        _player('commissioner', RoleType.commissioner, bot: true),
        _player('human', RoleType.civilian, local: true),
        _player('mafia', RoleType.mafia),
        _player('c1', RoleType.civilian),
      ];
      final s = _state(players, phase: GamePhase.voting, checks: const [
        CheckRecord(
          round: 1,
          commissionerId: 'commissioner',
          targetId: 'mafia',
          isMafia: true,
        ),
        CheckRecord(
          round: 2,
          commissionerId: 'commissioner',
          targetId: 'human',
          isMafia: false,
        ),
      ]);
      final votes = BotEngine.votesFor(s, Random(19));
      expect(votes['commissioner'], 'mafia');
    });

    test('в повторном голосовании мафия не голосует против своего', () {
      // Обвиняемый — дон, то есть свой для бота-мафии. Такой бот в туре
      // участвует (обвиняемый — не он), но «выгнать» не выбирает.
      final players = [
        _player('human', RoleType.civilian, name: 'Вы', local: true),
        _player('mafia', RoleType.mafia, name: 'Марк', bot: true),
        _player('don', RoleType.don, name: 'Гоша', bot: true),
        _player('doctor', RoleType.doctor, name: 'Дина', bot: true),
        _player('commissioner', RoleType.commissioner, name: 'Кир', bot: true),
      ];
      final s = _state(players, phase: GamePhase.voting, verdictId: 'don');
      final votes = BotEngine.votesFor(s, Random(23));
      expect(votes.containsKey('mafia'), isTrue);
      expect(votes['mafia'], isNull);
    });

    test('в повторном голосовании можно и согласиться выгнать', () {
      // Не «всегда оставить»: иначе повторное голосование теряет смысл.
      // Доктор чист по проверке комиссара, но у остальных есть шанс
      // проголосовать за выгон — проверяем, что такие голоса бывают.
      var kicks = 0;
      for (var seed = 0; seed < 40; seed++) {
        final s = _state(_six(), phase: GamePhase.voting, verdictId: 'doctor');
        final votes = BotEngine.votesFor(s, Random(seed));
        kicks += votes.values.where((v) => v == 'doctor').length;
      }
      expect(kicks, greaterThan(0));
    });

    test('во втором туре нельзя проголосовать вне списка кандидатов', () {
      final s = _state(_six(), phase: GamePhase.voting).copyWith(
        runoffCandidates: ['human', 'doctor'],
      );
      final votes = BotEngine.votesFor(s, Random(31));
      for (final target in votes.values) {
        if (target != null) {
          expect(['human', 'doctor'], contains(target));
        }
      }
    });
  });

  group('Дневные реплики', () {
    test('комиссар сообщает только о собственной найденной мафии', () {
      final s = _state(_six(), phase: GamePhase.day, checks: const [
        CheckRecord(
          round: 1,
          commissionerId: 'commissioner',
          targetId: 'mafia',
          isMafia: true,
        ),
      ]);
      final lines = BotEngine.dayLinesFor(s, Random(1));
      final own = lines.firstWhere((l) => l.playerId == 'commissioner');
      expect(own.text, contains('Марк'));
      expect(own.text.toLowerCase(), contains('мафия'));
      expect(lines.length, lessThanOrEqualTo(3));
      expect(lines.map((l) => l.playerId).toSet().length, lines.length);
    });

    test('реплики не содержат названий чужих ролей', () {
      final s = _state(_six(), phase: GamePhase.day);
      final lines = BotEngine.dayLinesFor(s, Random(9));
      expect(lines, isNotEmpty);
      for (final line in lines) {
        for (final role in RoleType.values) {
          expect(line.text.toLowerCase(), isNot(contains(role.name)));
        }
      }
    });
  });

  group('Полная партия без сервера', () {
    /// Один раунд «ночь → голосование» на чистом движке.
    ///
    /// Это НЕ копия HostController: здесь нет последнего слова, второго
    /// тура, таймеров и пауз. Цель теста — убедиться, что правила ночи и
    /// голосования вместе с ботами всегда приводят партию к финалу и не
    /// зависают на пустом списке целей.
    test('100 соло-игр завершаются без зависания и нарушения инвариантов',
        () {
      final wins = <String, int>{};
      for (var game = 0; game < 100; game++) {
        final rnd = Random(1000 + game);
        var base = _state(
          [_player('human', RoleType.civilian, name: 'Вы', local: true)],
          phase: GamePhase.waiting,
        );
        base = BotEngine.addBots(base, 5);
        final dealt = GameEngine.assignRoles(
          players: base.players,
          setup: const {
            RoleType.mafia: 1,
            RoleType.doctor: 1,
            RoleType.commissioner: 1,
          },
          random: rnd,
        );
        var s = base.copyWith(players: dealt);
        var ended = false;

        for (var round = 1; round <= 30; round++) {
          s = s.copyWith(
            phase: GamePhase.night,
            round: round,
            nightActions: const {},
            votes: const {},
            runoffCandidates: const [],
            clearVerdict: true,
            clearLastWord: true,
          );

          // Ход «человека»: первый законный вариант. Если ходить нечем
          // (мирный житель), действий просто нет.
          final human = s.localPlayer!;
          final humanTargets = GameEngine.legalTargetsFor(s, human);
          // Ходить нечем (доктор уже лечил единственного живого соседа) —
          // человек нажимает «Пропустить»: это тоже законный ход.
          final actions = <String, String?>{
            if (s.actsTonight(human))
              human.id:
                  humanTargets.isEmpty ? null : humanTargets.first.id,
          };
          actions.addAll(BotEngine.nightActionsFor(
            s.copyWith(nightActions: actions),
            rnd,
          ));
          s = s.copyWith(nightActions: actions);
          expect(s.allNightActionsIn, isTrue,
              reason: 'партия $game, ночь $round: кто-то так и не сходил');

          final outcome = GameEngine.resolveNight(s, random: rnd);
          var players = s.players;
          for (final id in outcome.killedIds) {
            players = players
                .map((p) => p.id == id ? p.copyWith(isAlive: false) : p)
                .toList();
          }
          final record = checkRecordFor(s, outcome);
          s = s.copyWith(
            players: players,
            lastHealedId: outcome.healedId,
            clearLastHealed: outcome.healedId == null,
            checks: record == null ? s.checks : [...s.checks, record],
          );
          final afterNight = s.checkWinner();
          if (afterNight != null) {
            wins[afterNight.name] = (wins[afterNight.name] ?? 0) + 1;
            ended = true;
            break;
          }

          // День: голосование без последнего слова и второго тура.
          s = s.copyWith(phase: GamePhase.voting, votes: const {});
          final alive = s.alive;
          final humanVoter = s.localPlayer!;
          final voteTargets = GameEngine.legalTargetsFor(s, humanVoter);
          final votes = <String, String?>{
            if (humanVoter.isAlive)
              humanVoter.id:
                  voteTargets.isEmpty ? null : voteTargets.first.id,
          };
          votes.addAll(BotEngine.votesFor(
            s.copyWith(votes: votes),
            rnd,
          ));
          s = s.copyWith(votes: votes);
          expect(s.votes.length, lessThanOrEqualTo(alive.length));
          for (final entry in s.votes.entries) {
            if (entry.value != null) {
              expect(entry.value, isNot(entry.key),
                  reason: 'партия $game: голос за себя');
            }
          }

          final tally = s.voteTally;
          String? eliminated;
          if (tally.isNotEmpty) {
            final max = tally.values.reduce((a, b) => a > b ? a : b);
            final leaders = tally.entries
                .where((e) => e.value == max)
                .map((e) => e.key)
                .toList();
            if (leaders.length == 1) eliminated = leaders.first;
          }
          if (eliminated != null) {
            s = s.copyWith(players: [
              for (final p in s.players)
                if (p.id == eliminated) p.copyWith(isAlive: false) else p,
            ]);
          }
          final afterDay = s.checkWinner();
          if (afterDay != null) {
            wins[afterDay.name] = (wins[afterDay.name] ?? 0) + 1;
            ended = true;
            break;
          }
        }

        expect(ended, isTrue, reason: 'партия $game не завершилась за 30 раундов');
        expect(s.alive, isNotEmpty);
        expect(s.players.map((p) => p.id).toSet().length, s.players.length);
      }
      // Каждая партия закончилась победой одной из сторон или «никого».
      expect(wins.values.reduce((a, b) => a + b), 100);
      // Раскладка побед печатается в отчёте: по ней видно, не отдаёт ли
      // движок победу одной стороне всегда. Жёсткое требование здесь
      // не ставим — это тест на зависание, а не на баланс.
      // ignore: avoid_print
      print('Итоги 100 соло-партий: $wins');
    });
  });

  group('Защита слотов', () {
    test('по имени бота нельзя войти в его слот', () {
      final s = _state([_player('b', RoleType.don, bot: true)],
          phase: GamePhase.waiting);
      expect(
        resolveRegister(
          name: 'b',
          deviceId: null,
          state: s,
          isOnline: (_) => false,
        ),
        RegisterVerdict.denyNameTaken,
      );
    });

    test('по имени локального игрока нельзя получить его роль', () {
      final s = _state([_player('l', RoleType.don, local: true)],
          phase: GamePhase.waiting);
      expect(
        resolveRegister(
          name: 'l',
          deviceId: null,
          state: s,
          isOnline: (_) => false,
        ),
        RegisterVerdict.denyNameTaken,
      );
    });
  });
}
