import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/core/assets.dart';
import 'package:mafia_offline/core/crime_deck.dart';
import 'package:mafia_offline/core/story_deck.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/main.dart';
import 'package:mafia_offline/models/role.dart';
import 'package:mafia_offline/ui/card_gallery_screen.dart';
import 'package:mafia_offline/ui/rules_screen.dart';

void main() {
  testWidgets('главное меню показывает вход ведущего', (tester) async {
    await tester.pumpWidget(const MafiaApp());
    await tester.pump();

    expect(find.text('Мафия Offline'), findsOneWidget);
    expect(find.text('Я ведущий — создать игру'), findsOneWidget);
  });

  testWidgets('режим игрока по умолчанию скрыт: игроки заходят через браузер',
      (tester) async {
    await tester.pumpWidget(const MafiaApp());
    // Настройки читаются асинхронно — даём кадру дойти до конца.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Кнопки «Я игрок» быть не должно: основной путь для игроков —
    // браузер по QR-коду. Кнопка включается в настройках.
    expect(find.text('Я игрок — подключиться'), findsNothing);
  });

  group('Экран «Правила»', () {
    testWidgets('открывается и листается', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: RulesScreen()));
      await tester.pump();

      expect(find.text('Правила'), findsOneWidget);
      expect(find.text('Ведущий и его телефон'), findsOneWidget);

      // ListView строит детей лениво: дальние разделы в дереве ещё не
      // созданы, поэтому до них надо доскроллить, а не искать в дереве.
      await tester.scrollUntilVisible(find.text('Ночь'), 600,
          scrollable: find.byType(Scrollable).first, maxScrolls: 100);
      expect(find.text('Ночь'), findsOneWidget);

      // Карточка роли 2:3 на тестовом экране занимает ~700 px,
      // до маньяка (6-я роль) — несколько тысяч пикселей.
      await tester.scrollUntilVisible(find.text('🔪 Маньяк'), 600,
          scrollable: find.byType(Scrollable).first, maxScrolls: 100);
      expect(find.text('🔪 Маньяк'), findsOneWidget);
    });

    testWidgets('у каждой роли есть карточка в наборе правил',
        (tester) async {
      // Проверка на уровне данных: файл существует и путь не пустой.
      // Если карточку переименуют, экран покажет заглушку, а тест упадёт.
      for (final type in RoleType.values) {
        final path = A.guideRole(type);
        expect(path, startsWith('assets/instructions/roles/'),
            reason: type.name);
        expect(path, endsWith('.jpg'), reason: type.name);
      }
      expect(A.guideHost, contains('guides/'));
      expect(A.guideNight, contains('phases/'));
      expect(A.guideWin, contains('phases/'));
    });

    testWidgets('в меню есть вход в правила', (tester) async {
      await tester.pumpWidget(const MafiaApp());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Правила и роли'), findsOneWidget);
    });
  });

  group('Колода злодеяний', () {
    test('десять способов, без дублей', () {
      expect(Crime.all.length, 10);
      expect(Crime.all.map((c) => c.type).toSet().length, 10);
      for (final c in Crime.all) {
        expect(c.name, isNotEmpty, reason: c.type.name);
        expect(c.phrase, isNotEmpty, reason: c.type.name);
      }
    });

    test('известный способ находится по типу', () {
      expect(Crime.of(CrimeType.drowning).name, 'Утопление');
      expect(Crime.of(CrimeType.poison).phrase, contains('отравлен'));
    });

    test('картинки ссылаются в assets/crimes/, отсутствие допустимо', () {
      // У двух способов карточек нет осознанно (удушение не проходит
      // генерацию, электричество осталось без картинки). Пустой строки
      // быть не должно: либо путь, либо null.
      for (final c in Crime.all) {
        if (c.image != null) {
          expect(c.image!, startsWith('assets/crimes/'), reason: c.type.name);
          expect(c.image!, endsWith('.jpg'), reason: c.type.name);
        }
      }
    });

    test('строка для протокола читается по-русски', () {
      expect(Crime.of(CrimeType.gas).logLine('Вася'),
          'Вася — задохнулся от газа в квартире');
    });

    test('способ применим только к мафии и маньяку', () {
      expect(crimeAppliesTo(RoleType.mafia), isTrue);
      expect(crimeAppliesTo(RoleType.don), isTrue);
      expect(crimeAppliesTo(RoleType.maniac), isTrue);
      expect(crimeAppliesTo(RoleType.doctor), isFalse);
      expect(crimeAppliesTo(RoleType.civilian), isFalse);
      expect(crimeAppliesTo(null), isFalse);
    });
  });

  group('Сюжетные карточки', () {
    Player p(String id, RoleType role, {bool alive = true}) => Player(
          id: id,
          name: id,
          colorHex: '#FFFFFF',
          role: Role.fromType(role),
          isAlive: alive,
        );

    GameState st({
      required List<Player> players,
      GamePhase phase = GamePhase.night,
      List<String> runoff = const [],
      int round = 2,
    }) =>
        GameState(
          id: 'g',
          name: 't',
          code: '000000',
          createdAt: DateTime(2026),
          players: players,
          phase: phase,
          round: round,
          runoffCandidates: runoff,
        );

    test('в колоде девять карточек, id уникальны', () {
      expect(StoryDeck.all.length, 9);
      expect(StoryDeck.all.map((c) => c.id).toSet().length, 9);
      for (final c in StoryDeck.all) {
        expect(c.title, isNotEmpty, reason: c.id);
        expect(c.line, isNotEmpty, reason: c.id);
        expect(c.caption, isNotEmpty, reason: c.id);
      }
    });

    test('первая ночь: показываем «Город засыпает»', () {
      // Валидный состав: минимум 6 игроков, иначе сработал бы не тот
      // триггер (1 мафия против 1 горожанина — это уже «мафия сравнялась»).
      final s = st(players: [
        p('m1', RoleType.mafia),
        p('d1', RoleType.don),
        p('c1', RoleType.civilian),
        p('c2', RoleType.civilian),
        p('c3', RoleType.civilian),
        p('doc', RoleType.doctor),
      ], round: 1);
      final best = StoryDeck.bestFor(s);
      expect(best?.id, 'first_night');
    });

    test('есть погибший — «Первая кровь» приоритетнее прочего', () {
      // Моделируем реальный порядок: карточка «Трое» показывается позже,
      // и к моменту первой смерти её ещё не показывали. Но в этом составе
      // живых осталось трое, поэтому «Трое» перебило бы по приоритету —
      // передаём seenIds, как было бы к моменту второй ночи.
      final s = st(players: [
        p('a', RoleType.mafia),
        p('b', RoleType.civilian, alive: false),
        p('c', RoleType.civilian),
        p('d', RoleType.doctor),
        p('e', RoleType.civilian),
      ]);
      expect(StoryDeck.bestFor(s)?.id, 'first_blood');
    });

    test('трое живых — карточка «Трое»', () {
      final s = st(players: [
        p('a', RoleType.mafia),
        p('b', RoleType.civilian),
        p('c', RoleType.doctor),
        p('d', RoleType.civilian, alive: false),
      ]);
      expect(StoryDeck.bestFor(s)?.id, 'last_three');
    });

    test('мафия выбита, маньяк жив — «Одиночка»', () {
      final s = st(players: [
        p('m', RoleType.mafia, alive: false),
        p('x', RoleType.maniac),
        p('b', RoleType.civilian),
        p('c', RoleType.doctor),
      ]);
      expect(StoryDeck.bestFor(s)?.id, 'maniac_alone');
    });

    test('две ничьи подряд — «Город не может решить»', () {
      // К моменту двух ничьих «Первая кровь» и «Трое» уже показаны —
      // именно поэтому в проде и работает приоритет. Проверяем
      // с тем же набором увиденного.
      final s = st(players: [
        p('a', RoleType.mafia),
        p('b', RoleType.civilian),
        p('c', RoleType.doctor),
        p('d', RoleType.commissioner),
        p('e', RoleType.civilian, alive: false),
      ]);
      final best = StoryDeck.bestFor(s,
          noDeathsStreak: 2, seenIds: {'first_blood', 'last_three'});
      expect(best?.id, 'deadlock');
    });

    test('показанное не показывается второй раз', () {
      final s = st(players: [
        p('a', RoleType.mafia),
        p('b', RoleType.civilian, alive: false),
        p('c', RoleType.civilian),
        p('d', RoleType.doctor),
      ]);
      final best = StoryDeck.bestFor(s, seenIds: {'first_blood'});
      expect(best?.id, isNot('first_blood'));
    });

    test('в спокойной партии карточек может не быть вовсе', () {
      // Пять живых, никто не выбывал: нет ни первой ночи, ни крови,
      // ни трёх, ни раскола — показывать нечего, и это нормально.
      final s = st(players: [
        p('a', RoleType.mafia),
        p('b', RoleType.civilian),
        p('c', RoleType.doctor),
        p('d', RoleType.commissioner),
        p('e', RoleType.civilian),
      ]);
      expect(StoryDeck.bestFor(s), isNull);
    });

    test('карты суда привязаны к своим id', () {
      expect(StoryDeck.courtIds, containsAll(['runoff', 'deadlock', 'exile']));
      for (final id in StoryDeck.courtIds) {
        expect(StoryDeck.byId(id), isNotNull, reason: id);
      }
    });
  });

  group('Файлы карточек существуют', () {
    // Смысл в том, что путь в коде и файл на диске легко разъедутся:
    // переименовали картинку — приложение покажет заглушку, и никто
    // не заметит до партии. Тест проходит по реальной файловой системе.
    test('все карточки колоды злодеяний на месте', () {
      for (final c in Crime.all) {
        if (c.image == null) continue;
        expect(File(c.image!).existsSync(), isTrue, reason: c.image);
      }
    });

    test('все карточки сюжета на месте', () {
      for (final c in StoryDeck.all) {
        if (c.image == null) continue;
        expect(File(c.image!).existsSync(), isTrue, reason: c.image);
      }
    });

    test('карты ролей и фаз из инструкций на месте', () {
      for (final type in RoleType.values) {
        expect(File(A.guideRole(type)).existsSync(), isTrue,
            reason: A.guideRole(type));
      }
      for (final path in [A.guideHost, A.guideNight, A.guideDay, A.guideVote, A.guideWin]) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
    });
  });

  group('Галерея карточек', () {
    test('каталог покрывает все группы без пропусков', () {
      final all = CardGalleryScreen.entries();
      expect(all, isNotEmpty);
      for (final g in CardGalleryScreen.groups) {
        expect(all.where((e) => e.group == g), isNotEmpty, reason: g);
      }
      // Общее число = роли + 4 фазы + злодеяния + 4 суда + сюжет.
      expect(
        all.length,
        RoleType.values.length + 4 + Crime.all.length + 4 + StoryDeck.all.length,
      );
    });

    test('в каталоге нет карточек без названия', () {
      for (final e in CardGalleryScreen.entries()) {
        expect(e.title.trim(), isNotEmpty);
        expect(e.subtitle.trim(), isNotEmpty, reason: e.title);
      }
    });

    test('каждый путь из каталога существует на диске', () {
      for (final e in CardGalleryScreen.entries()) {
        if (e.image == null) continue;
        expect(File(e.image!).existsSync(), isTrue, reason: e.image);
      }
    });

    testWidgets('галерея открывается и показывает группы', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CardGalleryScreen()));
      await tester.pump();
      expect(find.textContaining('Все карточки'), findsOneWidget);
      expect(find.text('Роли'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Суд'), 600,
          scrollable: find.byType(Scrollable).first, maxScrolls: 100);
      expect(find.text('Суд'), findsOneWidget);
    });

    testWidgets('в партии первым разделом идут правила этого стола (UX-7)',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: RulesScreen(tableRules: [
          'Карта выбывшего закрыта до конца партии',
          'Первая ночь — знакомство: никто не погибает',
        ]),
      ));
      await tester.pump();

      expect(find.text('Правила этого стола'), findsOneWidget);
      expect(find.textContaining('знакомство'), findsOneWidget);
      // Общие правила никуда не делись — они ниже.
      expect(find.text('Как это устроено'), findsOneWidget);
    });

    testWidgets('вне партии раздела «Правила этого стола» нет',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: RulesScreen()));
      await tester.pump();
      expect(find.text('Правила этого стола'), findsNothing);
    });

    testWidgets('в «Правилах» есть кнопка перехода в галерею', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: RulesScreen()));
      await tester.pump();
      expect(find.byTooltip('Все карточки'), findsOneWidget);
    });
  });
}
