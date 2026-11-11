import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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

      final savedAt = map['savedAt'] as int? ?? 0;
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

  GameState _decode(Map<String, dynamic> m) {
    final rawPlayers = m['players'];
    final players = <Player>[];
    if (rawPlayers is List) {
      for (final p in rawPlayers) {
        if (p is Map) {
          players.add(
            Player.fromStorageJson(Map<String, dynamic>.from(p))
                // После перезапуска связи ни с кем нет, пока не переподключатся.
                .copyWith(isConnected: false),
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

    Map<String, String?> _strMap(Object? raw) {
      final out = <String, String?>{};
      if (raw is Map) {
        raw.forEach((k, v) {
          if (k is String) out[k] = v is String ? v : null;
        });
      }
      return out;
    }

    final rawRunoff = m['runoff'];
    final runoff = <String>[];
    if (rawRunoff is List) {
      for (final e in rawRunoff) {
        if (e is String) runoff.add(e);
      }
    }

    return GameState(
      id: m['id'] as String? ?? '0',
      name: m['name'] as String? ?? 'Игра',
      code: m['code'] as String? ?? '000000',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          m['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch),
      plannedPlayers: m['plannedPlayers'] as int? ?? players.length,
      phase: GamePhaseX.parse(m['phase'] as String?),
      round: m['round'] as int? ?? 1,
      // Таймер после восстановления стоит на паузе: ведущий сам решит,
      // когда продолжить — за время простоя ситуация за столом изменилась.
      timeLeft: m['timeLeft'] as int? ?? 0,
      paused: true,
      lastHealedId: m['lastHealedId'] as String?,
      roleSetup: setup,
      players: players,
      log: log,
      nightActions: _strMap(m['nightActions']),
      votes: _strMap(m['votes']),
      runoffCandidates: runoff,
      awaitingVoteConfirm: m['awaitingVoteConfirm'] as bool? ?? false,
    );
  }
}
