import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/main.dart';
import 'package:mafia_offline/ui/card_gallery_screen.dart';
import 'package:mafia_offline/ui/history_screen.dart';
import 'package:mafia_offline/ui/host/setup_screen.dart';
import 'package:mafia_offline/ui/offer_screen.dart';
import 'package:mafia_offline/ui/rules_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Дизайн-аудит: экраны на телефоне, а не на макете.
//
// Тест задаёт вопросы, которые дизайнер задаёт макету, но которые никто
// не проверяет руками на каждом релизе:
//
//   1. Влезает ли экран в старый телефон (320×480, как у бюджетников)?
//   2. Не ломается ли вёрстка, если человек включил крупный шрифт
//      в настройках системы (у многих пожилых игроков он на максимуме)?
//   3. Не появляется ли «жёлто-чёрных полос переполнения» — в приложении
//      это не полоски, а обрезанный текст.
//
// Если содержимое не влезает — это нормально, пока оно прокручивается.
// Ненормально, когда `takeException()` не null: Flutter тогда рисует
// поверх интерфейса жёлто-чёрную ленту и часть интерфейса теряется.
// ---------------------------------------------------------------------------

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Старый телефон 320×480 и, по выбору, крупный системный шрифт.
  void phone(WidgetTester tester, {double textScale = 1.0}) {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  /// Открыть экран и убедиться, что вёрстка не сломалась.
  Future<void> open(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(MaterialApp(home: screen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  }

  group('Экраны на старом телефоне 320×480', () {
    testWidgets('главное меню', (tester) async {
      phone(tester);
      await tester.pumpWidget(const MafiaApp(offerAccepted: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      // Главное действие обязано быть достижимо.
      await tester.scrollUntilVisible(
        find.text('Я ведущий — создать игру'),
        120,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 40,
      );
    });

    testWidgets('правила и роли', (tester) async {
      phone(tester);
      await open(tester, const RulesScreen());
      expect(find.text('Правила'), findsOneWidget);
    });

    testWidgets('галерея карточек', (tester) async {
      phone(tester);
      await open(tester, const CardGalleryScreen());
    });

    testWidgets('история партий', (tester) async {
      phone(tester);
      await open(tester, const HistoryScreen());
    });

    testWidgets('новая игра (состав и правила)', (tester) async {
      phone(tester);
      await open(tester, const SetupScreen());
      // Кнопка создания — внизу экрана, до неё обязан быть ход.
      await tester.scrollUntilVisible(
        find.text('Создать игру и запустить сервер'),
        120,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
    });

    testWidgets('оферта', (tester) async {
      phone(tester);
      await open(tester, OfferGate(onAccepted: () {}));
      await tester.scrollUntilVisible(
        find.widgetWithText(ElevatedButton, 'Принимаю и продолжаю'),
        120,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
    });
  });

  group('Крупный системный шрифт (как у пожилых игроков)', () {
    // 1.3 — не крайность: в Android «Крупный» это 1.15, «Огромный» — 1.3.
    // 1.5 встречается на планшетах и в режиме доступности.
    for (final scale in [1.3, 1.5]) {
      testWidgets('меню, x$scale', (tester) async {
        phone(tester, textScale: scale);
        await tester.pumpWidget(const MafiaApp(offerAccepted: true));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(tester.takeException(), isNull,
            reason: 'меню ломается при шрифте x$scale');
        await tester.scrollUntilVisible(
          find.text('Я ведущий — создать игру'),
          120,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 60,
        );
      });

      testWidgets('новая игра, x$scale', (tester) async {
        phone(tester, textScale: scale);
        await open(tester, const SetupScreen());
        expect(tester.takeException(), isNull,
            reason: 'состав игры ломается при шрифте x$scale');
      });

      testWidgets('правила, x$scale', (tester) async {
        phone(tester, textScale: scale);
        await open(tester, const RulesScreen());
        expect(tester.takeException(), isNull,
            reason: 'правила ломаются при шрифте x$scale');
      });
    }
  });

  group('Шторка настроек при крупном шрифте', () {
    testWidgets('содержимое доскролливается, вёрстка не ломается',
        (tester) async {
      phone(tester, textScale: 1.3);
      await tester.pumpWidget(const MafiaApp(offerAccepted: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.scrollUntilVisible(
        find.text('Звук'),
        120,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
      await tester.tap(find.text('Звук'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'шторка настроек ломается при крупном шрифте');

      // Последний пункт обязан быть достижим даже на x1.3 и 320×480.
      await tester.scrollUntilVisible(
        find.text('Режим игрока в приложении'),
        120,
        // Прокрутка самой шторки: под ней осталась прокрутка меню,
        // и листать надо именно верхний слой.
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 60,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
