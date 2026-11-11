import '../models/game_state.dart';
import '../models/game_phase.dart';
import '../models/player.dart';
import '../models/role.dart';

/// Сюжетная карточка: кадр, который ведущий показывает за столом в
/// определённый момент партии.
///
/// Зачем это нужно. У ведущего есть текст и таймер, но нет «картинки
/// момента»: когда город впервые теряет человека, или когда голосование
/// второй раз подряд заканчивается ничем, за столом повисает пауза.
/// Карточка заполняет эту паузу одним кадром и одной фразой.
///
/// Важно: карточка **не раскрывает информацию** и не влияет на правила.
/// Она показывается всем одинаково и говорит только о том, что и так
/// известно: «в городе первая смерть», «голосование сорвалось».
class StoryCard {
  /// Устойчивый идентификатор: попадает в состояние, историю и тесты.
  final String id;

  final String title;

  /// Что прочитать вслух. Одна-две фразы, не больше: это реплика, а не лекция.
  final String line;

  /// Подпись мелким шрифтом под картинкой.
  final String caption;

  /// Когда показывать.
  final StoryTrigger trigger;

  /// Чем больше, тем важнее. Если подходят две карточки сразу,
  /// показывается одна — с большим приоритетом.
  final int priority;

  final String? image;

  const StoryCard({
    required this.id,
    required this.title,
    required this.line,
    required this.caption,
    required this.trigger,
    required this.priority,
    this.image,
  });
}

/// Условия показа. Проверяются по состоянию партии — без побочных эффектов,
/// чтобы решение можно было покрыть тестом.
enum StoryTrigger {
  /// Первая ночь, ещё никто не погиб.
  firstNight,

  /// Первый погибший в партии.
  firstBlood,

  /// Второй тур голосования: город раскололся, но не решил.
  runoff,

  /// Два голосования подряд закончились ничем — город не может решить.
  deadlock,

  /// Осталось трое живых: финальная развилка.
  lastThree,

  /// В живых остался только маньяк и один горожанин.
  maniacAlone,

  /// Мафии осталось столько же, сколько горожан: город на грани.
  mafiaSurge,

  /// Город выгнал игрока голосованием (любой, кроме первого).
  exile,

  /// Ночь без жертв: доктор или проститутка сработали.
  quietNight,
}

/// Колода. Порядок важен только для тестов: показ идёт по приоритету.
class StoryDeck {
  static const List<StoryCard> all = [
    StoryCard(
      id: 'first_night',
      title: 'Город засыпает',
      line: 'Первая ночь. Город ещё не знает, кого ему бояться.',
      caption: 'Покажите карточку перед раздачей ролей.',
      trigger: StoryTrigger.firstNight,
      priority: 10,
      image: 'assets/story/01_first_night.jpg',
    ),
    StoryCard(
      id: 'first_blood',
      title: 'Первая кровь',
      line: 'Этой ночью город потерял первого. Дальше будет тише — '
          'и от этого страшнее.',
      caption: 'Первый погибший в партии.',
      trigger: StoryTrigger.firstBlood,
      priority: 90,
      image: 'assets/story/02_first_blood.jpg',
    ),
    StoryCard(
      id: 'runoff',
      title: 'Город раскололся',
      line: 'Голоса разделились. Решать придётся ещё раз — '
          'и уже без права на ошибку.',
      caption: 'Второй тур голосования.',
      trigger: StoryTrigger.runoff,
      priority: 60,
      image: 'assets/story/07_runoff.jpg',
    ),
    StoryCard(
      id: 'deadlock',
      title: 'Город не может решить',
      line: 'Дважды не смогли договориться. Тот, кто молчит громче всех, '
          'обычно и есть мафия.',
      caption: 'Два голосования подряд закончились ничем.',
      trigger: StoryTrigger.deadlock,
      priority: 70,
      image: 'assets/story/03_tie.jpg',
    ),
    StoryCard(
      id: 'last_three',
      title: 'Трое',
      line: 'В городе осталось трое. Один из них врёт прямо сейчас.',
      caption: 'Трое живых игроков.',
      trigger: StoryTrigger.lastThree,
      priority: 95,
      image: 'assets/story/05_survivors.jpg',
    ),
    StoryCard(
      id: 'maniac_alone',
      title: 'Одиночка',
      line: 'Мафии больше нет. Но город не победил: в нём остался тот, '
          'кто убивал для себя.',
      caption: 'Мафия выбита, маньяк ещё жив.',
      trigger: StoryTrigger.maniacAlone,
      priority: 100,
      image: 'assets/story/06_maniac.jpg',
    ),
    StoryCard(
      id: 'mafia_surge',
      title: 'Мафия сравнялась',
      line: 'Тех и других поровну. Город больше не может выгнать мафию '
          'голосованием.',
      caption: 'Мафии столько же, сколько горожан.',
      trigger: StoryTrigger.mafiaSurge,
      priority: 85,
      image: 'assets/story/04_dead_end.jpg',
    ),
    StoryCard(
      id: 'exile',
      title: 'Изгнание',
      line: 'Город решил. Приговор приводится в исполнение сразу: '
          'за ворота, в туман, без возврата.',
      caption: 'Игрок выбыл голосованием.',
      trigger: StoryTrigger.exile,
      priority: 40,
      image: 'assets/court/03_exile.jpg',
    ),
    StoryCard(
      id: 'quiet_night',
      title: 'Тихая ночь',
      line: 'Этой ночью никто не погиб. Значит, кто-то успел '
          'вмешаться — и он знает о городе больше, чем говорит.',
      caption: 'Ночь прошла без жертв.',
      trigger: StoryTrigger.quietNight,
      priority: 50,
      image: 'assets/story/08_quiet_night.jpg',
    ),
  ];

  /// Карточки, привязанные к суду (голосованию).
  static const List<String> courtIds = ['runoff', 'deadlock', 'exile'];

  static StoryCard? byId(String? id) {
    if (id == null) return null;
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }

  static List<StoryCard> of(StoryTrigger trigger) =>
      all.where((c) => c.trigger == trigger).toList();

  /// Какие карточки уместны в текущем состоянии.
  ///
  /// [seenIds] — уже показанные в этой партии: одну и ту же карточку
  /// дважды не показываем, иначе приём превращается в назойливость.
  /// [noDeathsStreak] — сколько голосований подряд закончилось ничем.
  ///
  /// [quietNight] и [exile] — события, которых не видно по состоянию:
  /// «этой ночью никто не погиб» и «только что выгнали голосованием».
  /// Их сообщает вызывающий. До 1.2.0 эти две карточки были в колоде,
  /// но условия для них никто не проверял — сами они не показывались.
  static List<StoryCard> candidatesFor(
    GameState s, {
    Set<String> seenIds = const {},
    int noDeathsStreak = 0,
    bool quietNight = false,
    bool exile = false,
  }) {
    final alive = s.alive;
    final out = <StoryCard>[];

    void add(StoryTrigger t) {
      for (final c in of(t)) {
        if (!seenIds.contains(c.id)) out.add(c);
      }
    }

    // Первая ночь: ещё никто не выбыл и раунд только начинается.
    if (s.round <= 1 && s.dead.isEmpty && s.phase == GamePhase.night) {
      add(StoryTrigger.firstNight);
    }

    // «Первая кровь» — про ночное убийство («этой ночью город потерял
    // первого»). Если первым выбыл изгнанный голосованием, карточка уже
    // не к месту: с ночью знакомства это обычный ход партии, и до 1.2.0
    // после первого же голосования читали бы текст про ночь.
    final someoneExiled =
        s.dead.any((p) => p.eliminationReason == EliminationReason.voted);
    if (s.dead.isNotEmpty && !exile && !someoneExiled) {
      add(StoryTrigger.firstBlood);
    }
    if (alive.length == 3) add(StoryTrigger.lastThree);
    if (s.runoffCandidates.isNotEmpty) add(StoryTrigger.runoff);
    if (noDeathsStreak >= 2) add(StoryTrigger.deadlock);

    final mafiaAlive = alive
        .where((p) => p.role?.side == Side.mafia)
        .length;
    final maniacAlive =
        alive.where((p) => p.role?.type == RoleType.maniac).length;
    final civilians = alive.length - mafiaAlive - maniacAlive;

    if (mafiaAlive == 0 && maniacAlive > 0 && alive.length > 1) {
      add(StoryTrigger.maniacAlone);
    }
    if (mafiaAlive > 0 && mafiaAlive == civilians) add(StoryTrigger.mafiaSurge);

    if (quietNight) add(StoryTrigger.quietNight);
    if (exile) add(StoryTrigger.exile);

    out.sort((a, b) => b.priority.compareTo(a.priority));
    return out;
  }

  /// Одна карточка для показа: самая приоритетная из подходящих.
  static StoryCard? bestFor(
    GameState s, {
    Set<String> seenIds = const {},
    int noDeathsStreak = 0,
    bool quietNight = false,
    bool exile = false,
  }) {
    final list = candidatesFor(
      s,
      seenIds: seenIds,
      noDeathsStreak: noDeathsStreak,
      quietNight: quietNight,
      exile: exile,
    );
    return list.isEmpty ? null : list.first;
  }
}
