import 'dart:convert';

import '../core/constants.dart';

/// Типы сообщений. Ведущий — единственный источник истины:
/// клиент только отображает то, что получил.
class Msg {
  // ведущий -> игрок
  static const registerOk = 'register_ok';
  static const registerDenied = 'register_denied';
  static const lobby = 'lobby';
  static const roleAssign = 'role_assign';
  static const phase = 'phase';
  static const timeUpdate = 'time_update';
  static const nightResult = 'night_result';
  static const voteRunoff = 'vote_runoff';
  static const voteResult = 'vote_result';
  static const eliminated = 'eliminated';
  static const sync = 'sync';
  static const gameOver = 'game_over';

  /// Сюжетная карточка: ведущий показывает кадр момента всем игрокам.
  /// Отдельный тип, а не общий `info`: клиент показывает большую картинку,
  /// игрок закрывает её сам, и она не должна теряться при переподключении.
  static const story = 'story';

  /// Игрок закрыл карточку (не обязательно; ведущий тоже может закрыть).
  static const storyDismiss = 'story_dismiss';
  static const kick = 'kick';

  /// Результат проверки — ТОЛЬКО комиссару, который её сделал (v1.2.0).
  /// Никому другому пакет не уходит; в лог игроков проверка не попадает.
  static const checkResult = 'check_result';

  /// Ведущий изменил имя игрока — клиент обязан его принять.
  static const rename = 'rename';

  /// Игрок вернулся в свой слот после перезапуска приложения.
  static const reclaimed = 'reclaimed';
  static const pong = 'pong';

  /// Команда синхронного воспроизведения звука на всех устройствах.
  static const sound = 'sound';
  static const ack = 'ack';

  // игрок -> ведущий
  static const register = 'register';
  static const nightAction = 'night_action';
  static const vote = 'vote';
  static const ping = 'ping';
  static const resyncRequest = 'resync_request';
  static const leave = 'leave';

  /// Игрок прочитал и подтвердил свою роль.
  static const roleAck = 'role_ack';
}

/// Причины отказа в подключении.
class DenyReason {
  static const nameTaken = 'name_taken';
  static const gameFull = 'game_full';
  static const gameStarted = 'game_started';
  static const badCode = 'bad_code';

  /// Версия протокола не совпала. Клиент должен сказать человеку
  /// «обновите страницу», а не молча висеть в «Подключение…».
  static const badVersion = 'bad_version';
}

/// Конверт сообщения: тип + версия + метка времени + полезная нагрузка.
class Envelope {
  final String type;
  final Map<String, dynamic> data;
  final int version;
  final int ts;

  Envelope(this.type, [Map<String, dynamic>? data])
      : data = data ?? <String, dynamic>{},
        version = Net.protocolVersion,
        ts = DateTime.now().millisecondsSinceEpoch;

  Envelope._raw(this.type, this.data, this.version, this.ts);

  String encode() => jsonEncode({
        'v': version,
        'ts': ts,
        'type': type,
        ...data,
      });

  /// Версия последнего пакета, который не подошёл по версии.
  ///
  /// Зачем статическое поле: [decode] — чистая функция разбора, и тащить
  /// в неё состояние сервера некрасиво. Но серверу нужно знать, что клиент
  /// «из прошлого», чтобы ответить `bad_version`, а не молчать. Флаг
  /// сбрасывается при каждом вызове decode.
  static int? lastRejectedVersion;

  /// Разбор входящего сообщения. Возвращает null, если пакет повреждён
  /// или версия протокола не совпадает (тогда смотри [lastRejectedVersion]).
  static Envelope? decode(String raw) {
    lastRejectedVersion = null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final type = decoded['type'];
      if (type is! String) return null;

      // `as int?` бросает исключение при строке или дробном числе —
      // а прислать `"v":"1"` может и обновлённый клиент из кеша, и
      // что угодно, что стучится в открытый порт. Ловится оно внешним
      // try, но тогда сообщение молча пропадает вместо понятного
      // «версия не та». Разбираем тип явно.
      final rawVersion = decoded['v'];
      final version = rawVersion is int
          ? rawVersion
          : (rawVersion is num ? rawVersion.toInt() : 0);
      if (version != Net.protocolVersion) {
        lastRejectedVersion = version;
        return null;
      }

      final rawTs = decoded['ts'];
      final data = Map<String, dynamic>.from(decoded)
        ..remove('type')
        ..remove('v')
        ..remove('ts');
      return Envelope._raw(
        type,
        data,
        version,
        rawTs is int ? rawTs : (rawTs is num ? rawTs.toInt() : 0),
      );
    } catch (_) {
      return null;
    }
  }

  T? get<T>(String key) {
    final value = data[key];
    return value is T ? value : null;
  }

  @override
  String toString() => 'Envelope($type, $data)';
}
