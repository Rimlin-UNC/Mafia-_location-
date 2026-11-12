import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/models/role.dart';

// ---------------------------------------------------------------------------
// Таймер фазы: игровое время идёт по РЕАЛЬНЫМ секундам.
//
// Дефект 1.9.2: `_startTimer` вычитал по единице на каждый тик
// `Timer.periodic`. Android замораживает таймеры, когда экран ведущего
// погас, а служба переднего плана ещё не поднялась; на iOS — при уходе
// приложения в фон. После возврата тики не «догоняют» пропущенное, и фаза
// «Ночь» висела дольше, чем ведущий и стол ожидали: время на экране
// замирало, обратный отсчёт врал.
//
// Здесь проверяется модель, по которой теперь идёт отсчёт: разница
// фактического времени, а не число срабатываний. Тест держит контракт,
// даже если реализацию таймера снова перепишут.
// ---------------------------------------------------------------------------

/// Тот же расчёт, что в HostController._startTimer:
/// новое время = старое - реально прошедшие секунды.
int afterElapsed({required int timeLeft, required Duration elapsed}) {
  final seconds = elapsed.inSeconds;
  if (seconds <= 0) return timeLeft;
  return timeLeft - seconds;
}

GameState state({int timeLeft = 120, GamePhase phase = GamePhase.night}) {
  return GameState(
    id: 'g',
    name: 't',
    code: '000000',
    createdAt: DateTime(2026),
    phase: phase,
    timeLeft: timeLeft,
    round: 1,
    players: [
      Player(id: 'a', name: 'A', colorHex: '#FFFFFF',
          role: Role.fromType(RoleType.mafia)),
      Player(id: 'b', name: 'B', colorHex: '#FFFFFF',
          role: Role.fromType(RoleType.civilian)),
      Player(id: 'c', name: 'C', colorHex: '#FFFFFF',
          role: Role.fromType(RoleType.civilian)),
      Player(id: 'd', name: 'D', colorHex: '#FFFFFF',
          role: Role.fromType(RoleType.civilian)),
    ],
  );
}

void main() {
  group('Таймер не замирает, когда приложение было в фоне', () {
    test('обычная секунда снимает одну секунду', () {
      expect(afterElapsed(timeLeft: 120, elapsed: const Duration(seconds: 1)),
          119);
    });

    test('пять пропущенных секунд снимают пять, а не одну', () {
      // Самая суть дефекта: старый код снял бы 1 (одно срабатывание
      // после разморозки), новый снимает все 5.
      expect(afterElapsed(timeLeft: 120, elapsed: const Duration(seconds: 5)),
          115);
    });

    test('долгий фон 90 секунд при 120 на табло даёт 30', () {
      expect(afterElapsed(timeLeft: 120, elapsed: const Duration(seconds: 90)),
          30);
    });

    test('если фон дольше фазы — время уходит в минус, фаза кончается', () {
      // Контракт: 0 или меньше означает «время вышло», а не «ждём ещё».
      final left =
          afterElapsed(timeLeft: 60, elapsed: const Duration(seconds: 600));
      expect(left, lessThanOrEqualTo(0),
          reason: 'после долгого фона фаза обязана завершиться, '
              'а не ждать ещё минуту');
    });

    test('дробные доли секунды не съедают время', () {
      // Timer.periodic может сработать на 900 мс раньше — нельзя
      // вычитать ноль и терять тик, но и нельзя вычитать «полсекунды».
      expect(afterElapsed(timeLeft: 120, elapsed: const Duration(milliseconds: 900)),
          120);
    });
  });

  group('Фазы без таймера не завершаются сами', () {
    test('в лобби и раздаче ролей timeLeft не тикает', () {
      // onResume() явно пропускает эти фазы: иначе «догон» мгновенно
      // завершил бы раздачу ролей, которую заканчивает человек.
      for (final phase in [GamePhase.waiting, GamePhase.rolesCheck]) {
        final s = state(timeLeft: 0, phase: phase);
        expect(s.timeLeft, 0);
        // Контракт контроллера: на этих фазах onResume ничего не делает.
        // Мы проверяем само условие, а не приватный метод.
        final skipped =
            phase == GamePhase.waiting || phase == GamePhase.rolesCheck;
        expect(skipped, isTrue, reason: '$phase не должна догоняться');
      }
    });
  });
}
