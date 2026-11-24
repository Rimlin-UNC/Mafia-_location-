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

  /// Допустимые цели для ночного хода или голосования.
  ///
  /// Единственный источник этого списка для людей, ботов и серверной
  /// проверки: цель, которой нет здесь, не может уйти по протоколу.
  /// Мафия не стреляет по своим, доктор не лечит себя и не повторяет
  /// прошлоночную цель, в голосовании нельзя выбрать себя.
  static List<Player> legalTargetsFor(GameState s, Player player) {
    Iterable<Player> candidates = s.alive;

    if (s.phase == GamePhase.night) {
      final type = player.role?.type;
      if (type == RoleType.mafia || type == RoleType.don) {
        candidates = candidates.where((c) =>
            c.role?.type != RoleType.mafia &&
            c.role?.type != RoleType.don);
      }
      if (type == RoleType.prostitute ||
          type == RoleType.commissioner ||
          type == RoleType.doctor ||
          type == RoleType.maniac) {
        candidates = candidates.where((c) => c.id != player.id);
      }
      if (type == RoleType.doctor && s.lastHealedId != null) {
        candidates = candidates.where((c) => c.id != s.lastHealedId);
      }
    } else if (s.phase == GamePhase.voting) {
      candidates = candidates.where((c) => c.id != player.id);
      if (s.runoffCandidates.isNotEmpty) {
        candidates =
            candidates.where((c) => s.runoffCandidates.contains(c.id));
      }
    } else {
      return const [];
    }

    return candidates.toList();
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
      return const RoleCheckResult(accepted: false, already: true);
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

    // Главное правило баланса: после раздачи никто не должен победить
    // сразу. Проверка повторяет `GameState.checkWinner` — мафия побеждает
    // при mafia >= city, где city НЕ включает маньяка (он одиночка).
    //
    // Раньше здесь стояло условие `players.length - mafia <= 1`: оно
    // допускало равный состав (3 мафии / 3 города) — но `checkWinner`
    // объявляет победу именно при равенстве (`mafia >= civ`). В итоге
    // пресет «2 мафии + дон» на 6 пришедших давал 3 на 3, партия
    // заканчивалась победой мафии в первую секунду, и город не успевал
    // сделать ни одного хода. Проверено tools/forcestart.py и тестом
    // «раздача не создаёт уже выигранную партию».
    int mafiaCount() => pool
        .where((r) => r == RoleType.mafia || r == RoleType.don)
        .length;
    int maniacCount() => pool.where((r) => r == RoleType.maniac).length;

    while (pool.isNotEmpty && mafiaCount() > 0) {
      final mafia = mafiaCount();
      final city = players.length - mafia - maniacCount();
      if (mafia < city) break;
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

    // Ночь знакомства (v1.2.0): никто не погибает, никого не лечат и не
    // блокируют — считается только проверка комиссара. Правило стоит
    // ЗДЕСЬ, а не только в списке целей на экране: даже если клиент
    // пришлёт ход убийцы, движок его не применит.
    if (s.isIntroNight) {
      final com = s.commissioner;
      final checked = com == null ? null : s.nightActions[com.id];
      return NightOutcome(
        checkedId: checked,
        checkResultIsMafia: checked == null
            ? null
            : s.byId(checked)?.role?.type == RoleType.mafia,
      );
    }

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
      // Классика: доктор не лечит себя. В 1.0.x мог — это делало его
      // бессмертным в партии на 6 человек и ломало баланс.
      final selfHeal = target == doc.id;
      // Нельзя лечить одну цель две ночи подряд.
      if (target != null && !selfHeal && target != s.lastHealedId) {
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
    if (s.isIntroNight) {
      return 'Город просыпается. Это была ночь знакомства: все живы. '
          'Но мафия уже знает своих.';
    }
    if (o.killedIds.isEmpty) {
      return 'Город просыпается. Этой ночью обошлось без жертв.';
    }
    final names = o.killedIds.map(s.nameOf).join(' и ');
    return 'Город просыпается. Этой ночью мы потеряли: $names.';
  }
}

/// Правила стола — то, о чём ведущий договорился с игроками при создании
/// партии. Собраны в одном месте, чтобы экран ведущего, пакет для игроков
/// и протокол партии называли их одинаково.
class TableRules {
  /// Строки для показа человеку: только включённые правила плюс те,
  /// выключение которых меняет привычный ход игры.
  static List<String> describe(GameState s) => describeWire(toWire(s));

  /// Те же строки из пакета `lobby.rules` — для экрана игрока, у которого
  /// нет [GameState]. Один текст на обе стороны: ведущий и игрок читают
  /// одни и те же формулировки, спорить о словах не приходится.
  ///
  /// Пакета нет (ведущий на 1.1.x) — список пустой, и раздел не рисуется.
  /// Отсутствующий ключ читается как «выключено»: клиент не должен
  /// обещать игроку правило, о котором ведущий ничего не сказал.
  static List<String> describeWire(Map<String, dynamic>? wire) {
    final w = wire;
    if (w == null) return const [];
    bool on(String key) => w[key] == true;
    final seconds = w['lastWordSeconds'];
    return [
      on('openCards')
          ? 'Карта выбывшего открывается сразу'
          : 'Карта выбывшего закрыта до конца партии',
      if (on('introNight')) 'Первая ночь — знакомство: никто не погибает',
      if (on('lastWord'))
        'Перед изгнанием — последнее слово, '
            '${seconds is int ? seconds : Rules.lastWordSeconds} секунд, '
            'и повторное голосование: стол может оставить игрока'
      else
        'Выбывает тот, кого выбрало голосование, — без последнего слова',
      on('privateCheck')
          ? 'Комиссар видит ответ на проверку сразу, как выберет игрока; '
              'все его проверки — в «Моя роль»'
          : 'Результат проверки комиссару сообщает ведущий',
    ];
  }

  /// То же самое для клиента: он сам решает, как это показать.
  static Map<String, dynamic> toWire(GameState s) => {
        'openCards': s.openCards,
        'introNight': s.introNight,
        'lastWord': s.lastWord,
        'lastWordSeconds': Rules.lastWordSeconds,
        'privateCheck': s.privateCheck,
      };
}

/// Запись о проверке комиссара по итогам ночи или null, если проверки
/// не было вовсе (комиссара нет или он пропустил ход).
///
/// Заблокированный комиссар получает запись с [CheckRecord.blocked]:
/// он выбирал цель и должен узнать, что ответа не будет.
///
/// [s] — состояние ДО применения смертей этой ночи: комиссар, убитый
/// той же ночью, проверку всё равно сделал.
CheckRecord? checkRecordFor(GameState s, NightOutcome o) {
  final com = s.commissioner;
  if (com == null) return null;
  final target = o.checkedId;
  if (target != null) {
    return CheckRecord(
      round: s.round,
      commissionerId: com.id,
      targetId: target,
      isMafia: o.checkResultIsMafia == true,
    );
  }
  final wanted = s.nightActions[com.id];
  if (wanted != null && o.blockedId == com.id) {
    return CheckRecord(
      round: s.round,
      commissionerId: com.id,
      targetId: wanted,
      isMafia: false,
      blocked: true,
    );
  }
  return null;
}

/// Что уже можно сказать комиссару о его проверке — прямо сейчас, ночью,
/// не дожидаясь рассвета. null — сказать пока нечего.
///
/// Комиссар видит ответ сразу, как выбрал игрока. Единственное, что может
/// отменить проверку, — блокировка проститутки, поэтому:
///
///  * проститутки нет в живых или идёт ночь знакомства — ответ сразу;
///  * проститутка уже сходила — ответ сразу (или «вас заблокировали»);
///  * проститутка ещё не сходила — ждём её хода: показать ответ, а потом
///    отменить его блокировкой нельзя, увиденное уже не забыть;
///  * ночь закрыта ([GameState.pendingNight] посчитан) — ответ по итогу.
///
/// Функция обязана совпадать с [GameEngine.resolveNight]: то, что комиссар
/// увидел ночью, утром не должно оказаться другим. Это проверяет тест
/// «ранний ответ совпадает с итогом ночи».
CheckRecord? checkKnownNow(GameState s) {
  if (s.phase != GamePhase.night) return null;
  final com = s.commissioner;
  if (com == null) return null;
  final target = s.nightActions[com.id];
  if (target == null) return null; // ещё не ходил или пропустил ход

  final outcome = s.pendingNight;
  if (outcome != null) return checkRecordFor(s, outcome);

  var blocked = false;
  if (!s.isIntroNight) {
    final pros = s.prostitute;
    if (pros != null) {
      if (!s.nightActions.containsKey(pros.id)) return null;
      blocked = s.nightActions[pros.id] == com.id;
    }
  }
  return CheckRecord(
    round: s.round,
    commissionerId: com.id,
    targetId: target,
    isMafia: !blocked && s.byId(target)?.role?.type == RoleType.mafia,
    blocked: blocked,
  );
}

/// Проверки комиссара в виде, готовом к отправке ему на экран.
/// Имена подставляются в момент отправки: ведущий мог переименовать игрока.
List<Map<String, dynamic>> checksWireFor(GameState s, String playerId) => [
      for (final c in s.checksBy(playerId))
        {
          'round': c.round,
          'name': s.nameOf(c.targetId),
          'isMafia': c.isMafia,
          if (c.blocked) 'blocked': true,
        },
    ];

/// Одна проверка в виде пакета `check_result`.
Map<String, dynamic> checkWire(GameState s, CheckRecord c) => {
      'round': c.round,
      'name': s.nameOf(c.targetId),
      'isMafia': c.isMafia,
      if (c.blocked) 'blocked': true,
    };

/// Нужно ли дать последнее слово тому, кого выбрало голосование.
///
/// Слово даётся ДО выбывания: после него стол голосует ещё раз и может
/// оставить игрока. Поэтому условие одно — правило включено и это ещё
/// не повторное голосование (после него слова уже нет: человек всё сказал).
///
/// Намеренно НЕ смотрим, закончит ли изгнание партию. Если бы слово
/// пропускалось, когда выбран последний мафиози, стол узнавал бы его роль
/// по самому факту пропуска — до того, как решил, выгонять ли.
bool shouldGiveLastWord(GameState s) => s.lastWord && s.verdictId == null;

/// Что делать с запросом регистрации. Вынесено из `HostController`, чтобы
/// правило «свой слот» можно было проверить тестом без запуска сервера.
enum RegisterVerdict {
  /// Игрок новый — создаём.
  create,

  /// Имя занято живым игроком с другого устройства — отказ.
  denyNameTaken,

  /// Это тот же игрок: вернуть его в слот (роль и голоса сохраняются).
  reclaim,

  /// Вернулся в свой слот, придя с другого устройства (deviceId совпал) —
  /// отличить в логе: «открыл игру на другом устройстве».
  reclaimOtherDevice,

  /// Партия уже началась, состав зафиксирован.
  denyGameStarted,

  /// Мест нет.
  denyGameFull,
}

/// Разбор запроса на регистрацию. [isOnline] — занят ли слот живым сокетом.
///
/// Порядок проверок существенный и он же — найденный ранее баг:
/// возврат в свой слот проверяется ДО «игра уже началась». Иначе игрок,
/// у которого разрядился телефон посреди партии, получает отказ и теряет роль.
RegisterVerdict resolveRegister({
  required String name,
  required String? deviceId,
  required GameState state,
  required bool Function(String playerId) isOnline,
}) {
  final lower = name.trim().toLowerCase();
  final index = state.players
      .indexWhere((p) => p.name.trim().toLowerCase() == lower);

  if (index != -1) {
    final existing = state.players[index];
    // Бот и локальный игрок не имеют сокета. Без этой проверки любой
    // мог бы «вернуться» в их слот по имени и получить чужую роль.
    if (existing.isBot || existing.isLocal) {
      return RegisterVerdict.denyNameTaken;
    }
    final online = isOnline(existing.id);
    final sameDevice = deviceId != null &&
        existing.deviceId != null &&
        deviceId == existing.deviceId;
    // Тот же человек с планшета: слот его, даже если телефон ещё в сети.
    if (online && !sameDevice) return RegisterVerdict.denyNameTaken;
    if (sameDevice && online) return RegisterVerdict.reclaimOtherDevice;
    return RegisterVerdict.reclaim;
  }

  // Новых пускаем только в лобби: фаза проверки ролей — уже игра.
  if (state.phase != GamePhase.waiting) return RegisterVerdict.denyGameStarted;
  if (state.players.length >= Rules.maxPlayers) {
    return RegisterVerdict.denyGameFull;
  }
  return RegisterVerdict.create;
}
