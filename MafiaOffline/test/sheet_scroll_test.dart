import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/main.dart';
import 'package:mafia_offline/storage/app_prefs.dart';
import 'package:mafia_offline/ui/app_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Вёрстка на телефоне: всё, что не помещается, обязано прокручиваться.
//
// Поводом послужил скриншот с телефона: в шторке «Настройки» последний пункт
// («Режим игрока в приложении») обрезался краем экрана, и доскроллить до него
// было нельзя — шторка лежала в Column без прокрутки, а showModalBottomSheet
// по умолчанию ограничивает её 9/16 высоты экрана.
//
// Тест маленького экрана (320×480) ловит три класса ошибок:
//   * overflow («жёлто-чёрные полосы») — takeException();
//   * обрезанное содержимое — до последнего элемента нужно ДОСКРОЛЛИТЬ,
//     а не просто найти его в дереве виджетов (невидимые виджеты в дереве
//     тоже есть, поэтому find.text сам по себе ничего не доказывает);
//   * недоступную кнопку — «Закрыть» должна быть на экране сразу.
//
// Почему 320×480 — это не «страшный» случай: так выглядит экран старого
// телефона с учётом системных панелей. Современный телефон в портрете даёт
// ~360×640 логических пикселей, то есть тест строже реальности.
// ---------------------------------------------------------------------------

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Экран как у старого телефона. Всё, что не влезает, должно ехать.
  void useSmallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// Прокрутить до элемента, который обязан быть достижим.
  ///
  /// `within` — область прокрутки. Без него берётся первая на экране, а это
  /// ошибка: под открытой шторкой остаётся прокрутка меню, и листать надо
  /// именно шторку, а не фон.
  Future<void> expectReachable(
    WidgetTester tester,
    Finder target, {
    required String what,
    Finder? within,
  }) async {
    final scrollables = within == null
        ? find.byType(Scrollable)
        : find.descendant(of: within, matching: find.byType(Scrollable));
    expect(scrollables, findsWidgets,
        reason: '$what: на экране нет прокрутки — содержимое обрежется');
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: scrollables.first,
      maxScrolls: 80,
    );
    expect(target, findsWidgets, reason: '$what: не доскроллить');
  }

  /// Шторка — единственное, что сейчас листается.
  final sheetScroll = find.byType(SheetBody);

  group('Шторка настроек', () {
    testWidgets('на маленьком экране прокручивается до последней настройки',
        (tester) async {
      useSmallPhone(tester);
      await tester.pumpWidget(const MafiaApp(offerAccepted: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Меню само прокручивается: кнопка «Звук» ниже границы экрана.
      await expectReachable(tester, find.text('Звук'), what: 'кнопка «Звук»');
      await tester.tap(find.text('Звук'));
      await tester.pumpAndSettle();

      expect(find.text('Настройки'), findsOneWidget);

      // Ни переполнения, ни обрезки без прокрутки.
      expect(tester.takeException(), isNull,
          reason: 'шторка настроек не помещается на экран');

      // Все четыре переключателя достижимы прокруткой, включая последний —
      // тот самый, что пропадал на скриншоте.
      for (final title in [
        'Звуки событий',
        'Атмосферный фон',
        'Начинать первую ночь автоматически',
        'Режим игрока в приложении',
      ]) {
        await expectReachable(tester, find.text(title),
            what: 'пункт «$title»', within: sheetScroll);
      }

      // «Закрыть» — вне прокрутки: доступна сразу, не после листания.
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.text('Настройки'), findsNothing);
    });

    testWidgets('на типичном телефоне 360×640 шторка выше прежнего потолка',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MafiaApp(offerAccepted: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await expectReachable(tester, find.text('Звук'), what: 'кнопка «Звук»');
      await tester.tap(find.text('Звук'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      // Содержимое настроек — ~760 px, оно выше любого телефона; прокрутка
      // для этого и нужна. Проверяем не «всё видно сразу», а то, что шторке
      // разрешено занять больше прежнего потолка 9/16 экрана (360 px из 640).
      final sheetHeight = tester.getSize(find.byType(SheetBody)).height;
      expect(sheetHeight, greaterThan(640 * 9 / 16),
          reason: 'шторка обрезана до 9/16 экрана — потолок вернулся');

      // И до последнего пункта реально можно доскроллить.
      await expectReachable(tester, find.text('Режим игрока в приложении'),
          what: 'последний пункт настроек', within: sheetScroll);
    });

    testWidgets('переключатель сохраняет настройку и не закрывает шторку',
        (tester) async {
      useSmallPhone(tester);
      await tester.pumpWidget(const MafiaApp(offerAccepted: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await expectReachable(tester, find.text('Звук'), what: 'кнопка «Звук»');
      await tester.tap(find.text('Звук'));
      await tester.pumpAndSettle();

      // По умолчанию «Режим игрока» выключен — включаем и проверяем,
      // что значение сохранилось.
      final before = await AppPrefs.playerModeVisible();
      await expectReachable(tester, find.text('Режим игрока в приложении'),
          what: 'переключатель режима игрока', within: sheetScroll);
      await tester.tap(find.widgetWithText(SwitchListTile,
          'Режим игрока в приложении'));
      await tester.pumpAndSettle();

      expect(await AppPrefs.playerModeVisible(), !before,
          reason: 'переключатель не сохранил значение');
      // Шторка осталась открытой: настройки меняются пачкой.
      expect(find.text('Настройки'), findsOneWidget);
    });
  });

  group('showAppSheet — общий каркас шторок', () {
    testWidgets('высокое содержимое прокручивается, а не обрезается',
        (tester) async {
      useSmallPhone(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => showAppSheet<void>(
                  ctx,
                  builder: (_) => SheetBody(
                    title: 'Тест',
                    children: [
                      for (var i = 0; i < 40; i++)
                        ListTile(title: Text('Строка $i')),
                    ],
                  ),
                ),
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await expectReachable(tester, find.text('Строка 39'),
          what: 'последняя строка', within: sheetScroll);
    });

    testWidgets('шторка не прячется под системной навигацией', (tester) async {
      useSmallPhone(tester);
      // Нижняя вставка — как у жестовой навигации Android.
      tester.view.padding = const FakeViewPadding(bottom: 48);
      addTearDown(tester.view.resetPadding);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => showAppSheet<void>(
                  ctx,
                  builder: (_) => SheetBody(
                    title: 'Тест',
                    bottom: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Готово'),
                    ),
                    children: const [Text('Содержимое')],
                  ),
                ),
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();

      // Кнопка обязана быть выше вставки снизу: 480 - 48 = 432.
      final button =
          tester.getRect(find.widgetWithText(ElevatedButton, 'Готово'));
      expect(button.bottom, lessThanOrEqualTo(480 - 48),
          reason: 'кнопка ушла под системную навигацию');
    });
  });
}
