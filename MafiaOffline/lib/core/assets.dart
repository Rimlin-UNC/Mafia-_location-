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
      case RoleType.bodyguard:
        return 'assets/cards/bodyguard.jpg';
      case RoleType.witness:
        return 'assets/cards/witness.jpg';
      case RoleType.hunter:
        return 'assets/cards/hunter.jpg';
      case RoleType.blackmailer:
        return 'assets/cards/blackmailer.jpg';
    }
  }

  /// Карта-обманка. Если игрок включил маскировку, экран показывает
  /// мирного жителя — как бы кто ни подсмотрел.
  static const decoyCard = 'assets/cards/civilian.jpg';

  // ---------- карточки-инструкции (экран «Правила») ----------
  //
  // Отдельный набор от игровых карт: здесь крупные иллюстрации с подписями,
  // их можно листать и читать до партии. Лежат в assets/instructions/.

  /// Карточка роли для раздела «Роли».
  static String guideRole(RoleType type) {
    switch (type) {
      case RoleType.mafia:
        return 'assets/instructions/roles/01_mafia.jpg';
      case RoleType.don:
        return 'assets/instructions/roles/02_don.jpg';
      case RoleType.doctor:
        return 'assets/instructions/roles/03_doctor.jpg';
      case RoleType.commissioner:
        return 'assets/instructions/roles/04_commissioner.jpg';
      case RoleType.prostitute:
        return 'assets/instructions/roles/05_prostitute.jpg';
      case RoleType.maniac:
        return 'assets/instructions/roles/06_maniac.jpg';
      case RoleType.civilian:
        return 'assets/instructions/roles/07_civilian.jpg';
      case RoleType.bodyguard:
        return 'assets/instructions/roles/08_bodyguard.jpg';
      case RoleType.witness:
        return 'assets/instructions/roles/09_witness.jpg';
      case RoleType.hunter:
        return 'assets/instructions/roles/10_hunter.jpg';
      case RoleType.blackmailer:
        return 'assets/instructions/roles/11_blackmailer.jpg';
    }
  }

  static const guideHost = 'assets/instructions/guides/01_host.jpg';
  static const guideNight = 'assets/instructions/phases/01_night.jpg';
  static const guideDay = 'assets/instructions/phases/02_day.jpg';
  static const guideVote = 'assets/instructions/phases/03_vote.jpg';
  static const guideWin = 'assets/instructions/phases/04_win.jpg';
}
