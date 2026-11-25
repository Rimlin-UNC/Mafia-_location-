import 'dart:math';

import '../core/constants.dart';
import '../models/game_phase.dart';
import '../models/game_state.dart';
import '../models/player.dart';
import '../models/role.dart';
import 'game_engine.dart';

/// Одна реплика бота в дневном обсуждении.
class BotSpeech {
  final String playerId;
  final String text;

  const BotSpeech({required this.playerId, required this.text});
}

/// Боты для партии, в которой не хватает людей.
///
/// Важно: бот не читает чужие роли. Ему доступны только те сведения,
/// которые есть у живого игрока с той же ролью:
///  * мафия знает свою команду;
///  * комиссар помнит собственные проверки;
///  * все видят публичные события и текущие голоса.
///
/// Отдельный класс, а не ветки в HostController: цели и реплики —
/// чистые функции, которые можно прогнать на сотнях партий без сервера.
class BotEngine {
  static const List<String> names = [
    'Алекс', 'Марина', 'Глеб', 'Снежана', 'Борис',
    'Кристина', 'Эдуард', 'Анжела', 'Тимофей', 'Изольда',
    'Гоша', 'Лариса', 'Милана', 'Аркадий', 'Жанна',
    'Валера', 'Геннадий', 'Полина', 'Роман', 'Вера',
  ];

  static const List<String> _chatter = [
    'Пока ни в кого не верю. Присматриваюсь.',
    'Давайте сначала услышаем тех, кто ещё не говорил.',
    'Мне кажется, кто-то слишком старается казаться мирным.',
    'У меня пока только вопросы. К ночи вернёмся к фактам.',
    'Не торопитесь с голосованием: ошибка стоит городу игрока.',
    'Я сегодня с алиби: спал и никого не видел.',
    'Слишком тихий стол. Молчание тоже бывает показанием.',
    'Предлагаю проверить самого активного говоруна.',
  ];

  static const List<String> _suspect = [
    'Мне не нравится {x}. Пока это только ощущение, но запомню его.',
    'Мой кандидат на сегодня — {x}.',
    '{x} как-то слишком уверенно всё объясняет.',
    'Голосую за {x}, если никто не приведёт более веский аргумент.',
  ];

  /// Защита того, кого город уже обвиняет.
  ///
  /// Раньше боты умели только обвинять: любой бот-город называл случайную
  /// жертву, даже если она проверена комиссаром как мирная. За столом это
  /// выглядело как «боты не слушают факты». Теперь есть отдельная ветка:
  /// если обвиняемый чист по своей проверке — бот вступается.
  static const List<String> _defend = [
    'Не согласен по {x}: у меня он проходит как мирный. Ищите в другом месте.',
    'За {x} я не голосую — и вам не советую. Это трата дня.',
    '{x} сегодня не наш кандидат. Смотрите на тех, кто молчит.',
  ];

  /// Реплика того, кого обвинили. Защита без факта — так и должно быть:
  /// бот не знает чужих ролей и может только сказать, что он свой.
  static const List<String> _selfDefense = [
    'Я мирный. Обвинение против меня ничего не даёт городу, кроме дня.',
    'Если выгоните меня — потеряете день. Ищите мафию, а не удобного.',
    'Голосуйте как хотите, но моя роль городу нужна. Я не уйду без боя.',
  ];

  static const List<String> _foundMafia = [
    'Раскрываюсь: я комиссар. Проверка этой ночи: {x} — мафия!',
    'У меня есть факт, а не догадка: {x} — мафия. Проверено этой ночью.',
  ];

  /// Добавить [count] ботов, не выходя за лимит стола.
  static GameState addBots(GameState state, int count) {
    if (count <= 0 || state.phase != GamePhase.waiting) return state;
    final players = List<Player>.from(state.players);
    final room = Rules.maxPlayers - players.length;
    final toAdd = count > room ? room : count;
    for (var i = 0; i < toAdd; i++) {
      players.add(_newBot(players));
    }
    return state.copyWith(players: players);
  }

  static Player _newBot(List<Player> players) {
    final usedNames = players
        .map((p) => p.name.trim().toLowerCase())
        .toSet();
    final base = names.firstWhere(
      (name) => !usedNames.contains(name.toLowerCase()),
      orElse: () => 'Бот ${players.length + 1}',
    );
    var name = base;
    var suffix = 2;
    while (usedNames.contains(name.toLowerCase())) {
      name = '$base $suffix';
      suffix++;
    }

    var index = 1;
    while (players.any((p) => p.id == 'bot-$index')) {
      index++;
    }

    final usedColors = players.map((p) => p.colorHex).toSet();
    var color = colorForSlot(players.length);
    if (usedColors.contains(color)) {
      color = kPlayerColors.firstWhere(
        (c) => !usedColors.contains(c),
        orElse: () => colorForSlot(players.length),
      );
    }

    return Player(
      id: 'bot-$index',
      name: name,
      colorHex: color,
      isConnected: true,
      isBot: true,
    );
  }

  /// Ночные ходы ботов, которые ещё не сходили.
  ///
  /// Возвращает только новые записи; уже принятые ходы людей не трогает.
  /// Решение без знания лечения/ходов противника. Не читает чужие роли.
  static List<String> piercingRequestsFor(GameState s,
      Map<String, String?> actions, Random random) => [
    for (final p in s.players)
      if (p.isBot && s.canRequestPiercing(p) && actions[p.id] != null &&
          random.nextInt(3) == 0) p.id,
  ];

  static Map<String, String?> nightActionsFor(GameState s, Random random) {
    final actions = <String, String?>{};
    for (final bot in s.pendingActors.where((p) => p.isBot)) {
      final targets = _nightTargetsFor(s, bot);
      if (targets.isEmpty) {
        actions[bot.id] = null; // осознанный пропуск
        continue;
      }

      Player target;
      switch (bot.role?.type) {
        case RoleType.commissioner:
          // Не проверяем одного и того же по кругу. Проверка донa
          // врёт, но бот об этом не знает — как и человек-комиссар.
          final successful = s.checksBy(bot.id).where((c) => !c.blocked);
          final checked = successful.map((c) => c.targetId).toSet();
          final fresh = targets.where((t) => !checked.contains(t.id)).toList();
          target = _pick(fresh.isEmpty ? targets : fresh, random);
          break;
        case RoleType.doctor:
          // Доктор не знает цель мафии и чужие проверки, поэтому
          // выбирает случайную допустимую цель — как человек без информации.
          target = _pick(targets, random);
          break;
        case RoleType.prostitute:
          target = _pick(targets, random);
          break;
        case RoleType.maniac:
          target = _pick(targets, random);
          break;
        case RoleType.bodyguard:
          // Телохранитель прикрывает того, кого бот-город считает своим:
          // прикрыть подозреваемого — значит отдать за него жизнь.
          target = _guardTarget(s, bot, targets, random);
          break;
        case RoleType.witness:
          // Наблюдать за уже проверенным смысла нет: факт про него уже
          // есть, и второй раз он ничего не добавит.
          final seen = s.watchTargetId;
          final fresh = targets.where((t) => t.id != seen).toList();
          target = _pick(fresh.isEmpty ? targets : fresh, random);
          break;
        case RoleType.hunter:
          // Охотник метит того, в кого верит меньше всех: если его
          // выгонят, он заберёт с собой самого подозрительного.
          target = _suspiciousTarget(s, bot, targets, random);
          break;
        case RoleType.blackmailer:
          // Шантажист молча лишает голоса, поэтому выбирает не случайного,
          // а того, кто громче всех ведёт стол: чем активнее игрок, тем
          // дороже его молчание.
          target = _suspiciousTarget(s, bot, targets, random);
          break;
        default:
          target = _pick(targets, random);
          break;
      }
      actions[bot.id] = target.id;
    }
    return actions;
  }

  /// Список целей ночного хода. Мафия выбирает из всех живых, кроме
  /// своей команды: если бы список строился по чужим ролям, боты читали
  /// расклад и их нельзя было бы назвать честными противниками.
  static List<Player> _nightTargetsFor(GameState s, Player bot) =>
      GameEngine.legalTargetsFor(s, bot);

  /// Голоса ботов в текущем туре. Может частично следовать уже открытым
  /// голосам, но не знает, кто как проголосовал тайно.
  static Map<String, String?> votesFor(GameState s, Random random) {
    final votes = <String, String?>{};
    var working = s;
    for (final bot in s.pendingVoters.where((p) => p.isBot)) {
      final targets = GameEngine.legalTargetsFor(working, bot);
      final ownMafia = bot.role?.side == Side.mafia;
      final foundMafia = _foundMafiaFor(s, bot);

      String? choice;
      if (s.isVerdictVote) {
        final accusedId = s.verdictId;
        if (accusedId == null) {
          choice = null;
        } else if (ownMafia && _isMafia(s, accusedId)) {
          choice = null; // своих не сдаём
        } else if (foundMafia.contains(accusedId)) {
          choice = accusedId;
        } else if (bot.role?.type == RoleType.commissioner &&
            _hasCleanCheck(s, bot, accusedId) &&
            random.nextDouble() < 0.75) {
          choice = null;
        } else {
          // Без доказательств боты чаще дают обвиняемому шанс, но
          // не обязаны делать это всегда: иначе последнее слово теряло смысл.
          choice = random.nextDouble() < 0.35 ? null : accusedId;
        }
      } else {
        final candidates = targets.map((p) => p.id).toList();
        if (candidates.isEmpty) {
          choice = null;
        } else if (ownMafia) {
          // «Свои» — вся мафия: шантажист тоже свой, и голосовать
          // против него бот-мафия не станет.
          final teammates = s.mafiaSiders.map((p) => p.id).toSet();
          final town = candidates.where((id) => !teammates.contains(id)).toList();
          choice = town.isEmpty ? null : _pick(town, random);
        } else {
          var pool = candidates.toList();
          final knownMafia = pool.where(foundMafia.contains).toList();
          if (bot.role?.type == RoleType.commissioner) {
            final clean = pool.where((id) => _hasCleanCheck(s, bot, id)).toList();
            if (clean.isNotEmpty && random.nextDouble() < 0.8) {
              pool = pool.where((id) => !clean.contains(id)).toList();
            }
          }
          if (knownMafia.isNotEmpty) {
            // Найденная комиссаром мафия — не повод воздержаться.
            choice = _pick(knownMafia, random);
          } else if (pool.isEmpty || random.nextDouble() < 0.12) {
            choice = null; // воздержаться
          } else {
            final leader = _voteLeader(working, pool);
            choice = leader != null && random.nextDouble() < 0.35
                ? leader
                : _pick(pool, random);
          }
        }
      }
      votes[bot.id] = choice;
      working = working.copyWith(votes: {...working.votes, bot.id: choice});
    }
    return votes;
  }

  /// Реплики дня. Максимум четыре, чтобы одиночная партия не превращалась
  /// в простыню текста; комиссар раскрывается только при найденной мафии.
  ///
  /// Порядок и приоритет (1.13.0):
  ///   1. комиссар называет найденную мафию — это факт, он важнее всего;
  ///   2. обвиняемый отвечает на обвинение;
  ///   3. тот, у кого есть чистая проверка обвиняемого, вступается;
  ///   4. остальные — обвинение или общий разговор.
  static List<BotSpeech> dayLinesFor(GameState s, Random random) {
    final bots = s.alive.where((p) => p.isBot).toList()..shuffle(random);
    final lines = <BotSpeech>[];

    for (final bot in bots) {
      if (bot.role?.type != RoleType.commissioner) continue;
      final check = s.checksBy(bot.id).where((c) => c.round == s.round).toList();
      if (check.isEmpty) continue;
      final found = check.first;
      final target = s.byId(found.targetId);
      if (found.isMafia && !found.blocked && target != null && target.isAlive) {
        lines.add(BotSpeech(
          playerId: bot.id,
          text: _foundMafia[random.nextInt(_foundMafia.length)]
              .replaceAll('{x}', target.name),
        ));
        break;
      }
    }

    // Кого город обвиняет прямо сейчас: лидер вчерашнего голосования.
    final accusedId = _voteLeader(s, s.alive.map((p) => p.id).toList());

    // 1) Обвиняемый бот отвечает на обвинение — один раз, первым.
    if (accusedId != null) {
      final accused = s.byId(accusedId);
      if (accused != null && accused.isBot && accused.isAlive) {
        lines.add(BotSpeech(
          playerId: accused.id,
          text: _selfDefense[random.nextInt(_selfDefense.length)],
        ));
      }
    }

    // 2) Бот-комиссар (и любой, у кого есть чистая проверка) защищает
    //    того, кого обвиняют, если проверка его оправдывает.
    //
    //    Защищённого больше не обвиняют остальные: вслух сказанное «он
    //    чистый» стол слышит. Иначе выходило нелепо — один бот заявляет,
    //    что игрок проверен как мирный, а следующий тут же его выгоняет.
    final protectedIds = <String>{};
    if (accusedId != null) {
      for (final bot in bots) {
        if (lines.any((l) => l.playerId == bot.id)) continue;
        if (!_hasCleanCheck(s, bot, accusedId)) continue;
        lines.add(BotSpeech(
          playerId: bot.id,
          text: _defend[random.nextInt(_defend.length)]
              .replaceAll('{x}', s.nameOf(accusedId)),
        ));
        protectedIds.add(accusedId);
        break;
      }
    }

    for (final bot in bots) {
      if (lines.length >= 4) break;
      if (lines.any((line) => line.playerId == bot.id)) continue;
      if (lines.isNotEmpty && random.nextDouble() < 0.45) continue;

      final ownMafia = bot.role?.side == Side.mafia;
      if (ownMafia) {
        final teammates = s.mafiaSiders.map((p) => p.id).toSet();
        final targets = s.alive
            .where((p) => p.id != bot.id && !teammates.contains(p.id))
            .toList();
        if (targets.isNotEmpty) {
          final target = _pick(targets, random);
          lines.add(BotSpeech(
            playerId: bot.id,
            text: _suspect[random.nextInt(_suspect.length)]
                .replaceAll('{x}', target.name),
          ));
          continue;
        }
      }
      // Город не обвиняет того, кого сам проверил чистым: за столом
      // это выглядело бы как «бот не слушает собственные улики».
      final cleanPool = s.alive
          .where((p) =>
              p.id != bot.id &&
              !protectedIds.contains(p.id) &&
              !_hasCleanCheck(s, bot, p.id))
          .toList();
      if (cleanPool.isNotEmpty && random.nextDouble() < 0.55) {
        final target = _pick(cleanPool, random);
        lines.add(BotSpeech(
          playerId: bot.id,
          text: _suspect[random.nextInt(_suspect.length)]
              .replaceAll('{x}', target.name),
        ));
        continue;
      }
      lines.add(BotSpeech(
        playerId: bot.id,
        text: _chatter[random.nextInt(_chatter.length)],
      ));
    }
    return lines;
  }

  /// Кого прикрыть телохранителю-боту.
  ///
  /// Правило простое и честное: прикрываем того, кого считаем своим.
  /// Улики те же, что у живого игрока, — свои проверки комиссара, голоса
  /// прошлого дня и собственное мнение о команде.
  ///
  /// ВАЖНО: настоящую роль цели бот не читает — иначе он играл бы не
  /// хуже читера. Первая версия этой функции искала в целях живого
  /// комиссара по `role.type`, то есть подглядывала; от этого отказались.
  static Player _guardTarget(
    GameState s,
    Player bot,
    List<Player> targets,
    Random random,
  ) {
    // Кого город уже публично защищал вчера — того и прикрываем: это
    // наблюдаемая улика, а не служебная информация.
    final defended = _defendedTarget(s, targets);
    if (defended != null) return defended;
    return _trustedTarget(s, bot, targets, random);
  }

  /// Кого вчерашнее голосование почти выгнало (лидер по голосам среди
  /// живых целей): значит, за него вступались.
  static Player? _defendedTarget(GameState s, List<Player> targets) {
    final allowed = targets.map((t) => t.id).toList();
    final leader = _voteLeader(s, allowed);
    if (leader == null) return null;
    for (final t in targets) {
      if (t.id == leader) return t;
    }
    return null;
  }

  /// Самый «свой» из списка: сначала проверенные чистые, потом остальные.
  static Player _trustedTarget(
    GameState s,
    Player bot,
    List<Player> targets,
    Random random,
  ) {
    final clean = targets
        .where((t) => _hasCleanCheck(s, bot, t.id))
        .toList();
    if (clean.isNotEmpty) return _pick(clean, random);
    return _pick(targets, random);
  }

  /// Самый подозрительный из списка: сначала найденная мафия, потом
  /// тот, за кем город уже голосовал, иначе — случайный.
  static Player _suspiciousTarget(
    GameState s,
    Player bot,
    List<Player> targets,
    Random random,
  ) {
    final found = _foundMafiaFor(s, bot);
    if (found.isNotEmpty) {
      final known = targets.where((t) => found.contains(t.id)).toList();
      if (known.isNotEmpty) return _pick(known, random);
    }
    final leader = _voteLeader(s, targets.map((t) => t.id).toList());
    if (leader != null) {
      final byId = targets.where((t) => t.id == leader).toList();
      if (byId.isNotEmpty) return byId.first;
    }
    return _pick(targets, random);
  }

  static Set<String> _foundMafiaFor(GameState s, Player bot) {
    if (bot.role?.type != RoleType.commissioner) return const {};
    return s.checksBy(bot.id)
        .where((c) => c.isMafia && !c.blocked)
        .map((c) => c.targetId)
        .toSet();
  }

  static bool _hasCleanCheck(GameState s, Player bot, String targetId) =>
      bot.role?.type == RoleType.commissioner &&
      s.checksBy(bot.id).any((c) =>
          c.targetId == targetId && !c.isMafia && !c.blocked);

  static bool _isMafia(GameState s, String id) =>
      s.byId(id)?.role?.side == Side.mafia;

  static String? _voteLeader(GameState s, List<String> allowed) {
    final tally = <String, int>{};
    for (final target in s.votes.values) {
      if (target != null && allowed.contains(target)) {
        tally[target] = (tally[target] ?? 0) + 1;
      }
    }
    if (tally.isEmpty) return null;
    final max = tally.values.reduce((a, b) => a > b ? a : b);
    final leaders = tally.entries
        .where((e) => e.value == max)
        .map((e) => e.key)
        .toList();
    return leaders.length == 1 ? leaders.first : null;
  }

  static T _pick<T>(List<T> values, Random random) =>
      values[random.nextInt(values.length)];
}
