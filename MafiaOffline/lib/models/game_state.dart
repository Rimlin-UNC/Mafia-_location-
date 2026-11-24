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

  /// Кого этой ночью прикрывал телохранитель и кому это стоило жизни.
  final String? guardedId;
  final String? guardDiedId;

  /// Кого запугивал шантажист: наступающий день этот игрок не голосует.
  final String? silencedId;

  /// За кем наблюдал свидетель и выходил ли тот из дома.
  final String? watchedId;
  final bool? watchedActed;

  /// Кого охотник отметил перед этой ночью.
  final String? hunterMarkId;

  /// Кого забрал с собой погибший охотник (кроме целей убийц).
  final List<String> revengeIds;

  const NightOutcome({
    this.killedIds = const [],
    this.mafiaTargetId,
    this.maniacTargetId,
    this.healedId,
    this.blockedId,
    this.checkedId,
    this.checkResultIsMafia,
    this.guardedId,
    this.guardDiedId,
    this.silencedId,
    this.watchedId,
    this.watchedActed,
    this.hunterMarkId,
    this.revengeIds = const [],
  });

  NightOutcome copyWith({
    List<String>? killedIds,
    String? mafiaTargetId,
    String? maniacTargetId,
    String? healedId,
    String? blockedId,
    String? checkedId,
    bool? checkResultIsMafia,
    String? guardedId,
    String? guardDiedId,
    String? silencedId,
    String? watchedId,
    bool? watchedActed,
    String? hunterMarkId,
    List<String>? revengeIds,
  }) {
    return NightOutcome(
      killedIds: killedIds ?? this.killedIds,
      mafiaTargetId: mafiaTargetId ?? this.mafiaTargetId,
      maniacTargetId: maniacTargetId ?? this.maniacTargetId,
      healedId: healedId ?? this.healedId,
      blockedId: blockedId ?? this.blockedId,
      checkedId: checkedId ?? this.checkedId,
      checkResultIsMafia: checkResultIsMafia ?? this.checkResultIsMafia,
      guardedId: guardedId ?? this.guardedId,
      guardDiedId: guardDiedId ?? this.guardDiedId,
      silencedId: silencedId ?? this.silencedId,
      watchedId: watchedId ?? this.watchedId,
      watchedActed: watchedActed ?? this.watchedActed,
      hunterMarkId: hunterMarkId ?? this.hunterMarkId,
      revengeIds: revengeIds ?? this.revengeIds,
    );
  }
}

/// Одна проверка комиссара: кто проверял, кого и что получил.
///
/// До 1.2.0 результат жил только в логе ведущего строкой текста. Отдельная
/// запись нужна, чтобы отдать комиссару ЕГО проверки после переподключения,
/// не разбирая лог и не показывая чужое (если комиссаров двое).
///
/// [blocked] — проверка не состоялась: комиссара в эту ночь заблокировали.
/// Запись всё равно ведём: иначе комиссар ждал бы ответа, которого не будет,
/// а после перезагрузки страницы не понял бы, куда делась ночь.
class CheckRecord {
  final int round;
  final String commissionerId;
  final String targetId;
  final bool isMafia;
  final bool blocked;

  const CheckRecord({
    required this.round,
    required this.commissionerId,
    required this.targetId,
    required this.isMafia,
    this.blocked = false,
  });

  Map<String, dynamic> toJson() => {
        'round': round,
        'by': commissionerId,
        'target': targetId,
        'isMafia': isMafia,
        if (blocked) 'blocked': true,
      };

  static CheckRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final by = raw['by'];
    final target = raw['target'];
    if (by is! String || target is! String) return null;
    return CheckRecord(
      round: raw['round'] is int ? raw['round'] as int : 0,
      commissionerId: by,
      targetId: target,
      isMafia: raw['isMafia'] == true,
      blocked: raw['blocked'] == true,
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

  /// Кого прикрывал телохранитель прошлой ночью — тоже нельзя повторять.
  /// Правило то же, что у доктора: иначе щит просто ставился бы на самого
  /// сильного игрока и больше не менялся.
  final String? lastGuardedId;

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

  // ---------- правила стола (v1.2.0) ----------

  /// «Первая ночь — знакомство»: в первую ночь никто не погибает.
  /// Мафия узнаёт своих, комиссар делает первую проверку, остальные спят.
  /// По умолчанию выключено — как играли до 1.2.0.
  final bool introNight;

  /// Последнее слово и повторное голосование. Тот, кого выбрал стол,
  /// ещё не выбыл: он говорит [Rules.lastWordSeconds] секунд, после чего
  /// стол голосует ещё раз — выгнать или оставить. Выключено — выбывает
  /// сразу по итогам первого голосования, как в 1.1.0.
  final bool lastWord;

  /// Комиссар видит результат своей проверки на собственном экране:
  /// ночью — сразу, как выбрал игрока, потом — в «Моя роль». Выключено —
  /// результат знает только ведущий и сообщает его сам, как в 1.1.0.
  final bool privateCheck;

  /// Кто сейчас говорит последнее слово. null — никто.
  /// Фаза при этом [GamePhase.day]: никто не голосует и не ходит.
  /// Говорящий ещё жив: его судьбу решит повторное голосование.
  final String? lastWordId;

  /// Чью судьбу решает повторное голосование («выгнать или оставить»).
  /// Фаза при этом [GamePhase.voting], единственный кандидат — он сам.
  /// Голос за него значит «выгнать», пропуск хода — «оставить».
  final String? verdictId;

  /// Все состоявшиеся проверки комиссара за партию.
  final List<CheckRecord> checks;

  /// Кого шантажист запугал прошлой ночью: в эту дату (раунд + фаза)
  /// он не голосует. Храним раунд, а не bool: «молчание» живёт ровно
  /// один день, и после смены раунда снимается само.
  final String? silencedId;
  final int silencedRound;

  /// Последнее наблюдение свидетеля: за кем следил и выходил ли тот.
  final String? watchTargetId;
  final bool? watchActed;
  final int watchRound;

  /// Кого охотник заберёт с собой, если погибнет. Действует со
  /// следующей ночи: метка ставится ночью, значит убийца этой же ночи
  /// ещё о ней «не знает».
  final String? hunterMarkId;

  /// Раунд, в котором боты уже высказались днём. Номер раунда, а не bool:
  /// после восстановления партии или повторной сборки экрана реплики
  /// текущего дня не должны отправляться второй раз.
  final int lastBotSpeechRound;

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
    this.lastGuardedId,
    this.openCards = false,
    this.storyId,
    this.storySeen = const [],
    this.noDeathsStreak = 0,
    this.introNight = false,
    this.lastWord = true,
    this.privateCheck = true,
    this.lastWordId,
    this.verdictId,
    this.checks = const [],
    this.lastBotSpeechRound = 0,
    this.silencedId,
    this.silencedRound = 0,
    this.watchTargetId,
    this.watchActed,
    this.watchRound = 0,
    this.hunterMarkId,
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
    String? lastGuardedId,
    bool? openCards,
    String? storyId,
    List<String>? storySeen,
    int? noDeathsStreak,
    bool? introNight,
    bool? lastWord,
    bool? privateCheck,
    String? lastWordId,
    String? verdictId,
    List<CheckRecord>? checks,
    int? lastBotSpeechRound,
    String? silencedId,
    int? silencedRound,
    String? watchTargetId,
    bool? watchActed,
    int? watchRound,
    String? hunterMarkId,
    bool clearSilenced = false,
    bool clearWatch = false,
    bool clearHunterMark = false,
    bool clearLastWord = false,
    bool clearVerdict = false,
    bool clearStory = false,
    bool clearPendingNight = false,
    bool clearLastHealed = false,
    bool clearLastGuarded = false,
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
      lastGuardedId:
          clearLastGuarded ? null : (lastGuardedId ?? this.lastGuardedId),
      openCards: openCards ?? this.openCards,
      storyId: clearStory ? null : (storyId ?? this.storyId),
      storySeen: storySeen ?? this.storySeen,
      noDeathsStreak: noDeathsStreak ?? this.noDeathsStreak,
      introNight: introNight ?? this.introNight,
      lastWord: lastWord ?? this.lastWord,
      privateCheck: privateCheck ?? this.privateCheck,
      lastWordId: clearLastWord ? null : (lastWordId ?? this.lastWordId),
      verdictId: clearVerdict ? null : (verdictId ?? this.verdictId),
      checks: checks ?? this.checks,
      lastBotSpeechRound:
          lastBotSpeechRound ?? this.lastBotSpeechRound,
      silencedId: clearSilenced ? null : (silencedId ?? this.silencedId),
      silencedRound: clearSilenced ? 0 : (silencedRound ?? this.silencedRound),
      watchTargetId: clearWatch ? null : (watchTargetId ?? this.watchTargetId),
      watchActed: clearWatch ? null : (watchActed ?? this.watchActed),
      watchRound: clearWatch ? 0 : (watchRound ?? this.watchRound),
      hunterMarkId:
          clearHunterMark ? null : (hunterMarkId ?? this.hunterMarkId),
    );
  }

  // ---------- выборки ----------

  List<Player> get alive => players.where((p) => p.isAlive).toList();

  List<Player> get dead => players.where((p) => !p.isAlive).toList();

  List<Player> get humans => players.where((p) => !p.isBot).toList();

  List<Player> get bots => players.where((p) => p.isBot).toList();

  bool get hasBots => bots.isNotEmpty;

  /// Локальный игрок: ведущий, который сам участвует в партии.
  Player? get localPlayer {
    for (final p in players) {
      if (p.isLocal) return p;
    }
    return null;
  }

  Player? byId(String? id) {
    if (id == null) return null;
    for (final p in players) {
      if (p.id == id) return p;
    }
    return null;
  }

  String nameOf(String? id) => byId(id)?.name ?? '—';

  /// Идёт ли сейчас «ночь знакомства»: настройка включена и это первая ночь.
  ///
  /// Проверяем именно фазу и номер раунда, а не «ещё никто не погиб»:
  /// во второй ночи тоже может не быть погибших, но убивать уже можно.
  bool get isIntroNight =>
      introNight && phase == GamePhase.night && round == 1;

  /// Ходит ли этот игрок текущей ночью.
  ///
  /// Единственное место, где решается «кто активен»: по нему считаются
  /// таймер ночи, список ожидаемых ходов и допуск действия на сервере.
  /// В ночь знакомства ходит только комиссар — убийцам некого убивать,
  /// доктору некого спасать, а блокировать единственную проверку значило
  /// бы отнять у города то немногое, что эта ночь ему даёт.
  bool actsTonight(Player p) {
    if (!p.isAlive) return false;
    final role = p.role;
    if (role == null || !role.isActiveAtNight) return false;
    if (isIntroNight) return role.type == RoleType.commissioner;
    return true;
  }

  /// Живые игроки, которые должны ходить этой ночью.
  List<Player> get nightActive => players.where(actsTonight).toList();

  /// Проверки, которые сделал конкретный комиссар (для его экрана).
  List<CheckRecord> checksBy(String playerId) =>
      checks.where((c) => c.commissionerId == playerId).toList();

  /// Убийцы мафии: те, чей ночной ход — выстрел, и чьи голоса складываются
  /// в общую жертву. Шантажист в этот список НЕ входит: его ход — не
  /// выстрел, и если считать его «голосом за жертву», мафия по ошибке
  /// убивала бы того, кого он всего лишь запугал.
  List<Player> get mafiaTeam => players
      .where((p) =>
          p.isAlive &&
          (p.role?.type == RoleType.mafia || p.role?.type == RoleType.don))
      .toList();

  /// Вся мафия, включая шантажиста: для «своих не трогаем», союзников на
  /// карточке и подсчёта победы.
  List<Player> get mafiaSiders =>
      players.where((p) => p.isAlive && p.role?.side == Side.mafia).toList();

  Player? get bodyguard => _firstAliveOfType(RoleType.bodyguard);
  Player? get witness => _firstAliveOfType(RoleType.witness);
  Player? get hunter => _firstAliveOfType(RoleType.hunter);
  Player? get blackmailer => _firstAliveOfType(RoleType.blackmailer);

  /// Запуган ли этот игрок прямо сейчас: шантаж действует только на
  /// следующий за ночью день и только один раз.
  bool isSilencedNow(Player? p) =>
      p != null && silencedId != null && silencedId == p.id;

  /// Свидетель узнал что-то в этом раунде.
  bool get hasFreshWatch =>
      watchTargetId != null && watchRound == round;

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

  /// Все живые люди, которым есть чем ходить этой ночью, уже сходили.
  /// После этого боты могут сделать свои ходы не дожидаясь таймера.
  bool get humanNightActionsIn => nightActive
      .where((p) => !p.isBot)
      .every((p) => nightActions.containsKey(p.id));

  /// Кто из игроков ещё не подтвердил, что прочитал свою роль.
  List<Player> get unacknowledged =>
      players.where((p) => !p.roleAcknowledged).toList();

  /// Все ли прочитали роль. Пустой список игроков готовым не считается:
  /// раздавать роли некому.
  bool get allRolesAcknowledged =>
      players.isNotEmpty && unacknowledged.isEmpty;

  /// Идёт ли повторное голосование после последнего слова.
  bool get isVerdictVote => phase == GamePhase.voting && verdictId != null;

  /// Кто голосует в текущем туре. В повторном голосовании обвиняемый
  /// не голосует: его голос «оставить» был бы голосом за самого себя.
  ///
  /// Запуганный шантажистом игрок в этот день не голосует вообще: его нет
  /// в списке голосующих, поэтому фаза не ждёт его хода.
  List<Player> get voters {
    final base = isVerdictVote
        ? alive.where((p) => p.id != verdictId).toList()
        : alive;
    return base.where((p) => !isSilencedNow(p)).toList();
  }

  /// Кто из голосующих ещё не проголосовал.
  List<Player> get pendingVoters =>
      voters.where((p) => !votes.containsKey(p.id)).toList();

  bool get allVotesIn => pendingVoters.isEmpty;

  /// Все люди уже проголосовали; остальные голоса можно отдать ботам.
  bool get humanVotesIn => voters
      .where((p) => !p.isBot)
      .every((p) => votes.containsKey(p.id));

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
    // В соло-партии обсуждение нужно только чтобы прочитать реплики ботов:
    // живого спора между несколькими людьми нет, и пять минут таймера
    // превращали бы игру в ожидание.
    if (humans.length <= 1) return Rules.soloDaySeconds;
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

  // ---------- повторное голосование ----------

  /// Голоса «выгнать» в повторном голосовании.
  int get verdictExile => verdictId == null
      ? 0
      : votes.values.where((v) => v == verdictId).length;

  /// Голоса «оставить». Не проголосовавшие не считаются ни туда, ни сюда.
  int get verdictKeep => votes.values.where((v) => v == null).length;

  /// Решение стола: выгнать, только если «за» строго больше, чем «против».
  /// Равенство — в пользу игрока: сомнение трактуется как «оставить»,
  /// так же, как повторная ничья в обычном голосовании никого не выгоняет.
  bool get verdictPasses => verdictExile > verdictKeep;

  /// Кто голосовал «оставить» (только для ведущего).
  List<String> get verdictKeepers {
    final result = <String>[];
    votes.forEach((voter, candidate) {
      if (candidate == null) result.add(nameOf(voter));
    });
    return result;
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
