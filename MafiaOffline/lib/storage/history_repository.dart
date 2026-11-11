import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/game_event.dart';
import '../models/game_state.dart';

/// Локальное хранилище истории партий. Работает полностью офлайн.
class HistoryRepository {
  static Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'mafia_offline.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE games (
            id            TEXT PRIMARY KEY,
            name          TEXT    NOT NULL,
            code          TEXT    NOT NULL,
            created_at    INTEGER NOT NULL,
            ended_at      INTEGER,
            rounds        INTEGER NOT NULL DEFAULT 0,
            winner        TEXT,
            players_json  TEXT    NOT NULL,
            log_json      TEXT    NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_games_created ON games (created_at DESC)');
      },
    );
    return _db!;
  }

  Future<void> saveGame(GameState s) async {
    try {
      final db = await _open();
      await db.insert(
        'games',
        {
          'id': s.id,
          'name': s.name,
          'code': s.code,
          'created_at': s.createdAt.millisecondsSinceEpoch,
          'ended_at': s.endedAt?.millisecondsSinceEpoch,
          'rounds': s.round,
          'winner': s.winner?.name,
          'players_json':
              jsonEncode(s.players.map((p) => p.toStorageJson()).toList()),
          'log_json': jsonEncode(s.log.map((e) => e.toJson()).toList()),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // История не критична для хода игры — молча пропускаем сбой записи.
    }
  }

  Future<List<GameSummary>> listGames() async {
    try {
      final db = await _open();
      final rows = await db.query('games', orderBy: 'created_at DESC');
      return rows.map(GameSummary.fromRow).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<GameEvent>> logOf(String gameId) async {
    try {
      final db = await _open();
      final rows =
          await db.query('games', where: 'id = ?', whereArgs: [gameId], limit: 1);
      if (rows.isEmpty) return const [];
      final raw = jsonDecode(rows.first['log_json'] as String? ?? '[]');
      if (raw is! List) return const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(GameEvent.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Вся партия целиком: нужна для экспорта протокола (FR-7.7).
  /// Возвращает null, если записи нет.
  Future<GameSummary?> gameOf(String gameId) async {
    try {
      final db = await _open();
      final rows = await db.query('games',
          where: 'id = ?', whereArgs: [gameId], limit: 1);
      if (rows.isEmpty) return null;
      return GameSummary.fromRow(rows.first);
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteGame(String id) async {
    try {
      final db = await _open();
      await db.delete('games', where: 'id = ?', whereArgs: [id]);
    } catch (_) {}
  }
}

class GameSummary {
  final String id;
  final String name;
  final DateTime createdAt;
  final int rounds;
  final String? winner;
  final List<Map<String, dynamic>> players;

  const GameSummary({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.rounds,
    required this.winner,
    required this.players,
  });

  static GameSummary fromRow(Map<String, Object?> row) {
    final rawPlayers = jsonDecode(row['players_json'] as String? ?? '[]');
    return GameSummary(
      id: row['id'] as String,
      name: row['name'] as String? ?? 'Игра',
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int? ?? 0),
      rounds: row['rounds'] as int? ?? 0,
      winner: row['winner'] as String?,
      players: rawPlayers is List
          ? rawPlayers.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : const [],
    );
  }

  String get winnerTitle {
    switch (winner) {
      case 'mafia':
        return 'Победила мафия';
      case 'civilians':
        return 'Победили мирные';
      case 'maniac':
        return 'Победил маньяк';
      case 'nobody':
        return 'Ничья — никто не выжил';
      case 'aborted':
        return 'Прервана';
      default:
        return 'Не завершена';
    }
  }
}
