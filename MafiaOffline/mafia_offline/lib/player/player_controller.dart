import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/assets.dart';
import '../models/game_phase.dart';
import '../models/role.dart';
import '../net/client_connection.dart';
import '../net/protocol.dart';
import '../services/audio_service.dart';
import '../services/synced_audio.dart';
import '../storage/player_session_store.dart';

class TeammateInfo {
  final String name;
  final bool isDon;
  const TeammateInfo(this.name, this.isDon);
}

class TargetInfo {
  final String id;
  final String name;
  final String color;
  const TargetInfo(this.id, this.name, this.color);
}

/// Состояние клиента-игрока. Тонкий: не содержит игровой логики,
/// только отображает то, что прислал ведущий.
class PlayerController extends ChangeNotifier {
  final ClientConnection conn = ClientConnection();

  /// Синхронизация часов с ведущим для одновременного звука.
  final SyncedAudio synced = SyncedAudio();
  final PlayerSessionStore _sessionStore = PlayerSessionStore();

  /// Код и адрес текущей партии — нужны, чтобы переподключиться
  /// без повторного ввода.
  String? gameCode;
  String? hostAddress;

  /// Игрок скрыл свою карту — на экране показывается «мирный житель».
  bool disguised = false;

  /// Карта раскрыта (игрок держит палец / нажал «показать»).
  bool cardRevealed = false;

  /// Роль получена, но игрок ещё не нажал «Понятно» —
  /// показываем предупреждающий экран перед раскрытием.
  bool awaitingRoleReveal = false;

  /// Игрок подтвердил, что ознакомился с ролью.
  bool roleAcknowledged = false;

  StreamSubscription? _msgSub;
  StreamSubscription? _statusSub;
  Timer? _localTick;

  String gameName = '';
  String playerName = '';
  String? playerId;

  GamePhase phase = GamePhase.waiting;
  int round = 0;
  int timeLeft = 0;
  bool paused = false;

  bool isAlive = true;
  bool canAct = false;
  bool actionSent = false;
  String prompt = 'Ожидание начала игры...';

  String? roleName;
  String? roleEmoji;
  String? roleDescription;
  String? roleAsset;
  List<TeammateInfo> teammates = const [];

  List<TargetInfo> targets = const [];
  String? selectedTargetId;

  /// Публичный список игроков в лобби.
  List<({String name, String color, bool alive, bool online})> lobby = const [];

  List<String> eventLog = [];
  String? banner;
  String? deniedReason;
  String? gameOverTitle;
  List<({String name, String role, String emoji, bool alive})> reveal = const [];

  ConnStatus get status => conn.status;
  int get reconnectAttempt => conn.attempt;

  PlayerController() {
    _msgSub = conn.messages.listen(_onMessage);
    _statusSub = conn.statusStream.listen((s) {
      // После обрыва маршрут мог смениться — старые замеры часов уже не годятся.
      if (s == ConnStatus.reconnecting) synced.reset();
      notifyListeners();
    });
    // Локальный отсчёт между пакетами синхронизации — таймер идёт плавно.
    _localTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!paused && timeLeft > 0 && phase != GamePhase.ended) {
        timeLeft--;
        notifyListeners();
      }
    });
  }

  Future<bool> join({
    required String code,
    required String name,
    String? manualHost,
  }) async {
    playerName = name;
    gameCode = code;
    hostAddress = manualHost;
    deniedReason = null;
    final ok = await conn.connect(
      code: code,
      playerName: name,
      manualHost: manualHost,
    );
    notifyListeners();
    return ok;
  }

  void _onMessage(Envelope msg) {
    switch (msg.type) {
      case Msg.registerOk:
        playerId = msg.get<String>('id');
        gameName = msg.get<String>('gameName') ?? 'Игра';
        deniedReason = null;
        _saveSession();
        break;

      case Msg.registerDenied:
        deniedReason = msg.get<String>('reason');
        break;

      case Msg.lobby:
        gameName = msg.get<String>('gameName') ?? gameName;
        final list = msg.get<List>('players') ?? const [];
        lobby = list
            .whereType<Map>()
            .map((p) => (
                  name: p['name'] as String? ?? '',
                  color: p['color'] as String? ?? '#888888',
                  alive: p['isAlive'] as bool? ?? true,
                  online: p['isConnected'] as bool? ?? true,
                ))
            .toList();
        break;

      case Msg.roleAssign:
        // Роль пришла, но сразу её не показываем: сначала предупреждение,
        // чтобы игрок успел отвернуть экран от соседей.
        awaitingRoleReveal = true;
        roleAcknowledged = false;
        cardRevealed = false;
        roleAsset = A.card(_roleTypeFromWire(msg.get<String>('role')));
        roleName = msg.get<String>('roleName');
        roleEmoji = msg.get<String>('roleEmoji');
        roleDescription = msg.get<String>('roleDescription');
        final mates = msg.get<List>('teammates') ?? const [];
        teammates = mates
            .whereType<Map>()
            .map((m) => TeammateInfo(
                  m['name'] as String? ?? '',
                  m['isDon'] as bool? ?? false,
                ))
            .toList();
        break;

      case Msg.phase:
      case Msg.sync:
        _applyPhase(msg);
        break;

      case Msg.timeUpdate:
        timeLeft = msg.get<int>('time') ?? timeLeft;
        paused = msg.get<bool>('paused') ?? paused;
        break;

      case Msg.nightResult:
        final text = msg.get<String>('text') ?? '';
        banner = text;
        if (text.isNotEmpty) eventLog.insert(0, text);
        break;

      case Msg.voteRunoff:
        final cands = msg.get<List>('candidates') ?? const [];
        targets = cands
            .whereType<Map>()
            .map((c) => TargetInfo(
                  c['id'] as String? ?? '',
                  c['name'] as String? ?? '',
                  '#888888',
                ))
            .toList();
        actionSent = false;
        selectedTargetId = null;
        canAct = isAlive;
        banner = 'Второй тур голосования';
        break;

      case Msg.voteResult:
        final name = msg.get<String>('eliminatedName');
        final text = name == null
            ? 'Голосование: никто не выбывает'
            : 'Голосованием выбыл $name';
        banner = text;
        eventLog.insert(0, text);
        break;

      case Msg.eliminated:
        isAlive = false;
        canAct = false;
        final reason = msg.get<String>('reason');
        banner = reason == 'vote'
            ? 'Вас выгнали голосованием'
            : 'Вас убили этой ночью';
        break;

      case Msg.gameOver:
        phase = GamePhase.ended;
        canAct = false;
        _sessionStore.clear();
        gameOverTitle = msg.get<String>('title');
        final list = msg.get<List>('reveal') ?? const [];
        reveal = list
            .whereType<Map>()
            .map((r) => (
                  name: r['name'] as String? ?? '',
                  role: r['role'] as String? ?? '',
                  emoji: r['emoji'] as String? ?? '',
                  alive: r['isAlive'] as bool? ?? false,
                ))
            .toList();
        break;

      case Msg.rename:
        // Ведущий изменил имя — принимаем без вопросов.
        final newName = msg.get<String>('name');
        if (newName != null && newName.isNotEmpty) {
          playerName = newName;
          banner = 'Ведущий изменил ваше имя на «$newName»';
          // Иначе при возврате в игру мы представимся старым именем
          // и создадим дубль вместо возврата в свой слот.
          _saveSession();
        }
        break;

      case Msg.reclaimed:
        // Вернулись в свой слот после перезапуска приложения.
        playerId = msg.get<String>('id');
        gameName = msg.get<String>('gameName') ?? gameName;
        deniedReason = null;
        banner = 'Вы вернулись в игру';
        _saveSession();
        break;

      case Msg.kick:
        banner = 'Ведущий исключил вас из игры';
        canAct = false;
        _sessionStore.clear();
        conn.close();
        break;

      case Msg.ack:
        actionSent = true;
        canAct = false;
        break;

      case Msg.pong:
        // Считаем смещение часов относительно ведущего.
        synced.onPong(
          sentAtLocal: msg.get<int>('echo') ?? 0,
          hostTime: msg.get<int>('hostTime') ?? 0,
        );
        conn.reportedRtt = synced.rttMs;
        return; // не перерисовываем экран из-за служебного пакета

      case Msg.sound:
        // Общий звук: играем ровно в назначенный ведущим момент.
        final asset = msg.get<String>('asset');
        final playAt = msg.get<int>('playAt');
        if (asset != null && playAt != null) {
          synced.scheduleAt(
            hostPlayAt: playAt,
            asset: asset,
            volume: (msg.get<num>('volume') ?? 1).toDouble(),
          );
        }
        return;
    }
    notifyListeners();
  }

  void _applyPhase(Envelope msg) {
    phase = GamePhaseX.parse(msg.get<String>('phase'));
    round = msg.get<int>('round') ?? round;
    timeLeft = msg.get<int>('time') ?? 0;
    paused = msg.get<bool>('paused') ?? false;
    isAlive = msg.get<bool>('isAlive') ?? isAlive;
    canAct = msg.get<bool>('canAct') ?? false;
    actionSent = msg.get<bool>('alreadyActed') ?? false;
    prompt = msg.get<String>('prompt') ?? prompt;
    gameName = msg.get<String>('gameName') ?? gameName;

    // sync после переподключения приносит роль заново.
    final syncRole = msg.get<String>('role');
    if (syncRole != null) roleAsset = A.card(_roleTypeFromWire(syncRole));
    roleName = msg.get<String>('roleName') ?? roleName;
    roleEmoji = msg.get<String>('roleEmoji') ?? roleEmoji;
    roleDescription = msg.get<String>('roleDescription') ?? roleDescription;
    final mates = msg.get<List>('teammates');
    if (mates != null && mates.isNotEmpty) {
      teammates = mates
          .whereType<Map>()
          .map((m) => TeammateInfo(
                m['name'] as String? ?? '',
                m['isDon'] as bool? ?? false,
              ))
          .toList();
    }

    final list = msg.get<List>('targets') ?? const [];
    targets = list
        .whereType<Map>()
        .map((t) => TargetInfo(
              t['id'] as String? ?? '',
              t['name'] as String? ?? '',
              t['color'] as String? ?? '#888888',
            ))
        .toList();

    selectedTargetId = null;
    if (phase == GamePhase.night) banner = null;

    // Фон фазы. Играет у каждого игрока, а не только у ведущего.
    switch (phase) {
      case GamePhase.night:
        AudioService.instance.playAmbient(A.ambNight);
        break;
      case GamePhase.day:
        AudioService.instance.playAmbient(A.ambDay);
        break;
      case GamePhase.voting:
        AudioService.instance.playAmbient(A.ambVote);
        break;
      case GamePhase.ended:
        AudioService.instance.stopAmbient();
        break;
      case GamePhase.waiting:
        break;
    }

    // При смене фазы карта снова прячется — чтобы не осталась
    // открытой на столе после ночного хода.
    cardRevealed = false;
  }

  /// Игрок подтвердил, что готов увидеть роль.
  void confirmRoleReveal() {
    awaitingRoleReveal = false;
    roleAcknowledged = true;
    cardRevealed = true;
    AudioService.instance.play(A.revealCard, volume: 0.8);
    conn.send(Envelope(Msg.roleAck, {'playerId': playerId}));
    notifyListeners();
  }

  /// Показать/скрыть свою карту (кнопка «глаз»).
  void toggleCard() {
    cardRevealed = !cardRevealed;
    AudioService.instance
        .play(cardRevealed ? A.revealCard : A.hideCard, volume: 0.7);
    notifyListeners();
  }

  /// Режим маскировки: если кто-то подсмотрит, увидит мирного жителя.
  void toggleDisguise() {
    disguised = !disguised;
    AudioService.instance.play(A.tap, volume: 0.5);
    notifyListeners();
  }

  /// Что показывать на карточке прямо сейчас.
  /// Возвращает подменённые данные, когда включена маскировка.
  ({String asset, String name, String emoji, String description}) get shownCard {
    if (disguised) {
      return (
        asset: A.decoyCard,
        name: 'Мирный житель',
        emoji: '👤',
        description: 'Ночью спит. Днём обсуждает и голосует, пытаясь найти мафию.',
      );
    }
    return (
      asset: roleAsset ?? A.decoyCard,
      name: roleName ?? 'Роль неизвестна',
      emoji: roleEmoji ?? '👤',
      description: roleDescription ?? '',
    );
  }

  RoleType _roleTypeFromWire(String? wire) {
    for (final t in RoleType.values) {
      if (t.name == wire) return t;
    }
    return RoleType.civilian;
  }

  void select(String id) {
    if (!canAct || actionSent) return;
    selectedTargetId = (selectedTargetId == id) ? null : id;
    notifyListeners();
  }

  /// Отправка ночного действия или голоса.
  void submit({bool skip = false}) {
    if (!canAct || actionSent) return;
    final target = skip ? null : selectedTargetId;
    if (!skip && target == null) return;

    final type = phase == GamePhase.voting ? Msg.vote : Msg.nightAction;
    conn.send(Envelope(type, {
      'playerId': playerId,
      'targetId': target,
    }));

    actionSent = true;
    canAct = false;
    notifyListeners();
  }

  Future<void> retry() async {
    await conn.retry();
    notifyListeners();
  }

  void _saveSession() {
    final code = gameCode;
    if (code == null) return;
    _sessionStore.save(PlayerSession(
      code: code,
      name: playerName,
      playerId: playerId,
      host: hostAddress,
      savedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// Полный выход из партии: сессия стирается, при следующем запуске
  /// приложение снова спросит имя.
  Future<void> forget() async {
    await _sessionStore.clear();
    await leave();
  }

  Future<void> leave() async {
    conn.send(Envelope(Msg.leave, {'playerId': playerId}));
    await conn.close();
    notifyListeners();
  }

  @override
  void dispose() {
    synced.cancelAll();
    AudioService.instance.stopAmbient();
    _localTick?.cancel();
    _msgSub?.cancel();
    _statusSub?.cancel();
    conn.dispose();
    super.dispose();
  }
}
