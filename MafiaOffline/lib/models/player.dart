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

  /// Восстановление игрока из сохранения партии.
  ///
  /// Разбор намеренно «мягкий»: сохранение пишется на диск и может быть
  /// записано прошлой версией приложения, повреждено при сбое питания
  /// или содержать поле другого типа (раньше `name` был числом, потом
  /// стал строкой). `as String?` в таком случае бросает исключение —
  /// и партия не восстанавливается вообще, хотя терять ради одного
  /// поля весь расклад ролей нельзя.
  ///
  /// Поэтому каждое поле проверяется по типу: не подошло — берём
  /// значение по умолчанию. Игрок с пустым именем попадёт в партию как
  /// «—», и ведущий увидит это в списке.
  static Player fromStorageJson(Map<String, dynamic> j) => Player(
        id: _str(j['id']) ?? '',
        name: _str(j['name']) ?? '—',
        colorHex: _str(j['color']) ?? '#888888',
        role: Role.tryParse(_str(j['role'])),
        isAlive: _bool(j['isAlive']) ?? true,
        roleAcknowledged: _bool(j['roleAck']) ?? false,
        deviceId: _str(j['deviceId']),
        eliminatedRound: _int(j['eliminatedRound']),
        eliminationReason: _parseReason(_str(j['reason'])),
      );

  static String? _str(Object? v) => v is String ? v : null;
  static bool? _bool(Object? v) => v is bool ? v : null;
  static int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
}
