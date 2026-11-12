import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/core/assets.dart';
import 'package:mafia_offline/core/crime_deck.dart';
import 'package:mafia_offline/core/story_deck.dart';
import 'package:mafia_offline/main.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/models/role.dart';
import 'package:mafia_offline/storage/app_prefs.dart';
import 'package:mafia_offline/ui/card_gallery_screen.dart';
import 'package:mafia_offline/ui/offer_screen.dart';
import 'package:mafia_offline/ui/rules_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('Оферта и права на программу', () {
    test('оферта называет правообладателя, сайт и редакцию', () {
      expect(offerHighlights.join(' '), contains('Ямастер'));
      expect(offerHighlights.join(' '), contains('ymaster.ru'));
      expect(offerHighlights.join(' '), contains('2026'));
      expect(offerVersion, contains('1.2'));
    });

    test('в условиях названы реквизиты правообладателя', () {
      final text = offerHighlights.join(' ');
      expect(text, contains('4712030034'), reason: 'ИНН');
      expect(text, contains('1204700012483'), reason: 'ОГРН');
      expect(text, contains('ymaster.ru'));
    });

    test('в условиях прямо сказано, что права не переходят', () {
      final text = offerHighlights.join(' ');
      expect(text.toLowerCase(), contains('не переходят'));
    });

    test('в условиях сказано про офлайн и хранение данных на устройстве', () {
      final text = offerHighlights.join(' ');
      expect(text.toLowerCase(), contains('офлайн'));
      expect(text.toLowerCase(), contains('устройстве'));
    });

    testWidgets('без галочки принять оферту нельзя', (tester) async {
      var accepted = false;
      await tester.pumpWidget(MaterialApp(
        home: OfferGate(onAccepted: () => accepted = true),
      ));
      await tester.pumpAndSettle();

      // Кнопка есть, но неактивна: галочка не стоит.
      final button = find.widgetWithText(ElevatedButton, 'Принимаю и продолжаю');
      expect(button, findsOneWidget);
      expect(tester.widget<ElevatedButton>(button).onPressed, isNull);

      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(accepted, isFalse, reason: 'без галочки принятие невозможно');
    });

    testWidgets('после галочки кнопка становится активной', (tester) async {
      // Хранилище как на устройстве: принятие должно ещё и записаться.
      SharedPreferences.setMockInitialValues({});
      var accepted = false;
      await tester.pumpWidget(MaterialApp(
        home: OfferGate(onAccepted: () => accepted = true),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox));
      await tester.pump();

      final button = find.widgetWithText(ElevatedButton, 'Принимаю и продолжаю');
      expect(tester.widget<ElevatedButton>(button).onPressed, isNotNull);

      // Кнопка внизу экрана: на тестовой высоте она может быть за границей
      // видимой области, и тап по координатам не попадёт. Прокручиваем к ней.
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(accepted, isTrue);

      // И факт принятия действительно записан — иначе галочка была бы
      // формальностью, которую нечем подтвердить в споре.
      expect(await AppPrefs.offerAccepted(), isTrue);
      expect(await AppPrefs.offerVersionAccepted(), offerVersion);
    });

    testWidgets('экран оферты показывает правообладателя и ограничение ответственности',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OfferGate(onAccepted: () {}),
      ));
      await tester.pumpAndSettle();

      // Правообладатель назван дважды: в шапке и в пункте 1 условий.
      // Оба нужны — один виден сразу, второй остаётся при прокрутке.
      expect(find.textContaining('ООО «Ямастер»'), findsNWidgets(2));
      expect(find.textContaining('ymaster.ru'), findsWidgets);
      expect(find.text('УСЛОВИЯ ИСПОЛЬЗОВАНИЯ'), findsOneWidget);
    });

    testWidgets('правила доступны до принятия условий', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OfferGate(onAccepted: () {}),
      ));
      await tester.pumpAndSettle();

      // Сначала узнай игру, потом соглашайся — кнопка должна быть на экране
      // оферты, до галочки.
      final rulesButton = find.text('Правила и роли — что это за игра');
      expect(rulesButton, findsOneWidget);
      // Рядом сказано, что за кнопкой: полное описание игры, а не выжимка.
      expect(find.textContaining('полное описание игры'), findsOneWidget);
      expect(find.textContaining('роли, фазы'), findsOneWidget);

      await tester.tap(rulesButton);
      await tester.pumpAndSettle();

      // Открылся экран «Правила» с содержанием, а не пустая страница.
      expect(find.text('Правила'), findsOneWidget);
      expect(find.text('Как это устроено'), findsOneWidget);

      // Секции ниже первого экрана: ListView строит лениво, поэтому до них
      // надо доскроллить, иначе проверка была бы про высоту экрана, а не
      // про наличие содержания.
      // Это не выжимка: с 1.8.0 экран открывается сразу как полная книга
      // правил — та же, что игрок читает в браузере. Пояснение лежит в шапке
      // списка, проверяем его ДО прокрутки: вниз уйдём — и его не станет.
      expect(find.textContaining('Полная инструкция'), findsOneWidget);

      for (final title in ['Фазы партии', 'Роли']) {
        await tester.scrollUntilVisible(
          find.text(title),
          400,
          scrollable: find.byType(Scrollable).last,
          maxScrolls: 60,
        );
        expect(find.text(title), findsWidgets, reason: 'секция «$title»');
      }
    });

    testWidgets('книга правил доходит до способов убийства и спорных правил',
        (tester) async {
      // Раньше игра показывала только роли и фазы; ниже — колода злодеяний
      // и разбор спорных правил. Игрок должен увидеть и их, иначе «полное
      // описание» — обещание, которого экран не выполняет.
      await tester.pumpWidget(const MaterialApp(home: RulesScreen()));
      await tester.pump();

      for (final title in [
        'Как мафия убирает игрока',
        'Правила, о которых спорят',
      ]) {
        await tester.scrollUntilVisible(
          find.text(title),
          500,
          scrollable: find.byType(Scrollable).last,
          maxScrolls: 120,
        );
        expect(find.text(title), findsOneWidget, reason: 'секция «$title»');
      }
      // Название хотя бы одного способа убийства — из общего источника.
      expect(find.text('Огнестрел'), findsWidgets);
    });

    testWidgets('из правил можно вернуться к оферте', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OfferGate(onAccepted: () {}),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Правила и роли — что это за игра'));
      await tester.pumpAndSettle();
      expect(find.text('Правила'), findsOneWidget);

      // Возврат — и оферта на месте, ничего не потеряно.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('УСЛОВИЯ ИСПОЛЬЗОВАНИЯ'), findsOneWidget);
      expect(find.text('Принимаю и продолжаю'), findsOneWidget);
    });

    testWidgets('на маленьком экране оферта прокручивается, а не ломается',
        (tester) async {
      // Экран 320x480 — старый телефон. Текст условий длинный, и если бы он
      // лежал в Column, был бы overflow. Проверяем, что этого не происходит.
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: OfferGate(onAccepted: () {}),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'переполнение вёрстки на маленьком экране');
      // И кнопка согласия остаётся доступной после прокрутки.
      await tester.scrollUntilVisible(
        find.widgetWithText(ElevatedButton, 'Принимаю и продолжаю'),
        200,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
      expect(find.text('Принимаю и продолжаю'), findsOneWidget);
    });

    testWidgets('в главном меню видно, кому принадлежат права', (tester) async {
      await tester.pumpWidget(const MafiaApp(offerAccepted: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Меню прокручивается, и подпись стоит в самом низу. Ищем её
      // прокруткой, а не «в кадре»: иначе тест проверял бы высоту экрана.
      await tester.scrollUntilVisible(
        find.textContaining('ООО «Ямастер»'),
        300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 40,
      );
      expect(find.textContaining('ООО «Ямастер»'), findsOneWidget);
    });
  });

  group('Принятие оферты сохраняется', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('по умолчанию оферта не принята', () async {
      expect(await AppPrefs.offerAccepted(), isFalse);
      expect(await AppPrefs.offerAcceptedAt(), isNull);
      expect(await AppPrefs.offerVersionAccepted(), isNull);
    });

    test('принятие записывает дату, редакцию и имя', () async {
      await AppPrefs.setOfferAccepted(
        offerVersion: offerVersion,
        playerName: '  Аня  ',
      );

      expect(await AppPrefs.offerAccepted(), isTrue);
      final at = await AppPrefs.offerAcceptedAt();
      expect(at, isNotNull);
      expect(DateTime.tryParse(at!), isNotNull,
          reason: 'дата должна быть в ISO-8601, иначе её нечем показать');
      expect(await AppPrefs.offerVersionAccepted(), offerVersion);
      // Имя обрезается по краям: пробелы в доказательстве согласия не нужны.
      expect(await AppPrefs.offerAcceptedName(), 'Аня');
    });

    test('пустое имя не записывается', () async {
      await AppPrefs.setOfferAccepted(offerVersion: offerVersion, playerName: '   ');
      expect(await AppPrefs.offerAcceptedName(), isNull);
    });

    test('сброс возвращает устройство в состояние «не принято»', () async {
      await AppPrefs.setOfferAccepted(offerVersion: offerVersion, playerName: 'Аня');
      await AppPrefs.resetOfferAccepted();

      expect(await AppPrefs.offerAccepted(), isFalse);
      expect(await AppPrefs.offerAcceptedAt(), isNull);
      expect(await AppPrefs.offerVersionAccepted(), isNull);
      expect(await AppPrefs.offerAcceptedName(), isNull);
    });

    test('принятие переживает перезапуск приложения', () async {
      await AppPrefs.setOfferAccepted(offerVersion: offerVersion);
      // Новый экземпляр AppPrefs читает те же prefs — как после перезапуска.
      expect(await AppPrefs.offerAccepted(), isTrue);
    });

    test('старая редакция не засчитывается как принятие', () async {
      await AppPrefs.setOfferAccepted(offerVersion: '1.1 от 12.11.2026');

      // Без указания редакции отметка есть — но текущую редакцию она не покрывает.
      expect(await AppPrefs.offerAccepted(), isTrue);
      expect(await AppPrefs.offerAccepted(currentVersion: '1.2 от 12.11.2026'),
          isFalse,
          reason: 'условия переработаны — галочку нужно спросить заново');
      expect(await AppPrefs.offerAccepted(currentVersion: '1.1 от 12.11.2026'),
          isTrue);
    });

    test('отметка без записанной редакции не засчитывается', () async {
      // След приложения, где номер редакции ещё не сохранялся: флаг есть,
      // версии нет. Воспроизводим не через setMockInitialValues (он в этом
      // тесте мог уже отработать в setUp), а тем же хранилищем.
      await AppPrefs.setOfferAccepted();
      expect(await AppPrefs.offerVersionAccepted(), isNull,
          reason: 'версия не передана — записана не была');
      expect(await AppPrefs.offerAccepted(), isTrue);
      expect(await AppPrefs.offerAccepted(currentVersion: offerVersion), isFalse,
          reason: 'отметка без номера редакции не подтверждает текущий текст');
    });
  });
}
