/// Единственное объявление фазы игры на весь проект.
/// (В черновом прототипе enum дублировался в двух файлах — это было
/// источником ошибок сериализации.)
library;

enum GamePhase { waiting, night, day, voting, ended }

extension GamePhaseX on GamePhase {
  String get wire => name;

  String get title {
    switch (this) {
      case GamePhase.waiting:
        return 'Ожидание';
      case GamePhase.night:
        return 'Ночь';
      case GamePhase.day:
        return 'День';
      case GamePhase.voting:
        return 'Голосование';
      case GamePhase.ended:
        return 'Игра окончена';
    }
  }

  static GamePhase parse(String? value) {
    return GamePhase.values.firstWhere(
      (e) => e.name == value,
      orElse: () => GamePhase.waiting,
    );
  }
}
