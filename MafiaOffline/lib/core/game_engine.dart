import 'dart:math';

import '../core/constants.dart';
import '../models/game_phase.dart';
import '../models/game_state.dart';
import '../models/player.dart';
import '../models/role.dart';

/// Итог обработки `role_ack`. Отдельный тип вместо `String?`-ошибки:
/// вызывающему нужно различать «приняли», «уже подтверждено» и «нельзя».
class RoleCheckResult {
  /// Флаг изменился — состояние в [state] новое.
  final bool accepted;

  /// Игрок нажал «Понятно» повторно: ничего не меняем, но это не ошибка.
  final bool already;

  final String? reason;

  /// Новое состояние (только при [accepted]).
  final GameState? state;

  const RoleCheckResult({
    required this.accepted,
    this.already = false,
    this.reason,
    this.state,
  });
}

/// Чистая игровая логика без UI и сети. Легко покрывается тестами.
class GameEngine {
  /// Раздача ролей по заданному составу.
  /// Если игроков меньше, чем заявлено, лишние специальные роли
  /// отбрасываются по приоритету (маньяк → проститутка → комиссар → доктор).
  /// Проверка состава перед созданием партии (FR-1.5, BR-2).
  ///
  /// Раньше правило жило только в `setup_screen.dart` — то есть состав,
  /// загруженный из пользовательского пресета или пришедший из старой
  /// версии, мог проскочить мимо проверки. Один источник истины.
  ///
  /// Возвращает null, если состав корректен, иначе — текст причины.
  static String? validateSetup({
    required Map<RoleType, int> setup,
    required int players,
  }) {
    if (players < Rules.minPlayers || players > Rules.maxPlayers) {
      return 'Игроков должно быть от ${Rules.minPlayers} до ${Rules.maxPlayers}';
    }
    var special = 0;
    for (final entry in setup.entries) {
      if (entry.value < 0) return 'Число ролей не может быть отрицательным';
      if (entry.key == RoleType.civilian) {
        return 'Мирных не задают вручную — они считаются автоматически';
      }
      special += entry.value;
    }
    if (special > players) {
      return 'Специальных ролей ($special) больше, чем игроков ($players)';
    }
    // Мафия без единого мафиози — играть не с кем.
    final mafia = (setup[RoleType.mafia] ?? 0) + (setup[RoleType.don] ?? 0);
    if (mafia == 0) return 'Не назначено ни одного мафиози';
    return null;
  }

  /// Баланс состава: предупреждение, а не запрет.
  ///
  /// Возвращает null, если перевес в пределах разумного, иначе текст
  /// предупреждения. Пороги — из симуляции (см. `setup_screen.dart`):
  /// мафия против одного игрока проигрывает, сразу после первой ночи
  /// большинство голосов уже у мафии.
  static String? balanceWarning({
    required Map<RoleType, int> setup,
    required int players,
  }) {
    final mafia = (setup[RoleType.mafia] ?? 0) + (setup[RoleType.don] ?? 0);
    if (mafia == 0) return 'Мафии нет — играть не с кем';
    final others = players - mafia;
    if (others <= 1) {
      return 'Против мафии меньше двух игроков — город проиграет сразу';
    }
    if (mafia >= others - 1) {
      return 'Мафия $mafia против $others: уже после первой ночи у мафии '
          'будет большинство голосов — город почти обречён.';
    }
    return null;
  }

  /// Результат «прочитать роль»: кто подтвердил и кто ещё нет.
  ///
  /// Чистая функция — её можно проверить без сервера и без виджетов,
  /// и именно она решает, начнётся ли первая ночь (FR-3.6). Раньше эта
  /// логика жила в `HostController` и не была покрыта ничем.
  static RoleCheckResult applyRoleAck(GameState state, String playerId) {
    final player = state.byId(playerId);
    if (player == null) {
      return const RoleCheckResult(accepted: false, reason: 'Игрок не найден');
    }
    if (player.role == null) {
      return const RoleCheckResult(accepted: false, reason: 'Роли ещё не розданы');
    }
    // Повторное нажатие не должно ни менять счётчик, ни писать лог заново.
    if (player.roleAcknowledged) {
      return RoleCheckResult(accepted: false, already: true);
    }

    final updated = state.copyWith(
      players: state.players
          .map((p) =>
              p.id == playerId ? p.copyWith(roleAcknowledged: true) : p)
          .toList(),
    );
    return RoleCheckResult(accepted: true, state: updated);
  }

  /// Готова ли партия начать первую ночь: все роли прочитаны.
  static bool canStartNight(GameState state) =>
      state.phase == GamePhase.rolesCheck && state.allRolesAcknowledged;

  /// Кого ведущий оставляет позади, если запускает ночь не дожидаясь.
  static List<String> pendingRoleNames(GameState state) =>
      state.unacknowledged.map((p) => p.name).toList();

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
