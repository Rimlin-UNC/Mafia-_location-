import 'dart:math';

import '../models/game_state.dart';
import '../models/player.dart';
import '../models/role.dart';

/// Чистая игровая логика без UI и сети. Легко покрывается тестами.
class GameEngine {
  /// Раздача ролей по заданному составу.
  /// Если игроков меньше, чем заявлено, лишние специальные роли
  /// отбрасываются по приоритету (маньяк → проститутка → комиссар → доктор).
  static List<Player> assignRoles({
    required List<Player> players,
    required Map<RoleType, int> setup,
    Random? random,
  }) {
    final rnd = random ?? Random.secure();

    // Порядок ВАЖНОСТИ: чем ниже в списке, тем раньше роль отбрасывается,
    // если игроков пришло меньше, чем заказано. Пул строим с конца,
    // поэтому первым «срезается» маньяк, последним — дон.
    const dropOrder = [
      RoleType.don,
      RoleType.mafia,
      RoleType.doctor,
      RoleType.commissioner,
      RoleType.prostitute,
      RoleType.maniac,
    ];

    final pool = <RoleType>[];
    for (final type in dropOrder) {
      final count = setup[type] ?? 0;
      for (var i = 0; i < count; i++) {
        pool.add(type);
      }
    }

    // Если специальных ролей больше, чем игроков — режем с КОНЦА
    // (маньяк, проститутка, комиссар, доктор, рядовая мафия…).
    while (pool.length > players.length) {
      pool.removeLast();
    }

    // Главное правило баланса: против мафии должно остаться минимум
    // два игрока, иначе город проигрывает, не начав. Равный состав
    // (3 на 3) допустим — у города есть дневное голосование.
    int mafiaCount() => pool
        .where((r) => r == RoleType.mafia || r == RoleType.don)
        .length;
    // Сравниваем с ИТОГОВЫМ числом игроков, а не с длиной ещё не добитого
    // мирными пула — иначе разжалуем мафию там, где баланс в порядке.
    while (pool.isNotEmpty && players.length - mafiaCount() <= 1) {
      // Разжалуем рядовую мафию, дона трогаем в последнюю очередь.
      final idx = pool.lastIndexOf(RoleType.mafia) != -1
          ? pool.lastIndexOf(RoleType.mafia)
          : pool.lastIndexOf(RoleType.don);
      if (idx == -1) break;
      pool[idx] = RoleType.civilian;
    }

    // Остаток добиваем мирными.
    while (pool.length < players.length) {
      pool.add(RoleType.civilian);
    }

    // Перемешивание Фишера — Йетса.
    for (var i = pool.length - 1; i > 0; i--) {
      final j = rnd.nextInt(i + 1);
      final tmp = pool[i];
      pool[i] = pool[j];
      pool[j] = tmp;
    }

    return [
      for (var i = 0; i < players.length; i++)
        players[i].copyWith(role: Role.fromType(pool[i])),
    ];
  }

  /// Согласование цели мафии: голос дона решающий, иначе — большинство,
  /// при равенстве — случайный выбор среди лидеров.
  static String? resolveMafiaTarget(GameState s, Random rnd) {
    final team = s.mafiaTeam;
    if (team.isEmpty) return null;

    final donPlayer = s.don;
    if (donPlayer != null && s.nightActions.containsKey(donPlayer.id)) {
      final donChoice = s.nightActions[donPlayer.id];
      if (donChoice != null) return donChoice;
    }

    final tally = <String, int>{};
    for (final m in team) {
      final target = s.nightActions[m.id];
      if (target != null) tally[target] = (tally[target] ?? 0) + 1;
    }
    if (tally.isEmpty) return null;

    final maxVotes = tally.values.reduce((a, b) => a > b ? a : b);
    final leaders =
        tally.entries.where((e) => e.value == maxVotes).map((e) => e.key).toList();
    return leaders[rnd.nextInt(leaders.length)];
  }

  /// Разрешение ночи в строгом порядке:
  /// проститутка → доктор → мафия → маньяк → комиссар.
  static NightOutcome resolveNight(GameState s, {Random? random}) {
    final rnd = random ?? Random.secure();

    // 1. Проститутка блокирует цель — её ход аннулируется.
    String? blockedId;
    final pros = s.prostitute;
    if (pros != null) {
      blockedId = s.nightActions[pros.id];
    }

    bool isBlocked(Player? p) => p != null && p.id == blockedId;

    // 2. Доктор лечит, если не заблокирован.
    String? healedId;
    final doc = s.doctor;
    if (doc != null && !isBlocked(doc)) {
      final target = s.nightActions[doc.id];
      // Нельзя лечить одну цель две ночи подряд.
      if (target != null && target != s.lastHealedId) {
        healedId = target;
      }
    }

    // 3. Мафия выбирает жертву, если вся команда не заблокирована.
    String? mafiaTarget;
    final team = s.mafiaTeam;
    final teamBlocked = team.isNotEmpty && team.every((m) => m.id == blockedId);
    if (team.isNotEmpty && !teamBlocked) {
      mafiaTarget = resolveMafiaTarget(s, rnd);
    }

    // 4. Маньяк убивает независимо от мафии.
    String? maniacTarget;
    final man = s.maniac;
    if (man != null && !isBlocked(man)) {
      maniacTarget = s.nightActions[man.id];
    }

    // 5. Комиссар проверяет. Дон выглядит мирным.
    String? checkedId;
    bool? checkIsMafia;
    final com = s.commissioner;
    if (com != null && !isBlocked(com)) {
      checkedId = s.nightActions[com.id];
      if (checkedId != null) {
        final target = s.byId(checkedId);
        checkIsMafia = target?.role?.type == RoleType.mafia;
      }
    }

    // Применение: защита доктора спасает и от мафии, и от маньяка.
    final killed = <String>[];
    if (mafiaTarget != null && mafiaTarget != healedId) {
      killed.add(mafiaTarget);
    }
    if (maniacTarget != null &&
        maniacTarget != healedId &&
        !killed.contains(maniacTarget)) {
      killed.add(maniacTarget);
    }

    return NightOutcome(
      killedIds: killed,
      mafiaTargetId: mafiaTarget,
      maniacTargetId: maniacTarget,
      healedId: healedId,
      blockedId: blockedId,
      checkedId: checkedId,
      checkResultIsMafia: checkIsMafia,
    );
  }

  /// Текст для оглашения ведущим вслух.
  static String announcement(GameState s, NightOutcome o) {
    if (o.killedIds.isEmpty) {
      return 'Город просыпается. Этой ночью обошлось без жертв.';
    }
    final names = o.killedIds.map(s.nameOf).join(' и ');
    return 'Город просыпается. Этой ночью мы потеряли: $names.';
  }
}
