import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/main.dart';

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
}
