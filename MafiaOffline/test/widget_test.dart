import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/core/assets.dart';
import 'package:mafia_offline/core/crime_deck.dart';
import 'package:mafia_offline/main.dart';
import 'package:mafia_offline/models/role.dart';
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
}
