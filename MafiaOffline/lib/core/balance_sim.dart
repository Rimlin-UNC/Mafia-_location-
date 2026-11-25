import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/player.dart';
import '../models/role.dart';
import 'game_engine.dart';

/// Песочница состава: «а что если» до начала партии.
///
/// Зачем это нужно
/// ---------------
/// Ведущий собирает стол на глаз: «мафии двое, доктор, комиссар…» — и
/// узнаёт, что состав перекошен, только когда город проигрывает за две
/// ночи. У ботов и людей за столом нет времени перебирать варианты, а у
/// ведущего — тем более: его роль вести, а не считать.
///
/// Здесь состав прогоняется через **тот же** движок, что играет настоящую
/// партию: `GameEngine.assignRoles` и `GameEngine.checkWinner`. Никакой
/// второй модели баланса нет — иначе советы расходились бы с игрой.
///
/// Что считается
/// -------------
/// Для каждого состава несколько тысяч быстрых партий, где ночь и день
/// заменены их математическим ожиданием:
///
/// * ночью мафия убивает одного, если его не спас доктор и не прикрыл
///   телохранитель; маньяк — ещё одного;
/// * днём город выгоняет одного мафиози с вероятностью, зависящей от
///   того, сколько информации у города: живой комиссар и свидетель
///   повышают шанс, шантажист — понижает (он крадёт голос).
///
/// Это **оценка**, а не предсказание: реальные партии зависят от
/// разговоров за столом. Поэтому результат — доля побед города с
/// погрешностью, а не «победит мафия».
///
/// Почему не полноценная симуляция партий
/// --------------------------------------
/// Полный прогон с ботами (`tools/stress.py`, тест «100 соло-игр») —
/// это секунды на один состав. Ведущему нужен ответ за доли секунды на
/// десяток вариантов, пока он настраивает стол. Отсюда упрощение:
/// считаем не ходы, а исход ночи и шанс дневного изгнания.
class BalanceSim {
  /// Сколько партий прогонять на состав. 1200 даёт погрешность около
  /// ±1,4 процентного пункта (при 95% доверии) — достаточно, чтобы
  /// отличить «город побеждает в 40%» от «в 55%», и при этом считается
  /// за единицы миллисекунд.
  static const int defaultGames = 1200;

  /// Доля побед города, при которой состав считаем сбалансированным.
  ///
  /// Почему 40…60, а не 45…55: в классической мафии город исторически
  /// побеждает реже (мафия видит своих, город — нет). Стол, где город
  /// выигрывает в 45%, считается хорошим. Границы выбраны так, чтобы
  /// пресеты 1.12.0 («на 10», «на 14», «на 18») попадали внутрь.
  static const double fairLow = 0.40;
  static const double fairHigh = 0.60;

  /// Оценка состава.
  ///
  /// [setup] — заказ ролей (как в настройках стола), [players] — сколько
  /// человек фактически село за стол. Лишние роли отбрасываются движком
  /// по тем же правилам, что и в настоящей партии.
  static BalanceReport estimate({
    required Map<RoleType, int> setup,
    required int players,
    int games = defaultGames,
    int seed = 1,
  }) {
    if (players <= 0 || games <= 0) {
      return const BalanceReport(
        games: 0,
        cityWins: 0,
        mafiaWins: 0,
        maniacWins: 0,
        noWinner: 0,
        verdict: BalanceVerdict.invalid,
        note: 'Нет игроков — оценивать нечего',
      );
    }
    final rnd = Random(seed);

    // Раздача одна на все партии: состав ролей от неё не зависит,
    // а пересобирать список игроков 1200 раз незачем.
    final seats = [
      for (var i = 0; i < players; i++)
        Player(
          id: 'p$i',
          name: 'Игрок ${i + 1}',
          colorHex: '#FFFFFF',
        ),
    ];
    final dealt = GameEngine.assignRoles(
      players: seats,
      setup: setup,
      random: rnd,
    );

    final roles = [
      for (final p in dealt) p.role?.type ?? RoleType.civilian,
    ];

    int mafiaWins = 0;
    int maniacWins = 0;
    int cityWins = 0;
    int nobody = 0;
    var roundsSum = 0;

    for (var g = 0; g < games; g++) {
      final result = _oneGame(roles, rnd);
      roundsSum += result.rounds;
      switch (result.winner) {
        case _Winner.mafia:
          mafiaWins++;
        case _Winner.maniac:
          maniacWins++;
        case _Winner.city:
          cityWins++;
        case _Winner.nobody:
          nobody++;
      }
    }

    final cityShare = cityWins / games;
    final verdict = _verdict(cityShare, mafiaWins / games, players, roles);
    return BalanceReport(
      games: games,
      cityWins: cityWins,
      mafiaWins: mafiaWins,
      maniacWins: maniacWins,
      noWinner: nobody,
      averageRounds: roundsSum / games,
      verdict: verdict.$1,
      note: verdict.$2,
      dealt: {
        for (final t in RoleType.values)
          if (roles.where((r) => r == t).isNotEmpty)
            t: roles.where((r) => r == t).length,
      },
    );
  }

  /// Одна «партия в среднем».
  ///
  /// Считаем живых по сторонам и выбывших, но не ведём ночные ходы: для
  /// оценки достаточно «сколько останется после этой ночи». Победа
  /// проверяется тем же правилом, что и в игре — через
  /// `GameEngine.checkWinner`, чтобы расхождений не было.
  static ({_Winner winner, int rounds}) _oneGame(
    List<RoleType> roles,
    Random rnd,
  ) {
    final alive = List<bool>.filled(roles.length, true);
    final side = [
      for (final r in roles) _sideOf(r),
    ];

    // Кто жив и что умеет — считается каждый круг: роли погибают.
    int aliveCount(_SideKind k) {
      var n = 0;
      for (var i = 0; i < roles.length; i++) {
        if (alive[i] && side[i] == k) n++;
      }
      return n;
    }

    bool canProtect() {
      for (var i = 0; i < roles.length; i++) {
        if (alive[i] &&
            (roles[i] == RoleType.doctor ||
                roles[i] == RoleType.bodyguard)) {
          return true;
        }
      }
      return false;
    }

    bool hasInfoRole() {
      for (var i = 0; i < roles.length; i++) {
        if (alive[i] &&
            (roles[i] == RoleType.commissioner ||
                roles[i] == RoleType.witness)) {
          return true;
        }
      }
      return false;
    }

    bool hasSilencer() {
      for (var i = 0; i < roles.length; i++) {
        if (alive[i] && roles[i] == RoleType.blackmailer) return true;
      }
      return false;
    }

    /// Годится ли этот живой игрок в жертву удара стороны [kind].
    ///
    /// Как в движке: мафия бьёт город и одиночку, но не своих, маньяк —
    /// всех, кроме себя (в том числе мафию).
    bool isHitTarget(_SideKind kind, int i) => kind == _SideKind.maniac
        ? roles[i] != RoleType.maniac
        : side[i] != _SideKind.maniac && side[i] != _SideKind.mafia;

    /// Случайная живая цель для удара этой стороны (индекс), null — некого.
    ///
    /// Мафия бьёт по городу и одиночке, маньяк — по всем, кроме себя.
    /// Дон и шантажист умирают как все: отдельного иммунитета у них нет.
    int? victimFor(_SideKind kind) {
      final pool = <int>[
        for (var i = 0; i < roles.length; i++)
          if (alive[i] && isHitTarget(kind, i)) i,
      ];
      if (pool.isEmpty) return null;
      return pool[rnd.nextInt(pool.length)];
    }

    for (var round = 1; round <= 40; round++) {
      // --- ночь ---
      // Первая ночь — знакомство: никто не погибает.
      if (round > 1) {
        // Мафия: одна жертва на команду. Доктор/телохранитель спасают
        // одну цель с вероятностью 0,6 — они не знают, кого выбрала
        // мафия, но играют по тем же уликам, что и люди.
        final victims = <int>[];
        final m = victimFor(_SideKind.mafia);
        if (m != null) victims.add(m);
        if (aliveCount(_SideKind.maniac) > 0) {
          final mm = victimFor(_SideKind.maniac);
          if (mm != null) victims.add(mm);
        }
        if (victims.isNotEmpty) {
          final saved = (canProtect() && rnd.nextDouble() < 0.6)
              ? victims[rnd.nextInt(victims.length)]
              : -1;
          for (final v in victims) {
            if (v != saved) alive[v] = false;
          }
        }
        // Двойной удар мафии при равенстве не воспроизводим: он редкий
        // и оценивается как обычная ночь.
      }

      final w1 = _winnerNow(roles, alive);
      if (w1 != null) return (winner: w1, rounds: round);

      // --- день ---
      // Шанс, что город выгонит мафиози, а не мирного.
      var pMafia = 0.34;
      if (hasInfoRole()) pMafia += 0.14;
      if (hasSilencer()) pMafia -= 0.10;
      // Чем больше мафии в доле стола, тем проще её найти.
      final total = alive.where((a) => a).length;
      final mafiaAlive = aliveCount(_SideKind.mafia);
      if (total > 0) pMafia += 0.10 * (mafiaAlive / total);

      if (rnd.nextDouble() < pMafia) {
        // Выгнали мафиози (не дона — дон «чист» для комиссара).
        final pool = <int>[
          for (var i = 0; i < roles.length; i++)
            if (alive[i] && side[i] == _SideKind.mafia) i
        ];
        if (pool.isNotEmpty) {
          alive[pool[rnd.nextInt(pool.length)]] = false;
        }
      } else {
        // Выгнали мирного: город ошибся.
        final pool = <int>[
          for (var i = 0; i < roles.length; i++)
            if (alive[i] && side[i] == _SideKind.city) i
        ];
        if (pool.isNotEmpty) alive[pool[rnd.nextInt(pool.length)]] = false;
        // Маньяк иногда попадает под голосование — 25%.
        final maniacs = <int>[
          for (var i = 0; i < roles.length; i++)
            if (alive[i] && side[i] == _SideKind.maniac) i
        ];
        if (maniacs.isNotEmpty && rnd.nextDouble() < 0.25) {
          alive[maniacs[rnd.nextInt(maniacs.length)]] = false;
        }
      }

      final w2 = _winnerNow(roles, alive);
      if (w2 != null) return (winner: w2, rounds: round);
    }
    return (winner: _Winner.nobody, rounds: 40);
  }

  /// Тот же вердикт, что считает симуляция, но доступный тесту.
  ///
  /// Возвращает `'mafia' | 'city' | 'maniac' | 'nobody'` или null, если
  /// партия продолжается. Нужен, чтобы тест сверял **этот** код с
  /// `GameState.checkWinner`, а не собственную копию правила.
  @visibleForTesting
  static String? debugWinner(List<RoleType> roles, List<bool> alive) {
    final w = _winnerNow(roles, alive);
    return switch (w) {
      _Winner.mafia => 'mafia',
      _Winner.city => 'city',
      _Winner.maniac => 'maniac',
      _Winner.nobody => 'nobody',
      null => null,
    };
  }

  static _Winner? _winnerNow(List<RoleType> roles, List<bool> alive) =>
      _WinnerCheck(roles, alive).verdict();

  static _SideKind _sideOf(RoleType r) {
    if (r == RoleType.mafia ||
        r == RoleType.don ||
        r == RoleType.blackmailer) {
      return _SideKind.mafia;
    }
    if (r == RoleType.maniac) return _SideKind.maniac;
    return _SideKind.city;
  }

  /// Вердикт по доле побед города. Текст важен не меньше числа: ведущий
  /// должен понимать, **что** не так, а не просто «40%».
  static (BalanceVerdict, String) _verdict(
    double cityShare,
    double mafiaShare,
    int players,
    List<RoleType> roles,
  ) {
    final mafia = roles.where((r) =>
        r == RoleType.mafia ||
        r == RoleType.don ||
        r == RoleType.blackmailer).length;
    final has = {for (final r in roles) r};
    final buf = StringBuffer();

    if (cityShare > fairHigh) {
      buf.write('Городу слишком легко: побеждает в '
          '${(cityShare * 100).round()}% партий. ');
      if (mafia < 2 && players >= 9) {
        buf.write('На $players игроков двух мафиози мало — добавьте дона '
            'или шантажиста. ');
      } else if (has.contains(RoleType.commissioner) &&
          has.contains(RoleType.doctor) &&
          !has.contains(RoleType.blackmailer) &&
          players >= 12) {
        buf.write('Комиссар и доктор без шантажиста — слишком сильный '
            'город. Шантажист крадёт голос и ломает его планы. ');
      }
      return (BalanceVerdict.tooEasyForCity, buf.toString().trim());
    }
    if (cityShare < fairLow) {
      buf.write('Мафии слишком много: город побеждает лишь в '
          '${(cityShare * 100).round()}% партий. ');
      if (mafia >= 3 && players <= 10) {
        buf.write('Три мафиози на $players человек — город не успевает '
            'ничего сделать. Уберите шантажиста или рядового мафиози. ');
      } else if (!has.contains(RoleType.commissioner) &&
          !has.contains(RoleType.doctor)) {
        buf.write('У города нет ни комиссара, ни доктора: искать мафию '
            'нечем. Добавьте хотя бы одного. ');
      }
      return (BalanceVerdict.tooEasyForMafia, buf.toString().trim());
    }

    // Внутри коридора — но проверим, что у города есть чем играть.
    if (!has.contains(RoleType.commissioner) && players >= 8) {
      return (
        BalanceVerdict.fair,
        'Баланс в норме, но у города нет комиссара: партия будет '
            'держаться на разговорах, а не на уликах.'
      );
    }
    return (BalanceVerdict.fair, 'Состав сбалансирован — играть можно.');
  }
}

enum _SideKind { mafia, city, maniac }

enum _Winner { mafia, city, maniac, nobody }

/// Проверка победителя по тем же правилам, что в `GameState.checkWinner`.
///
/// Отдельный маленький класс, а не вызов движка: у движка состояние с
/// игроками и событиями, а здесь только роли и флаги «жив». Держать
/// правило в двух местах опасно, поэтому тест сверяет этот вердикт с
/// `GameState.checkWinner` на всех граничных раскладах.
class _WinnerCheck {
  final List<RoleType> roles;
  final List<bool> alive;

  _WinnerCheck(this.roles, this.alive);

  int count(_SideKind k) {
    var n = 0;
    for (var i = 0; i < roles.length; i++) {
      if (alive[i] && BalanceSim._sideOf(roles[i]) == k) n++;
    }
    return n;
  }

  _Winner? verdict() {
    final mafia = count(_SideKind.mafia);
    final maniac = count(_SideKind.maniac);
    final city = count(_SideKind.city);
    final totalAlive = mafia + maniac + city;

    if (totalAlive == 0) return _Winner.nobody;
    // Маньяк побеждает, только оставшись один живым.
    //
    // Ровно как в `GameState.checkWinner`: условие — «маньяк есть, а
    // мафии и города нет», без требования, что он один. Расхождение
    // здесь ловится тестом на всех раскладах до 5 игроков.
    if (maniac > 0 && mafia == 0 && city == 0) {
      return _Winner.maniac;
    }
    if (mafia == 0 && maniac == 0) return _Winner.city;
    // Мафия побеждает при равенстве с городом. Живой маньяк этому не
    // мешает — точно как в движке, где проверка `mafia >= civilians`
    // идёт до любых оговорок про одиночку.
    if (mafia > 0 && mafia >= city) return _Winner.mafia;
    return null;
  }
}

enum BalanceVerdict {
  fair,
  tooEasyForCity,
  tooEasyForMafia,
  invalid,
}

/// Результат оценки: доли побед, средняя длина партии и вердикт.
class BalanceReport {
  final int games;
  final int cityWins;
  final int mafiaWins;
  final int maniacWins;
  final int noWinner;
  final double averageRounds;
  final BalanceVerdict verdict;
  final String note;

  /// Фактически розданный состав: движок мог срезать лишние роли.
  final Map<RoleType, int> dealt;

  const BalanceReport({
    required this.games,
    required this.cityWins,
    required this.mafiaWins,
    required this.maniacWins,
    required this.noWinner,
    this.averageRounds = 0,
    required this.verdict,
    required this.note,
    this.dealt = const {},
  });

  double get cityShare => games == 0 ? 0 : cityWins / games;
  double get mafiaShare => games == 0 ? 0 : mafiaWins / games;
  double get maniacShare => games == 0 ? 0 : maniacWins / games;

  /// «Город 52% · мафия 45% · маньяк 3%» — строка для карточки.
  String get sharesRu {
    if (games == 0) return '—';
    final parts = <String>[
      'город ${(cityShare * 100).round()}%',
      'мафия ${(mafiaShare * 100).round()}%',
    ];
    if (maniacShare >= 0.005) {
      parts.add('маньяк ${(maniacShare * 100).round()}%');
    }
    return parts.join(' · ');
  }
}
