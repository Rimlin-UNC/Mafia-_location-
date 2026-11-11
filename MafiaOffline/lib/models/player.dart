import 'role.dart';

/// Причина выбывания игрока.
enum EliminationReason { killed, voted, kicked }

class Player {
  final String id;
  final String name;
  final String colorHex;
  final Role? role;
  final bool isAlive;
  final bool isConnected;

  /// Игрок открыл карточку роли и нажал «Понятно».
  /// Ведущий по этому флагу видит, кто уже готов начинать.
  final bool roleAcknowledged;
  final int? eliminatedRound;
  final EliminationReason? eliminationReason;

  /// Постоянный идентификатор устройства игрока.
  ///
  /// Позволяет отличить «он вернулся со второго телефона» от «кто-то ввёл
  /// то же имя»: при совпадении `deviceId` слот можно отдать новому
  /// подключению, даже если старый сокет ещё считается живым.
  /// Хранится только в памяти партии и в локальном сохранении.
  final String? deviceId;

  /// Время последнего ping — по нему ведущий определяет обрыв связи.
  final DateTime? lastSeen;

  const Player({
    required this.id,
    required this.name,
    required this.colorHex,
    this.role,
    this.isAlive = true,
    this.isConnected = true,
    this.roleAcknowledged = false,
    this.eliminatedRound,
    this.eliminationReason,
    this.deviceId,
    this.lastSeen,
  });

  Player copyWith({
    String? name,
    String? colorHex,
    Role? role,
    bool? isAlive,
    bool? isConnected,
    bool? roleAcknowledged,
    int? eliminatedRound,
    EliminationReason? eliminationReason,
    String? deviceId,
    DateTime? lastSeen,
    bool clearRole = false,
  }) {
    return Player(
      id: id,
      name: name ?? this.name,
      colorHex: colorHex ?? this.colorHex,
      role: clearRole ? null : (role ?? this.role),
      isAlive: isAlive ?? this.isAlive,
      isConnected: isConnected ?? this.isConnected,
      roleAcknowledged: roleAcknowledged ?? this.roleAcknowledged,
      eliminatedRound: eliminatedRound ?? this.eliminatedRound,
      eliminationReason: eliminationReason ?? this.eliminationReason,
      deviceId: deviceId ?? this.deviceId,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  /// Публичные данные — то, что безопасно отправлять всем игрокам.
  /// Роль сюда НЕ попадает.
  Map<String, dynamic> toPublicJson() => {
        'id': id,
        'name': name,
        'color': colorHex,
        'isAlive': isAlive,
        'isConnected': isConnected,
        'roleAck': roleAcknowledged,
      };

  Map<String, dynamic> toStorageJson() => {
        'id': id,
        'name': name,
        'color': colorHex,
        'role': role?.type.name,
        'isAlive': isAlive,
        'roleAck': roleAcknowledged,
        'deviceId': deviceId,
        'eliminatedRound': eliminatedRound,
        'reason': eliminationReason?.name,
      };

  static EliminationReason? _parseReason(Object? raw) {
    if (raw is! String) return null;
    for (final r in EliminationReason.values) {
      if (r.name == raw) return r;
    }
    return null;
  }

  static Player fromStorageJson(Map<String, dynamic> j) => Player(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '—',
        colorHex: j['color'] as String? ?? '#888888',
        role: Role.tryParse(j['role'] as String?),
        isAlive: j['isAlive'] as bool? ?? true,
        roleAcknowledged: j['roleAck'] as bool? ?? false,
        deviceId: j['deviceId'] as String?,
        eliminatedRound: j['eliminatedRound'] as int?,
        eliminationReason: _parseReason(j['reason']),
      );
}
