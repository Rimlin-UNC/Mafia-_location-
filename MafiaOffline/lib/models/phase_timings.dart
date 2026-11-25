import '../core/constants.dart';

/// Ноль означает прежний автоматический расчёт; последнее слово — 30 с.
/// Проверка выполняется и для данных с диска, и для прямого вызова API.
class PhaseTimings {
  final int _night, _day, _voting, _runoff, _lastWord;
  const PhaseTimings({int night = 0, int day = 0, int voting = 0,
    int runoff = 0, int lastWord = Rules.lastWordSeconds})
      : _night = night, _day = day, _voting = voting,
        _runoff = runoff, _lastWord = lastWord;

  static const keys = ['night', 'day', 'voting', 'runoff', 'lastWord'];
  static int maxFor(String key) => key == 'lastWord' ? 300 : 1800;
  static int _valid(int value, String key) =>
      value >= 10 && value <= maxFor(key)
          ? value : key == 'lastWord' ? Rules.lastWordSeconds : 0;
  int get night => _valid(_night, 'night');
  int get day => _valid(_day, 'day');
  int get voting => _valid(_voting, 'voting');
  int get runoff => _valid(_runoff, 'runoff');
  int get lastWord => _valid(_lastWord, 'lastWord');

  Map<String, int> toJson() => {'night': night, 'day': day,
    'voting': voting, 'runoff': runoff, 'lastWord': lastWord};

  factory PhaseTimings.fromJson(Object? raw) {
    final m = raw is Map ? raw : const {};
    int read(String key) => m[key] is int ? m[key] as int : 0;
    return PhaseTimings(night: read('night'), day: read('day'),
      voting: read('voting'), runoff: read('runoff'), lastWord: read('lastWord'));
  }

  PhaseTimings withSeconds(String key, int seconds) =>
      PhaseTimings.fromJson({...toJson(), key: seconds});
}
