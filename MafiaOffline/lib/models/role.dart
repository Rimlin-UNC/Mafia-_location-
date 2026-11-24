/// Роли и их способности.
library;

enum RoleType {
  mafia,
  don,
  doctor,
  commissioner,
  prostitute,
  maniac,
  civilian,

  // ---- 1.12.0: четыре роли, которые меняют тактику стола ----
  //
  // Все четыре намеренно сделаны из примитивов, которые движок уже умеет
  // разрешать (убийство, лечение, блокировка, проверка). Новых «фаз» и
  // «подфаз» они не создают: партия остаётся такой же предсказуемой,
  // какой была до них.

  /// Городской телохранитель: прикрывает игрока собой.
  bodyguard,

  /// Городской свидетель: узнаёт, выходил ли игрок ночью из дома.
  witness,

  /// Городской охотник: перед смертью забирает выбранного с собой.
  hunter,

  /// Мафия: лишает игрока голоса на один день.
  blackmailer,
}

/// Сторона, за которую играет роль.
///
/// Мирные жители — все, кроме мафии и дона: доктор, комиссар, проститутка,
/// маньяк и обычные горожане. У каждого свои ночные способности, но цель
/// общая — вычислить и выгнать мафию. Днём голосуют наравне со всеми.
///
/// [Side.solo] — сторона маньяка: он ни с мафией, ни с городом и
/// побеждает только оставшись один (классическое правило, v1.1.0).
/// До 1.1.0 маньяк числился за городом — старые записи истории читаются
/// по сохранённой в них роли, поэтому значение не удалять.
enum Side { mafia, civilians, solo }

class Role {
  final RoleType type;
  final String name;
  final String emoji;
  final String description;
  final Side side;
  final bool isActiveAtNight;
  final bool canKill;
  final bool canHeal;
  final bool canCheck;
  final bool canBlock;

  /// Порядок применения ночного действия (см. алгоритм разрешения ночи).
  final int nightOrder;

  const Role({
    required this.type,
    required this.name,
    required this.emoji,
    required this.description,
    required this.side,
    this.isActiveAtNight = false,
    this.canKill = false,
    this.canHeal = false,
    this.canCheck = false,
    this.canBlock = false,
    this.nightOrder = 99,
  });

  static const Role mafia = Role(
    type: RoleType.mafia,
    name: 'Мафия',
    emoji: '🔫',
    description: 'Каждую ночь вместе с командой выбирает жертву. '
        'При расхождении решает голос дона.',
    side: Side.mafia,
    isActiveAtNight: true,
    canKill: true,
    nightOrder: 3,
  );

  static const Role don = Role(
    type: RoleType.don,
    name: 'Дон',
    emoji: '🎩',
    description: 'Глава мафии. Его голос решающий при выборе жертвы. '
        'Комиссар видит дона как мирного жителя.',
    side: Side.mafia,
    isActiveAtNight: true,
    canKill: true,
    nightOrder: 3,
  );

  static const Role doctor = Role(
    type: RoleType.doctor,
    name: 'Доктор',
    emoji: '💉',
    description: 'Каждую ночь спасает одного игрока. '
        'Нельзя лечить одного и того же две ночи подряд.',
    side: Side.civilians,
    isActiveAtNight: true,
    canHeal: true,
    nightOrder: 2,
  );

  static const Role commissioner = Role(
    type: RoleType.commissioner,
    name: 'Комиссар',
    emoji: '🔎',
    description: 'Каждую ночь проверяет одного игрока на принадлежность '
        'к мафии. Дон выглядит как мирный.',
    side: Side.civilians,
    isActiveAtNight: true,
    canCheck: true,
    nightOrder: 5,
  );

  static const Role prostitute = Role(
    type: RoleType.prostitute,
    name: 'Проститутка',
    emoji: '💋',
    description: 'Блокирует одного игрока — тот пропускает свой ночной ход.',
    side: Side.civilians,
    isActiveAtNight: true,
    canBlock: true,
    nightOrder: 1,
  );

  static const Role bodyguard = Role(
    type: RoleType.bodyguard,
    name: 'Телохранитель',
    emoji: '🛡',
    description: 'Каждую ночь прикрывает одного игрока собой. '
        'Если этой ночью его попытаются убить, погибнете вы, а он выживет. '
        'Себя прикрывать нельзя, одного и того же — две ночи подряд.',
    side: Side.civilians,
    isActiveAtNight: true,
    nightOrder: 2,
  );

  static const Role witness = Role(
    type: RoleType.witness,
    name: 'Свидетель',
    emoji: '👁',
    description: 'Каждую ночь наблюдает за одним игроком и утром узнаёт, '
        'выходил ли тот из дома. Кто ночью не спал — тот не мирный житель, '
        'но и не обязательно мафия.',
    side: Side.civilians,
    isActiveAtNight: true,
    nightOrder: 5,
  );

  static const Role hunter = Role(
    type: RoleType.hunter,
    name: 'Охотник',
    emoji: '🎯',
    description: 'Перед каждой ночью выбирает, кого заберёт с собой. '
        'Если охотника убьют или выгонят голосованием, выбранный погибает '
        'вместе с ним.',
    side: Side.civilians,
    isActiveAtNight: true,
    nightOrder: 5,
  );

  static const Role blackmailer = Role(
    type: RoleType.blackmailer,
    name: 'Шантажист',
    emoji: '🕶',
    description: 'Мафия. Каждую ночь запугивает одного горожанина: '
        'на следующий день тот не голосует. Убивать не умеет — только '
        'пугать, зато его жертва молчит в самый нужный момент.',
    side: Side.mafia,
    isActiveAtNight: true,
    // Намеренно НЕ canBlock: шантажист не отменяет ночной ход, он лишает
    // голоса днём. Флаг читают экраны как «блокирует чужой ход», и врать
    // им нельзя.
    nightOrder: 1,
  );

  static const Role maniac = Role(
    type: RoleType.maniac,
    name: 'Маньяк',
    emoji: '🔪',
    description: 'Одиночка. Каждую ночь убивает одного игрока и хочет '
        'остаться последним. Побеждает, только когда в живых не осталось '
        'никого, кроме него.',
    side: Side.solo,
    isActiveAtNight: true,
    canKill: true,
    nightOrder: 4,
  );

  static const Role civilian = Role(
    type: RoleType.civilian,
    name: 'Мирный житель',
    emoji: '👤',
    description: 'Ночью спит. Днём обсуждает и голосует, пытаясь найти мафию.',
    side: Side.civilians,
  );

  static Role fromType(RoleType type) {
    switch (type) {
      case RoleType.mafia:
        return mafia;
      case RoleType.don:
        return don;
      case RoleType.doctor:
        return doctor;
      case RoleType.commissioner:
        return commissioner;
      case RoleType.prostitute:
        return prostitute;
      case RoleType.maniac:
        return maniac;
      case RoleType.civilian:
        return civilian;
      case RoleType.bodyguard:
        return bodyguard;
      case RoleType.witness:
        return witness;
      case RoleType.hunter:
        return hunter;
      case RoleType.blackmailer:
        return blackmailer;
    }
  }

  /// Русское название типа роли по «проволочному» имени (`RoleType.name`).
  ///
  /// Единственный словарь для всего приложения. Раньше такие таблицы жили
  /// отдельно в протоколе партии и в веб-клиенте, а любой новый экран
  /// печатал тип как есть — именно так в истории партий появилось
  /// «civilian» и «hunter» вместо «Мирный житель» и «Охотник».
  ///
  /// Неизвестное имя возвращаем как есть, но не пустым: в истории,
  /// сохранённой старой версией, может лежать что угодно.
  static String nameRuFor(String? wire) {
    for (final t in RoleType.values) {
      if (t.name == wire) return fromType(t).name;
    }
    return wire ?? '';
  }

  /// Русское название по ссылке на тип (для экранов, где тип уже есть).
  static String nameRu(RoleType? type) =>
      type == null ? '' : fromType(type).name;

  static Role? tryParse(String? wire) {
    if (wire == null) return null;
    for (final t in RoleType.values) {
      if (t.name == wire) return fromType(t);
    }
    return null;
  }

  /// Роли, доступные для настройки состава (мирные считаются автоматически).
  static const List<RoleType> configurable = [
    RoleType.mafia,
    RoleType.don,
    RoleType.blackmailer,
    RoleType.doctor,
    RoleType.commissioner,
    RoleType.bodyguard,
    RoleType.prostitute,
    RoleType.witness,
    RoleType.hunter,
    RoleType.maniac,
  ];

  /// Есть ли у роли ночной ход, кроме убийства. Нужно подсказкам ведущего
  /// и памяти ботов: «ходит, но не стреляет» — это другой класс роли.
  bool get isUtility => isActiveAtNight && !canKill;
}
