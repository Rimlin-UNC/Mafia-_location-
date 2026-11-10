import 'game_phase.dart';

enum EventType {
  phaseStart,
  kill,
  heal,
  check,
  block,
  elimination,
  disconnect,
  reconnect,
  gameOver,
  info,
}

class GameEvent {
  final int round;
  final GamePhase phase;
  final EventType type;
  final String text;

  /// Видно ли событие обычным игрокам (в логе зрителя).
  /// Результат проверки комиссара, например, виден только ведущему.
  final bool visibleToPlayers;
  final DateTime at;

  GameEvent({
    required this.round,
    required this.phase,
    required this.type,
    required this.text,
    this.visibleToPlayers = true,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'round': round,
        'phase': phase.name,
        'type': type.name,
        'text': text,
        'pub': visibleToPlayers,
        'at': at.millisecondsSinceEpoch,
      };

  static GameEvent fromJson(Map<String, dynamic> j) => GameEvent(
        round: j['round'] as int? ?? 0,
        phase: GamePhaseX.parse(j['phase'] as String?),
        type: EventType.values.firstWhere(
          (e) => e.name == j['type'],
          orElse: () => EventType.info,
        ),
        text: j['text'] as String? ?? '',
        visibleToPlayers: j['pub'] as bool? ?? true,
        at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int? ?? 0),
      );
}
