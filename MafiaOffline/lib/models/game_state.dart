import '../core/constants.dart';
import 'game_event.dart';
import 'game_phase.dart';
import 'player.dart';
import 'role.dart';

enum WinnerSide { mafia, civilians, maniac, nobody, aborted }

extension WinnerSideX on WinnerSide {
  String get title {
    switch (this) {
      case WinnerSide.mafia:
        return 'Победила мафия';
      case WinnerSide.civilians:
        return 'Победили мирные жители';
      case WinnerSide.maniac:
        return 'Победил маньяк';
      case WinnerSide.nobody:
        return 'Ничья — никто не выжил';
      case WinnerSide.aborted:
        return 'Партия прервана';
    }
  }
}

/// Результат разрешения ночи — то, что видит ведущий перед оглашением.
class NightOutcome {
  final List<String> killedIds;
  final String? mafiaTargetId;
  final String? maniacTargetId;
  final String? healedId;
  final String? blockedId;
  final String? checkedId;
  final bool? checkResultIsMafia;

  const NightOutcome({
    this.killedIds = const [],
    this.mafiaTargetId,
    this.maniacTargetId,
    this.healedId,
    this.blockedId,
    this.checkedId,
    this.checkResultIsMafia,
  });

  NightOutcome copyWith({
    List<String>? killedIds,
    String? mafiaTargetId,
    String? maniacTargetId,
    String? healedId,
    String? blockedId,
    String? checkedId,
    bool? checkResultIsMafia,
  }) {
    return NightOutcome(
      killedIds: killedIds ?? this.killedIds,
      mafiaTargetId: mafiaTargetId ?? this.mafiaTargetId,
      maniacTargetId: maniacTargetId ?? this.maniacTargetId,
      healedId: healedId ?? this.healedId,
      blockedId: blockedId ?? this.blockedId,
      checkedId: checkedId ?? this.checkedId,
      checkResultIsMafia: checkResultIsMafia ?? this.checkResultIsMafia,
    );
  }
}

/// Полное состояние партии. Неизменяемое: любое изменение — через copyWith.
class GameState {
  final String id;
  final String name;
  final String code;
  final DateTime createdAt;
  final DateTime? endedAt;

  final List<Player> players;
  final Map<RoleType, int> roleSetup;
  final int plannedPlayers;

  final GamePhase phase;
  final int round;
  final int timeLeft;
  final bool paused;

  /// playerId -> targetId (null = осознанный пропуск)
  final Map<String, String?> nightActions;

  /// voterId -> candidateId (null = воздержался)
  final Map<String, String?> votes;

  /// Кандидаты второго тура. Пусто — идёт первый тур.
  final List<String> runoffCandidates;

  final NightOutcome? pendingNight;

  /// Приём голосов закрыт, ведущий подтверждает результат.
  final bool awaitingVoteConfirm;
  final List<GameEvent> log;
  final WinnerSide? winner;

  /// Кого лечил доктор прошлой ночью — нельзя повторять.
  final String? lastHealedId;

  /// Показывать ли всем роль выбывшего игрока. По умолчанию закрыта:
  /// раскрытая карта упрощает город, но убивает интригу первого круга.
  final bool openCards;

  /// Сюжетная карточка, показанная прямо сейчас (id из StoryDeck).
  /// null — ничего не показываем. Сбрасывается кнопкой на экране игрока.
  final String? storyId;

  /// Уже показанные в этой партии карточки: две одинаковые не показываем.
  final List<String> storySeen;

  /// Сколько голосований подряд закончилось без выбывшего.
  /// Нужно для карточки «город не может решить».
  final int noDeathsStreak;

  const GameState({
    required this.id,
    required this.name,
    required this.code,
    required this.createdAt,
    this.endedAt,
    this.players = const [],
    this.roleSetup = const {},
    this.plannedPlayers = 0,
    this.phase = GamePhase.waiting,
    this.round = 0,
    this.timeLeft = 0,
    this.paused = false,
    this.nightActions = const {},
    this.votes = const {},
    this.runoffCandidates = const [],
    this.pendingNight,
    this.awaitingVoteConfirm = false,
    this.log = const [],
    this.winner,
    this.lastHealedId,
    this.openCards = false,
    this.storyId,
    this.storySeen = const [],
    this.noDeathsStreak = 0,
  });

  GameState copyWith({
    String? name,
    DateTime? endedAt,
    List<Player>? players,
    Map<RoleType, int>? roleSetup,
    int? plannedPlayers,
    GamePhase? phase,
    int? round,
    int? timeLeft,
    bool? paused,
    Map<String, String?>? nightActions,
    Map<String, String?>? votes,
    List<String>? runoffCandidates,
    NightOutcome? pendingNight,
    bool? awaitingVoteConfirm,
    List<GameEvent>? log,
    WinnerSide? winner,
    String? lastHealedId,
    bool? openCards,
    String? storyId,
    List<String>? storySeen,
    int? noDeathsStreak,
    bool clearStory = false,
    bool clearPendingNight = false,
    bool clearLastHealed = false,
  }) {
    return GameState(
      id: id,
      name: name ?? this.name,
      code: code,
      createdAt: createdAt,
      endedAt: endedAt ?? this.endedAt,
      players: players ?? this.players,
      roleSetup: roleSetup ?? this.roleSetup,
      plannedPlayers: plannedPlayers ?? this.plannedPlayers,
      phase: phase ?? this.phase,
      round: round ?? this.round,
      timeLeft: timeLeft ?? this.timeLeft,
      paused: paused ?? this.paused,
      nightActions: nightActions ?? this.nightActions,
      votes: votes ?? this.votes,
      runoffCandidates: runoffCandidates ?? this.runoffCandidates,
      pendingNight:
          clearPendingNight ? null : (pendingNight ?? this.pendingNight),
      awaitingVoteConfirm: awaitingVoteConfirm ?? this.awaitingVoteConfirm,
      log: log ?? this.log,
      winner: winner ?? this.winner,
      lastHealedId: clearLastHealed ? null : (lastHealedId ?? this.lastHealedId),
      openCards: openCards ?? this.openCards,
      storyId: clearStory ? null : (storyId ?? this.storyId),
      storySeen: storySeen ?? this.storySeen,
      noDeathsStreak: noDeathsStreak ?? this.noDeathsStreak,
    );
  }

  // ---------- выборки ----------

  List<Player> get alive => players.where((p) => p.isAlive).toList();

  List<Player> get dead => players.where((p) => !p.isAlive).toList();

  Player? byId(String? id) {
    if (id == null) return null;
    for (final p in players) {
      if (p.id == id) return p;
    }
    return null;
  }

  String nameOf(String? id) => byId(id)?.name ?? '—';

  /// Живые игроки, которые должны ходить этой ночью.
  List<Player> get nightActive => players
      .where((p) => p.isAlive && (p.role?.isActiveAtNight ?? false))
      .toList();

  List<Player> get mafiaTeam => players
      .where((p) =>
          p.isAlive &&
          (p.role?.type == RoleType.mafia || p.role?.type == RoleType.don))
      .toList();

  Player? get don => _firstAliveOfType(RoleType.don);
  Player? get doctor => _firstAliveOfType(RoleType.doctor);
  Player? get commissioner => _firstAliveOfType(RoleType.commissioner);
  Player? get prostitute => _firstAliveOfType(RoleType.prostitute);
  Player? get maniac => _firstAliveOfType(RoleType.maniac);

  Player? _firstAliveOfType(RoleType t) {
    for (final p in players) {
      if (p.isAlive && p.role?.type == t) return p;
    }
    return null;
  }

  /// Кто из активных ночью ещё не прислал действие.
  List<Player> get pendingActors =>
      nightActive.where((p) => !nightActions.containsKey(p.id)).toList();

  bool get allNightActionsIn => pendingActors.isEmpty;

  /// Кто из игроков ещё не подтвердил, что прочитал свою роль.
  List<Player> get unacknowledged =>
      players.where((p) => !p.roleAcknowledged).toList();

  /// Все ли прочитали роль. Пустой список игроков готовым не считается:
  /// раздавать роли некому.
  bool get allRolesAcknowledged =>
      players.isNotEmpty && unacknowledged.isEmpty;

  /// Кто из живых ещё не проголосовал.
  List<Player> get pendingVoters =>
      alive.where((p) => !votes.containsKey(p.id)).toList();

  bool get allVotesIn => pendingVoters.isEmpty;

  // ---------- длительности фаз ----------

  /// Длительность ночи.
  ///
  /// Первая ночь длиннее: люди ещё читают памятку, ищут кнопку и выбирают
  /// цель впервые. 20 базовых секунд хороши для третьего раунда и мало
  /// для первого — за столом это выглядит как «не дали даже подумать».
  int get nightDuration {
    final base =
        Rules.nightBaseSeconds + Rules.nightPerActiveSeconds * nightActive.length;
    if (round <= 1) {
      return (base * Rules.firstNightFactor).round();
    }
    return base;
  }

  int get dayDuration {
    final raw = Rules.dayPerPlayerSeconds * alive.length;
    return raw > Rules.dayMaxSeconds ? Rules.dayMaxSeconds : raw;
  }

  /// Голосование зависит от числа живых: читать список из 20 имён дольше,
  /// чем из шести.
  int get votingDuration =>
      Rules.votingBaseSeconds + Rules.votingPerPlayerSeconds * alive.length;

  int get runoffDuration =>
      Rules.runoffBaseSeconds + Rules.runoffPerPlayerSeconds * alive.length;

  // ---------- условия победы ----------

  /// Проверка победы. Возвращает null, если партия продолжается.
  ///
  /// Правило простое — играем до последнего:
  ///
  ///   * **город побеждает**, когда вся мафия выбыла. Неважно, сколько
  ///     горожан осталось и какие у них роли;
  ///   * **мафия побеждает**, когда против неё остался один человек.
  ///     Дальше играть бессмысленно: ночью мафия его убьёт, а днём его
  ///     одинокого голоса не хватит, чтобы кого-то выгнать.
  ///
  /// Ситуация «трое на трое» победой НЕ считается: у города ещё есть
  /// дневное голосование, и он вполне может переломить ход партии.
  /// Именно поэтому состав на 6 игроков (дон + 2 мафии против доктора,
  /// комиссара и проститутки) — честный, а не заведомо проигрышный.
  ///
  /// Маньяк относится к мирным жителям: он тоже голосует днём и
  /// заинтересован в победе над мафией, просто по ночам убивает.
  /// Классические условия победы (с версии 1.1.0).
  ///
  /// Порядок проверок определяет, кто получает победу в спорном раскладе:
  /// если одна ночь убрала всех, победа достаётся тому, кто её устроил.
  ///
  /// Отличия от 1.0.4+ («играем до последнего»):
  ///  * мафия побеждает при равенстве (`mafia >= civilians`), как за столом:
  ///    город уже не может выгнать мафию голосованием;
  ///  * маньяк — одиночка со своей победой, а не «городской линчеватель».
  WinnerSide? checkWinner() {
    final aliveList = alive;
    if (aliveList.isEmpty) return WinnerSide.nobody;

    final mafiaCount =
        aliveList.where((p) => p.role?.side == Side.mafia).length;
    final maniacCount =
        aliveList.where((p) => p.role?.type == RoleType.maniac).length;
    final civilianCount = aliveList.length - mafiaCount - maniacCount;

    // Маньяк остался один — победил он. Проверяем первым: это самый
    // редкий и самый «дорогой» исход, и он не должен утонуть в ветке города.
    if (maniacCount > 0 && mafiaCount == 0 && civilianCount == 0) {
      return WinnerSide.maniac;
    }

    // Мафии не осталось, и маньяка тоже — победа города.
    if (mafiaCount == 0 && maniacCount == 0) return WinnerSide.civilians;

    // Мафия сравнялась с городом (без учёта маньяка) — исход предрешён.
    if (mafiaCount > 0 && mafiaCount >= civilianCount) return WinnerSide.mafia;

    return null;
  }

  // ---------- подсчёт голосов ----------

  /// candidateId -> количество голосов (воздержавшиеся не считаются).
  Map<String, int> get voteTally {
    final tally = <String, int>{};
    votes.forEach((_, candidate) {
      if (candidate != null) {
        tally[candidate] = (tally[candidate] ?? 0) + 1;
      }
    });
    return tally;
  }

  /// Кандидаты с максимальным числом голосов.
  List<String> get voteLeaders {
    final tally = voteTally;
    if (tally.isEmpty) return const [];
    final max = tally.values.reduce((a, b) => a > b ? a : b);
    return tally.entries
        .where((e) => e.value == max)
        .map((e) => e.key)
        .toList();
  }

  /// Кто голосовал за конкретного кандидата (только для ведущего).
  List<String> votersFor(String candidateId) {
    final result = <String>[];
    votes.forEach((voter, candidate) {
      if (candidate == candidateId) result.add(nameOf(voter));
    });
    return result;
  }
}
