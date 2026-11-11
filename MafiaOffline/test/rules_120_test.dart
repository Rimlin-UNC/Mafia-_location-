import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/core/constants.dart';
import 'package:mafia_offline/core/game_engine.dart';
import 'package:mafia_offline/core/role_guide.dart';
import 'package:mafia_offline/core/story_deck.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/models/role.dart';
import 'package:mafia_offline/net/protocol.dart';
import 'package:mafia_offline/storage/app_prefs.dart';
import 'package:mafia_offline/storage/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Правила стола версии 1.2.0 (FR-9.1 … FR-9.6 в ТРАССИРУЕМОСТЬ.md):
/// ночь знакомства, последнее слово, личный результат проверки комиссара,
/// счётчик живых и сохранение всего этого между перезапусками.
///
/// Проверяется чистая логика. Те же сценарии на Python-порте гоняет
/// `tools/rules120.py` — названия проверок совпадают намеренно, чтобы
/// расхождение двух реализаций было видно сразу.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Player mk(
    String id,
    RoleType role, {
    bool alive = true,
    EliminationReason? reason,
  }) =>
      Player(
        id: id,
        name: id,
        colorHex: '#FFFFFF',
        role: Role.fromType(role),
        isAlive: alive,
        eliminationReason: reason,
      );

  /// Стол на десять человек со всеми ролями.
  List<Player> table() => [
        mk('don', RoleType.don),
        mk('maf', RoleType.mafia),
        mk('doc', RoleType.doctor),
        mk('com', RoleType.commissioner),
        mk('pro', RoleType.prostitute),
        mk('man', RoleType.maniac),
        mk('c1', RoleType.civilian),
        mk('c2', RoleType.civilian),
        mk('c3', RoleType.civilian),
        mk('c4', RoleType.civilian),
      ];

  GameState state({
    List<Player>? players,
    GamePhase phase = GamePhase.night,
    int round = 1,
    bool introNight = false,
    bool lastWord = true,
    bool privateCheck = true,
    Map<String, String?> actions = const {},
    List<CheckRecord> checks = const [],
    String? lastWordId,
  }) =>
      GameState(
        id: 'g1',
        name: 'Партия',
        code: '123456',
        createdAt: DateTime(2026),
        phase: phase,
        round: round,
        players: players ?? table(),
        introNight: introNight,
        lastWord: lastWord,
        privateCheck: privateCheck,
        nightActions: actions,
        checks: checks,
        lastWordId: lastWordId,
      );

  group('FR-9.1 — первая ночь — знакомство', () {
    test('первая ночь помечена как знакомство, вторая — уже нет', () {
      expect(state(introNight: true).isIntroNight, isTrue);
      expect(state(introNight: true, round: 2).isIntroNight, isFalse);
      // Настройка включена, но фаза другая — это не «ночь знакомства».
      expect(
        state(introNight: true, phase: GamePhase.day).isIntroNight,
        isFalse,
      );
    });

    test('настройка выключена — первая ночь обычная (как в 1.1.0)', () {
      final s = state();
      expect(s.isIntroNight, isFalse);
      expect(s.nightActive.length, 6);
    });

    test('ходит только комиссар', () {
      final s = state(introNight: true);
      expect(s.nightActive.map((p) => p.id), ['com']);
      expect(s.actsTonight(s.byId('don')!), isFalse);
      expect(s.actsTonight(s.byId('man')!), isFalse);
      expect(s.actsTonight(s.byId('doc')!), isFalse);
      expect(s.actsTonight(s.byId('pro')!), isFalse);
    });

    test('никто не погибает, даже если ход убийцы попал в состояние', () {
      // Защита на уровне движка, а не списка целей на экране: клиент из
      // кэша или «умелец» с консолью браузера ничего не добьются.
      final s = state(introNight: true, actions: {
        'don': 'c1',
        'maf': 'c1',
        'man': 'doc',
        'doc': 'c2',
        'pro': 'com',
        'com': 'maf',
      });
      final o = GameEngine.resolveNight(s, random: Random(1));
      expect(o.killedIds, isEmpty);
      expect(o.mafiaTargetId, isNull);
      expect(o.maniacTargetId, isNull);
      // Лечение не засчитано: иначе доктор «потратил» бы цель и не смог
      // лечить её во вторую, уже настоящую ночь.
      expect(o.healedId, isNull);
      // Блокировка не действует: проверка комиссара состоялась.
      expect(o.blockedId, isNull);
      expect(o.checkedId, 'maf');
      expect(o.checkResultIsMafia, isTrue);
    });

    test('без комиссара ночь проходит без проверки и без жертв', () {
      final s = state(introNight: true, players: [
        mk('don', RoleType.don),
        mk('maf', RoleType.mafia),
        mk('doc', RoleType.doctor),
        mk('c1', RoleType.civilian),
        mk('c2', RoleType.civilian),
        mk('c3', RoleType.civilian),
      ]);
      expect(s.nightActive, isEmpty);
      final o = GameEngine.resolveNight(s, random: Random(1));
      expect(o.killedIds, isEmpty);
      expect(o.checkedId, isNull);
      expect(checkRecordFor(s, o), isNull);
    });

    test('во вторую ночь мафия убивает как обычно', () {
      final s = state(introNight: true, round: 2, actions: {
        'don': 'c1',
        'maf': 'c1',
      });
      expect(s.nightActive.length, 6);
      final o = GameEngine.resolveNight(s, random: Random(1));
      expect(o.killedIds, ['c1']);
    });

    test('текст оглашения говорит о знакомстве, а не «обошлось без жертв»',
        () {
      final s = state(introNight: true);
      final text = GameEngine.announcement(s, const NightOutcome());
      expect(text, contains('знакомств'));
      expect(text, isNot(contains('обошлось')));
    });

    test('таймер ночи знакомства короче обычной первой ночи', () {
      // Ходит один человек, а не шестеро — ждать полторы минуты незачем.
      expect(
        state(introNight: true).nightDuration,
        lessThan(state().nightDuration),
      );
    });
  });

  group('FR-9.2 — последнее слово', () {
    test('даётся, если правило включено и партия продолжается', () {
      final players = table()
          .map((p) => p.id == 'c1'
              ? mk('c1', RoleType.civilian,
                  alive: false, reason: EliminationReason.voted)
              : p)
          .toList();
      final s = state(players: players, phase: GamePhase.voting);
      expect(shouldGiveLastWord(s), isTrue);
    });

    test('не даётся, если правило выключено', () {
      expect(
        shouldGiveLastWord(state(phase: GamePhase.voting, lastWord: false)),
        isFalse,
      );
    });

    test('не даётся, если изгнание закончило партию', () {
      // Выгнали единственного мафиози — сразу финал, речь не нужна.
      final s = state(phase: GamePhase.voting, players: [
        mk('don', RoleType.don, alive: false, reason: EliminationReason.voted),
        mk('c1', RoleType.civilian),
        mk('c2', RoleType.civilian),
        mk('c3', RoleType.civilian),
      ]);
      expect(s.checkWinner(), WinnerSide.civilians);
      expect(shouldGiveLastWord(s), isFalse);
    });

    test('длительность — константа, а не число в коде', () {
      expect(Rules.lastWordSeconds, 30);
      expect(TableRules.toWire(state())['lastWordSeconds'], 30);
    });

    test('copyWith: говорящий задаётся и снимается', () {
      final s = state(phase: GamePhase.day).copyWith(lastWordId: 'c1');
      expect(s.lastWordId, 'c1');
      // Обычный copyWith говорящего не теряет…
      expect(s.copyWith(timeLeft: 10).lastWordId, 'c1');
      // …а переход в следующую фазу снимает его явно.
      expect(s.copyWith(clearLastWord: true).lastWordId, isNull);
    });
  });

  group('FR-9.3 — комиссар видит результат своей проверки', () {
    test('запись о проверке создаётся из итога ночи', () {
      final s = state(round: 2, actions: {'com': 'maf'});
      final o = GameEngine.resolveNight(s, random: Random(1));
      final record = checkRecordFor(s, o)!;
      expect(record.round, 2);
      expect(record.commissionerId, 'com');
      expect(record.targetId, 'maf');
      expect(record.isMafia, isTrue);
    });

    test('дон на проверке — «не мафия» (ТЗ BR-7)', () {
      final s = state(round: 2, actions: {'com': 'don'});
      final o = GameEngine.resolveNight(s, random: Random(1));
      expect(checkRecordFor(s, o)!.isMafia, isFalse);
    });

    test('маньяк на проверке — «не мафия»', () {
      final s = state(round: 2, actions: {'com': 'man'});
      final o = GameEngine.resolveNight(s, random: Random(1));
      expect(checkRecordFor(s, o)!.isMafia, isFalse);
    });

    test('комиссар пропустил ход — записи нет', () {
      final s = state(round: 2, actions: {'com': null});
      final o = GameEngine.resolveNight(s, random: Random(1));
      expect(checkRecordFor(s, o), isNull);
    });

    test('заблокированный комиссар проверку не получает', () {
      final s = state(round: 2, actions: {'com': 'maf', 'pro': 'com'});
      final o = GameEngine.resolveNight(s, random: Random(1));
      expect(o.checkedId, isNull);
      expect(checkRecordFor(s, o), isNull);
    });

    test('комиссар убит этой же ночью — проверка всё равно его', () {
      // Запись строится по состоянию ДО применения смертей.
      final s = state(round: 2, actions: {
        'com': 'maf',
        'don': 'com',
        'maf': 'com',
      });
      final o = GameEngine.resolveNight(s, random: Random(1));
      expect(o.killedIds, contains('com'));
      expect(checkRecordFor(s, o)!.commissionerId, 'com');
    });

    test('игрок видит только свои проверки', () {
      final s = state(checks: const [
        CheckRecord(
            round: 1, commissionerId: 'com', targetId: 'maf', isMafia: true),
        CheckRecord(
            round: 2, commissionerId: 'com', targetId: 'c1', isMafia: false),
        CheckRecord(
            round: 2, commissionerId: 'other', targetId: 'don', isMafia: false),
      ]);
      expect(s.checksBy('com').length, 2);
      expect(s.checksBy('c1'), isEmpty);

      final wire = checksWireFor(s, 'com');
      expect(wire.length, 2);
      expect(wire.first, {'round': 1, 'name': 'maf', 'isMafia': true});
      // В пакете нет идентификаторов и ролей — только имя и ответ.
      expect(wire.first.containsKey('target'), isFalse);
      expect(checksWireFor(s, 'c1'), isEmpty);
    });

    test('в пакете проверки — актуальное имя после переименования', () {
      final players = table()
          .map((p) => p.id == 'maf' ? p.copyWith(name: 'Вася') : p)
          .toList();
      final s = state(players: players, checks: const [
        CheckRecord(
            round: 1, commissionerId: 'com', targetId: 'maf', isMafia: true),
      ]);
      expect(checksWireFor(s, 'com').single['name'], 'Вася');
    });

    test('тип пакета проверки объявлен в протоколе', () {
      expect(Msg.checkResult, 'check_result');
      final decoded = Envelope.decode(
        Envelope(Msg.checkResult, {
          'round': 1,
          'name': 'Вася',
          'isMafia': true,
        }).encode(),
      )!;
      expect(decoded.type, Msg.checkResult);
      expect(decoded.get<bool>('isMafia'), isTrue);
    });

    test('памятка комиссара говорит, где искать ответ', () {
      final guide = RoleGuide.of(RoleType.commissioner);
      expect(guide.atNight, contains('Моя роль'));
      // Старая формулировка обещала, что результат узнает только ведущий.
      expect(guide.atNight, isNot(contains('Ведущий узнает')));
    });

    test('CheckRecord: запись и чтение; мусор не роняет разбор', () {
      const r = CheckRecord(
          round: 3, commissionerId: 'com', targetId: 'c1', isMafia: false);
      final back = CheckRecord.tryParse(jsonDecode(jsonEncode(r.toJson())))!;
      expect(back.round, 3);
      expect(back.commissionerId, 'com');
      expect(back.targetId, 'c1');
      expect(back.isMafia, isFalse);

      expect(CheckRecord.tryParse(null), isNull);
      expect(CheckRecord.tryParse('строка'), isNull);
      expect(CheckRecord.tryParse({'by': 'com'}), isNull);
      expect(CheckRecord.tryParse({'by': 1, 'target': 'x'}), isNull);
    });
  });

  group('FR-9.4 — правила стола: описание и пакет для игроков', () {
    test('значения по умолчанию: слово и личная проверка включены', () {
      final s = GameState(
        id: 'g',
        name: 't',
        code: '000000',
        createdAt: DateTime(2026),
      );
      expect(s.introNight, isFalse);
      expect(s.lastWord, isTrue);
      expect(s.privateCheck, isTrue);
      expect(s.checks, isEmpty);
      expect(s.lastWordId, isNull);
    });

    test('пакет для игроков содержит все четыре правила', () {
      final wire = TableRules.toWire(
          state(introNight: true, lastWord: false, privateCheck: false));
      expect(wire['openCards'], isFalse);
      expect(wire['introNight'], isTrue);
      expect(wire['lastWord'], isFalse);
      expect(wire['privateCheck'], isFalse);
      // Пакет обязан кодироваться в JSON: он уходит в `lobby`.
      expect(() => jsonEncode(wire), returnsNormally);
    });

    test('описание для человека упоминает только включённое', () {
      final on = TableRules.describe(state(introNight: true));
      expect(on.any((l) => l.contains('знакомство')), isTrue);
      expect(on.any((l) => l.contains('последнее слово')), isTrue);
      expect(on.any((l) => l.contains('Моя роль')), isTrue);

      final off = TableRules.describe(
          state(lastWord: false, privateCheck: false));
      expect(off.any((l) => l.contains('знакомство')), isFalse);
      expect(off.any((l) => l.contains('последнее слово')), isFalse);
      expect(off.any((l) => l.contains('сообщает ведущий')), isTrue);
    });

    test('игрок читает те же строки, что и ведущий', () {
      // Экран «Правила» у игрока строится из пакета lobby.rules,
      // у ведущего — из состояния. Формулировки обязаны совпадать.
      for (final s in [
        state(),
        state(introNight: true),
        state(lastWord: false, privateCheck: false),
      ]) {
        expect(
          TableRules.describeWire(TableRules.toWire(s)),
          TableRules.describe(s),
        );
      }
    });

    test('ведущий 1.1.x правил не присылает — раздел пустой', () {
      expect(TableRules.describeWire(null), isEmpty);
    });

    test('неизвестное игроку правило читается как выключенное', () {
      // Пакет без ключей: клиент не обещает ни знакомства, ни слова.
      final lines = TableRules.describeWire(const {});
      expect(lines.any((l) => l.contains('знакомство')), isFalse);
      expect(lines.any((l) => l.contains('последнее слово')), isFalse);
      expect(lines.any((l) => l.contains('сообщает ведущий')), isTrue);
    });

    test('выбор правил запоминается до следующей партии', () async {
      final def = await AppPrefs.tableRules();
      expect(def.openCards, isFalse);
      expect(def.introNight, isFalse);
      expect(def.lastWord, isTrue);
      expect(def.privateCheck, isTrue);

      await AppPrefs.setTableRules(const TableRulePrefs(
        openCards: true,
        introNight: true,
        lastWord: false,
        privateCheck: false,
      ));
      final saved = await AppPrefs.tableRules();
      expect(saved.openCards, isTrue);
      expect(saved.introNight, isTrue);
      expect(saved.lastWord, isFalse);
      expect(saved.privateCheck, isFalse);
    });
  });

  group('FR-9.5 — сохранение партии переживает перезапуск', () {
    test('правила стола, проверки и говорящий сохраняются', () async {
      final s = state(
        phase: GamePhase.day,
        round: 2,
        introNight: true,
        lastWord: true,
        privateCheck: true,
        lastWordId: 'c1',
        checks: const [
          CheckRecord(
              round: 1, commissionerId: 'com', targetId: 'maf', isMafia: true),
        ],
      ).copyWith(
        storySeen: const ['first_night', 'exile'],
        noDeathsStreak: 1,
      );

      await SessionStore().save(s);
      final r = (await SessionStore().load())!;

      expect(r.introNight, isTrue);
      expect(r.lastWord, isTrue);
      expect(r.privateCheck, isTrue);
      expect(r.lastWordId, 'c1');
      expect(r.checks.single.targetId, 'maf');
      expect(r.checks.single.isMafia, isTrue);
      // До 1.2.0 эти два поля терялись: после перезапуска уже показанная
      // сюжетная карточка всплывала второй раз.
      expect(r.storySeen, ['first_night', 'exile']);
      expect(r.noDeathsStreak, 1);
    });

    test('сохранение из 1.1.x доигрывается по старым правилам', () async {
      // В старом сохранении новых полей нет. Партия начата без знакомства,
      // без таймера слова и с проверкой «через ведущего» — так и остаётся.
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
          'phase': 'night',
          'round': 1,
          'players': <Object>[],
        }),
      );
      final r = (await SessionStore().load())!;
      expect(r.introNight, isFalse);
      expect(r.lastWord, isFalse);
      expect(r.privateCheck, isFalse);
      expect(r.checks, isEmpty);
      expect(r.storySeen, isEmpty);
      expect(r.isIntroNight, isFalse);
    });

    test('битые записи проверок пропускаются, партия загружается', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'active_session_v1',
        jsonEncode({
          'savedAt': DateTime.now().millisecondsSinceEpoch,
          'id': 'g1',
          'name': 'Партия',
          'code': '111111',
          'createdAt': DateTime(2026).millisecondsSinceEpoch,
          'plannedPlayers': 6,
          'phase': 'day',
          'round': 2,
          'players': <Object>[],
          'checks': [
            {'round': 1, 'by': 'com', 'target': 'maf', 'isMafia': true},
            'мусор',
            {'round': 2},
          ],
          'storySeen': ['exile', 7, null],
        }),
      );
      final r = (await SessionStore().load())!;
      expect(r.checks.length, 1);
      expect(r.storySeen, ['exile']);
    });
  });

  group('FR-9.6 — сюжетные карточки: тихая ночь и приговор', () {
    test('«Тихая ночь» показывается, когда о ней сообщили', () {
      // До 1.2.0 карточка была в колоде, но условие никто не проверял.
      final s = state(round: 2);
      expect(StoryDeck.bestFor(s), isNull);
      expect(StoryDeck.bestFor(s, quietNight: true)?.id, 'quiet_night');
    });

    test('«Приговор» показывается после изгнания', () {
      final players = table()
          .map((p) => p.id == 'c1'
              ? mk('c1', RoleType.civilian,
                  alive: false, reason: EliminationReason.voted)
              : p)
          .toList();
      final s = state(players: players, phase: GamePhase.voting);
      expect(StoryDeck.bestFor(s, exile: true)?.id, 'exile');
    });

    test('после изгнания не читаем «этой ночью город потерял первого»', () {
      // С ночью знакомства первым выбывает изгнанный голосованием.
      // «Первая кровь» — карточка про ночь, здесь она не к месту.
      final players = table()
          .map((p) => p.id == 'c1'
              ? mk('c1', RoleType.civilian,
                  alive: false, reason: EliminationReason.voted)
              : p)
          .toList();
      final s = state(players: players, phase: GamePhase.voting);
      final ids = StoryDeck.candidatesFor(s, exile: true).map((c) => c.id);
      expect(ids, isNot(contains('first_blood')));
      // И позже, на следующее утро, тоже: первым был изгнанный.
      final morning = state(players: players, round: 2);
      expect(
        StoryDeck.candidatesFor(morning).map((c) => c.id),
        isNot(contains('first_blood')),
      );
    });

    test('ночное убийство по-прежнему даёт «Первую кровь»', () {
      final players = table()
          .map((p) => p.id == 'c1'
              ? mk('c1', RoleType.civilian,
                  alive: false, reason: EliminationReason.killed)
              : p)
          .toList();
      final s = state(players: players, round: 2);
      expect(StoryDeck.bestFor(s)?.id, 'first_blood');
    });

    test('показанная карточка не повторяется', () {
      final s = state(round: 2);
      expect(
        StoryDeck.bestFor(s, quietNight: true, seenIds: {'quiet_night'}),
        isNull,
      );
    });
  });
}
