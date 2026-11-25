import '../models/game_event.dart';
import '../models/game_phase.dart';
import '../models/role.dart';

/// Протокол партии в виде текста (FR-7.7).
///
/// Почему отдельным файлом и без Flutter: это чистая функция «данные → текст».
/// Её можно покрыть тестом без базы и без виджетов, а значит — она не сломается
/// незаметно при следующей правке экрана истории.
///
/// Формат рассчитан на чтение человеком в мессенджере: короткие строки,
/// без markdown-таблиц, которые в WhatsApp превращаются в кашу.
class ProtocolExport {
  /// Заголовок + состав + хронология.
  static String build({
    required String name,
    required DateTime createdAt,
    required int rounds,
    required String winnerTitle,
    required List<Map<String, dynamic>> players,
    required List<GameEvent> log,
    bool includeHidden = true,
  }) {
    final b = StringBuffer();
    b.writeln('🎭 ${name.trim().isEmpty ? 'Мафия' : name.trim()}');
    b.writeln('Дата: ${_date(createdAt)} · раундов: $rounds');
    b.writeln('Итог: $winnerTitle');
    b.writeln();

    if (players.isNotEmpty) {
      b.writeln('Расклад:');
      for (final p in players) {
        // Пометки важны в протоколе не меньше, чем на экране: по тексту
        // в чате должно быть видно, что партия шла с ботами и что
        // ведущий тоже играл — иначе «Мирный житель» у ведущего читается
        // как ошибка раздачи.
        final marks = <String>[
          if (p['isLocal'] == true) 'ведущий',
          if (p['isBot'] == true) 'бот',
        ];
        final rawName = (p['name'] ?? '—').toString();
        final pname = marks.isEmpty ? rawName : '$rawName (${marks.join(', ')})';
        final role = (p['role'] ?? '').toString();
        final alive = p['isAlive'] as bool? ?? true;
        final mark = alive ? 'выжил' : 'выбыл';
        final roleText = role.isEmpty ? 'роль неизвестна' : _roleRu(role);
        b.writeln('• $pname — $roleText ($mark)');
      }
      b.writeln();
    }

    if (log.isNotEmpty) {
      b.writeln('Хронология:');
      var lastRound = -1;
      var lastPhase = '';
      for (final e in log) {
        // Скрытые от игроков события (проверка комиссара, лечение) —
        // только для ведущего. Он и так знает роли, но протокол может
        // уйти в общий чат, поэтому по умолчанию их тоже печатаем,
        // с явной пометкой.
        if (!e.visibleToPlayers && !includeHidden) continue;
        if (e.round != lastRound || e.phase.name != lastPhase) {
          lastRound = e.round;
          lastPhase = e.phase.name;
          if (b.isNotEmpty) b.writeln();
          b.writeln(_phaseHeader(e.round, e.phase));
        }
        final prefix = e.visibleToPlayers ? '' : '🔒 ';
        b.writeln('  $prefix${e.text}');
      }
    }

    if (log.isEmpty && players.isEmpty) {
      b.writeln('Протокол пуст: в партии не было событий.');
    }

    b.writeln();
    b.writeln('— Мафия Offline, офлайн-игра по локальной сети');
    return b.toString().trimRight();
  }

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.'
      '${d.month.toString().padLeft(2, '0')}.${d.year}';

  static String _phaseHeader(int round, GamePhase phase) {
    switch (phase) {
      case GamePhase.rolesCheck:
        return '── Раздача ролей ──';
      case GamePhase.night:
        return '── Ночь $round ──';
      case GamePhase.day:
        return '── День $round ──';
      case GamePhase.voting:
        return '── Голосование $round ──';
      case GamePhase.ended:
        return '── Итог ──';
      case GamePhase.waiting:
        return '── Лобби ──';
    }
  }

  /// Имя роли по wire-имени (`don` → «Дон»).
  /// Русское название роли по служебному имени из истории.
  ///
  /// Словарь живёт в модели роли (`Role.nameRuFor`): здесь раньше была
  /// своя копия на семь ролей, и новые роли 1.12.0 выпадали из протокола
  /// английским словом. Неизвестное имя по-прежнему возвращается как есть.
  static String _roleRu(String wire) => Role.nameRuFor(wire);
}
