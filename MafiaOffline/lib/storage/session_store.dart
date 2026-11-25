import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/phase_timings.dart';
import '../models/game_event.dart';
import '../models/game_phase.dart';
import '../models/game_state.dart';
import '../models/player.dart';
import '../models/role.dart';

/// Сохранение активной партии, чтобы пережить перезапуск приложения ведущего.
///
/// Пишем на каждой смене фазы и после каждого выбывания. Если телефон
/// перезагрузился или система выгрузила приложение, ведущий возвращается
/// в ту же точку: фаза, раунд, живые игроки, роли и лог на месте.
/// Игроки переподключаются автоматически и получают `sync`.
class SessionStore {
  static const _key = 'active_session_v1';

  /// Партия считается устаревшей, если её не трогали дольше этого срока.
  static const _maxAge = Duration(hours: 6);

  Future<void> save(GameState s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_encode(s)));
    } catch (_) {
      // Сбой записи не должен прерывать партию.
    }
  }

  Future<GameState?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return null;

      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return null;

      final savedAt = _int(map['savedAt']) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - savedAt;
      if (age > _maxAge.inMilliseconds) {
        await clear();
        return null;
      }

      final state = _decode(map);
      // Законченную партию восстанавливать незачем.
      if (state.phase == GamePhase.ended) {
        await clear();
        return null;
      }
      return state;
    } catch (_) {
      await clear();
      return null;
    }
  }

  Future<bool> hasSession() async => (await load()) != null;

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }

  // ---------- сериализация ----------

  Map<String, dynamic> _encode(GameState s) => {
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'id': s.id,
        'name': s.name,
        'code': s.code,
        'createdAt': s.createdAt.millisecondsSinceEpoch,
        'plannedPlayers': s.plannedPlayers,
        'phase': s.phase.name,
        // Фаза rolesCheck сохраняется как есть: партия уже не в лобби,
        // но первая ночь ещё не началась.
        'round': s.round,
        'timeLeft': s.timeLeft,
        'lastHealedId': s.lastHealedId,
        'lastGuardedId': s.lastGuardedId,
        'timings': s.timings.toJson(),
        'piercingShot': s.piercingShot,
        'piercingSpent': s.piercingSpent,
        'piercingRequests': s.piercingRequests,
        'openCards': s.openCards,
        // Правила стола и служебное состояние 1.2.0. Без них перезапуск
        // посреди партии молча менял бы правила на значения по умолчанию.
        'introNight': s.introNight,
        'lastWord': s.lastWord,
        'privateCheck': s.privateCheck,
        'lastWordId': s.lastWordId,
        'verdictId': s.verdictId,
        'checks': s.checks.map((c) => c.toJson()).toList(),
        // Сюжетные карточки: иначе после перезапуска «Первая кровь»
        // показалась бы второй раз.
        'storySeen': s.storySeen,
        'noDeathsStreak': s.noDeathsStreak,
        'lastBotSpeechRound': s.lastBotSpeechRound,
        // 1.12.0: шантаж, наблюдение свидетеля и метка охотника.
        // Без них перезапуск посреди дня «снимал» бы запугивание и
        // заставлял свидетеля смотреть заново.
        'silencedId': s.silencedId,
        'silencedRound': s.silencedRound,
        'watchTargetId': s.watchTargetId,
        'watchActed': s.watchActed,
        'watchRound': s.watchRound,
        'hunterMarkId': s.hunterMarkId,
        'roleSetup': {
          for (final e in s.roleSetup.entries) e.key.name: e.value,
        },
        // Незавершённые действия текущей фазы. Без них перезапуск посреди
        // ночи «съедал» уже собранные ходы: игроки отправить повторно
        // не могут (сервер отвечает «уже ходил»), и фаза зависала.
        'nightActions': s.nightActions,
        'votes': s.votes,
        'runoff': s.runoffCandidates,
        'awaitingVoteConfirm': s.awaitingVoteConfirm,
        'players': s.players.map((p) => p.toStorageJson()).toList(),
        'log': s.log.map((e) => e.toJson()).toList(),
      };

  /// Мягкое чтение полей сохранения.
  ///
  /// Сохранение пишется на диск и переживает перезапуск приложения, смену
  /// версии и внезапное выключение телефона. Поле может оказаться другого
  /// типа: `as String?` в этом случае бросает TypeError, `load()` ловит его
  /// внешним `catch` и **молча стирает сохранение** — ведущий теряет
  /// прерванную партию целиком из-за одного поля.
  ///
  /// Эти три функции возвращают null вместо исключения: не подошло — берём
  /// значение по умолчанию и играем дальше. Так же сделано в
  /// `Player.fromStorageJson`.
  static String? _str(Object? v) => v is String ? v : null;
  static bool? _bool(Object? v) => v is bool ? v : null;
  static int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : null);

  GameState _decode(Map<String, dynamic> m) {
    final rawPlayers = m['players'];
    final players = <Player>[];
    if (rawPlayers is List) {
      for (final p in rawPlayers) {
        if (p is Map) {
          players.add(
            Player.fromStorageJson(Map<String, dynamic>.from(p))
                // После перезапуска связи ни с кем нет, пока не
                // переподключатся. Боты и локальный игрок — исключение:
                // их соединение не зависит от сети и не могло пропасть.
                .copyWith(isConnected: p['isBot'] == true || p['isLocal'] == true),
          );
        }
      }
    }

    final rawSetup = m['roleSetup'];
    final setup = <RoleType, int>{};
    if (rawSetup is Map) {
      rawSetup.forEach((k, v) {
        for (final t in RoleType.values) {
          if (t.name == k && v is int) setup[t] = v;
        }
      });
    }

    final rawLog = m['log'];
    final log = <GameEvent>[];
    if (rawLog is List) {
      for (final e in rawLog) {
        if (e is Map) log.add(GameEvent.fromJson(Map<String, dynamic>.from(e)));
      }
    }

    Map<String, String?> strMap(Object? raw) {
      final out = <String, String?>{};
      if (raw is Map) {
        raw.forEach((k, v) {
          if (k is String) out[k] = v is String ? v : null;
        });
      }
      return out;
    }

    List<String> strList(Object? raw) {
      final out = <String>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is String) out.add(e);
        }
      }
      return out;
    }

    final runoff = strList(m['runoff']);

    final checks = <CheckRecord>[];
    final rawChecks = m['checks'];
    if (rawChecks is List) {
      for (final e in rawChecks) {
        final record = CheckRecord.tryParse(e);
        if (record != null) checks.add(record);
      }
    }

    return GameState(
      id: _str(m['id']) ?? '0',
      name: _str(m['name']) ?? 'Игра',
      code: _str(m['code']) ?? '000000',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          _int(m['createdAt']) ?? DateTime.now().millisecondsSinceEpoch),
      plannedPlayers: _int(m['plannedPlayers']) ?? players.length,
      phase: GamePhaseX.parse(_str(m['phase'])),
      round: _int(m['round']) ?? 1,
      // Таймер после восстановления стоит на паузе: ведущий сам решит,
      // когда продолжить — за время простоя ситуация за столом изменилась.
      timeLeft: _int(m['timeLeft']) ?? 0,
      paused: true,
      lastHealedId: _str(m['lastHealedId']),
      // Сохранение из 1.11.x этого поля не знает — щит можно ставить
      // на кого угодно.
      lastGuardedId: _str(m['lastGuardedId']),
      // Старые сохранения поля не знают — считаем карту закрытой.
      timings: PhaseTimings.fromJson(m['timings']),
      piercingShot: _bool(m['piercingShot']) ?? false,
      piercingSpent: _bool(m['piercingSpent']) ?? false,
      piercingRequests: strList(m['piercingRequests']),
      openCards: _bool(m['openCards']) ?? false,
      // Сохранение из 1.1.x этих полей не знает. Партия, начатая по старым
      // правилам, по ним и доигрывается: без знакомства, без таймера
      // последнего слова, проверку сообщает ведущий.
      introNight: _bool(m['introNight']) ?? false,
      lastWord: _bool(m['lastWord']) ?? false,
      privateCheck: _bool(m['privateCheck']) ?? false,
      lastWordId: _str(m['lastWordId']),
      verdictId: _str(m['verdictId']),
      checks: checks,
      storySeen: strList(m['storySeen']),
      noDeathsStreak: _int(m['noDeathsStreak']) ?? 0,
      lastBotSpeechRound: _int(m['lastBotSpeechRound']) ?? 0,
      silencedId: _str(m['silencedId']),
      silencedRound: _int(m['silencedRound']) ?? 0,
      watchTargetId: _str(m['watchTargetId']),
      watchActed: _bool(m['watchActed']),
      watchRound: _int(m['watchRound']) ?? 0,
      hunterMarkId: _str(m['hunterMarkId']),
      roleSetup: setup,
      players: players,
      log: log,
      nightActions: strMap(m['nightActions']),
      votes: strMap(m['votes']),
      runoffCandidates: runoff,
      awaitingVoteConfirm: _bool(m['awaitingVoteConfirm']) ?? false,
    );
  }
}
