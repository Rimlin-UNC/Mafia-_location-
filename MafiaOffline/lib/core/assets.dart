import '../models/role.dart';

/// Пути к ассетам в одном месте — чтобы опечатка не всплывала в рантайме.
class A {
  // ---------- звуки: события фаз ----------
  static const nightFalls = 'sounds/night_falls.ogg';
  static const dayBreaks = 'sounds/day_breaks.ogg';
  static const rolesDealt = 'sounds/roles_dealt.ogg';
  static const voteStart = 'sounds/vote_start.ogg';

  // ---------- звуки: драматические моменты ----------
  static const kill = 'sounds/kill.ogg';
  static const heal = 'sounds/heal.ogg';
  static const check = 'sounds/check.ogg';
  static const block = 'sounds/block.ogg';
  static const eliminated = 'sounds/eliminated.ogg';
  static const noDeaths = 'sounds/no_deaths.ogg';

  // ---------- звуки: исходы ----------
  static const winMafia = 'sounds/win_mafia.ogg';
  static const winCivilians = 'sounds/win_civilians.ogg';
  static const winManiac = 'sounds/win_maniac.ogg';

  // ---------- звуки: интерфейс ----------
  static const revealCard = 'sounds/reveal_card.ogg';
  static const hideCard = 'sounds/hide_card.ogg';
  static const tap = 'sounds/tap.ogg';
  static const playerJoined = 'sounds/player_joined.ogg';

  // ---------- фоновые лупы ----------
  static const ambNight = 'sounds/night_ambient.wav';
  static const ambDay = 'sounds/day_ambient.wav';
  static const ambVote = 'sounds/vote_ambient.wav';

  // ---------- изображения ----------
  static const bgNight = 'assets/images/bg_night.jpg';
  static const bgDay = 'assets/images/bg_day.jpg';
  static const bgVote = 'assets/images/bg_vote.jpg';
  static const shield = 'assets/images/hide_shield.png';
  static const cardBack = 'assets/cards/card_back.jpg';

  /// Карточка роли. Ключевая деталь: дон показывается картинкой мафии,
  /// чтобы случайный взгляд соседа не выдал главаря.
  static String card(RoleType type) {
    switch (type) {
      case RoleType.mafia:
        return 'assets/cards/mafia.jpg';
      case RoleType.don:
        return 'assets/cards/don.jpg';
      case RoleType.doctor:
        return 'assets/cards/doctor.jpg';
      case RoleType.commissioner:
        return 'assets/cards/commissioner.jpg';
      case RoleType.prostitute:
        return 'assets/cards/prostitute.jpg';
      case RoleType.maniac:
        return 'assets/cards/maniac.jpg';
      case RoleType.civilian:
        return 'assets/cards/civilian.jpg';
    }
  }

  /// Карта-обманка. Если игрок включил маскировку, экран показывает
  /// мирного жителя — как бы кто ни подсмотрел.
  static const decoyCard = 'assets/cards/civilian.jpg';
}
