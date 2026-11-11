/// Роли и их способности.
library;

enum RoleType { mafia, don, doctor, commissioner, prostitute, maniac, civilian }

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
    }
  }

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
    RoleType.doctor,
    RoleType.commissioner,
    RoleType.prostitute,
    RoleType.maniac,
  ];
}
