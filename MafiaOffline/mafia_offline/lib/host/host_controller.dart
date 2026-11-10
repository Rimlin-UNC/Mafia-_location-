import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/game_engine.dart';
import '../models/game_event.dart';
import '../models/game_phase.dart';
import '../models/game_state.dart';
import '../models/player.dart';
import '../models/role.dart';
import '../core/assets.dart';
import '../net/host_server.dart';
import '../net/protocol.dart';
import '../services/audio_service.dart';
import '../services/host_background.dart';
import '../services/synced_audio.dart';
import '../storage/history_repository.dart';
import '../storage/session_store.dart';

/// Контроллер ведущего: единственный источник истины по состоянию партии.
class HostController extends ChangeNotifier {
  final HostServer server = HostServer();
  final HistoryRepository _history = HistoryRepository();
  final SessionStore _session = SessionStore();
  final Random _rnd = Random.secure();

  GameState? _state;
  GameState? get state => _state;

  Timer? _tick;
  Timer? _sync;
  String? _lastError;
  String? get lastError => _lastError;

  StreamSubscription? _inboxSub;
  StreamSubscription? _lostSub;
  StreamSubscription? _restoredSub;

  String? hostAddress;

  /// Создание партии и запуск локального сервера.
  Future<bool> createGame({
    required String name,
    required int plannedPlayers,
    required Map<RoleType, int> setup,
  }) async {
    final code = _generateCode();
    _state = GameState(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      code: code,
      createdAt: DateTime.now(),
      plannedPlayers: plannedPlayers,
      roleSetup: Map<RoleType, int>.from(setup),
      phase: GamePhase.waiting,
    );

    try {
      hostAddress = await server.start(
        gameCode: code,
        gameName: name,
        plannedPlayers: plannedPlayers,
      );
    } catch (e) {
      _lastError = 'Не удалось запустить сервер: $e';
      notifyListeners();
      return false;
    }

    _inboxSub = server.inbox.listen(_onMessage);
    _lostSub = server.onPlayerLost.listen(_onPlayerLost);
    _restoredSub = server.onPlayerRestored.listen(_onPlayerRestored);

    // Служба переднего плана: без неё Android заморозит процесс через
    // несколько секунд после выключения экрана и все игроки отвалятся.
    await HostBackground.start(gameName: name, code: code);

    notifyListeners();
    return true;
  }

  /// Синхронный звук: назначаем момент воспроизведения в будущем
  /// (с форой на доставку) и рассылаем всем. Ведущий играет тот же звук
  /// по тому же расписанию — получается единый «залп» на всех телефонах.
  void _playEverywhere(String asset, {double volume = 1.0}) {
    // Фора зависит от самого медленного телефона: на хорошем Wi-Fi это
    // ~350 мс, на загруженной сети — больше, чтобы успели все.
    final lead = SyncedAudio.leadTimeFor(server.worstRttMs);
    final playAt = DateTime.now().millisecondsSinceEpoch + lead.inMilliseconds;
    server.broadcast(Envelope(Msg.sound, {
      'asset': asset,
      'playAt': playAt,
      'volume': volume,
    }));
    Timer(lead, () {
      AudioService.instance.play(asset, volume: volume);
    });
  }

  /// Фон текущей фазы. Клиенты переключают его сами по пакету phase,
  /// поэтому здесь — только сторона ведущего.
  void _ambient(String asset) => AudioService.instance.playAmbient(asset);

  /// Есть ли незавершённая партия для восстановления.
  Future<bool> hasRecoverableSession() => _session.hasSession();

  /// Восстановление партии после перезапуска приложения ведущего.
  /// Возвращает false, если сохранения нет или сервер не поднялся.
  Future<bool> restoreGame() async {
    final saved = await _session.load();
    if (saved == null) return false;

    _state = saved;
    try {
      hostAddress = await server.start(
        gameCode: saved.code,
        gameName: saved.name,
        plannedPlayers: saved.plannedPlayers,
      );
    } catch (e) {
      _lastError = 'Не удалось поднять сервер: $e';
      _state = null;
      notifyListeners();
      return false;
    }

    _inboxSub = server.inbox.listen(_onMessage);
    _lostSub = server.onPlayerLost.listen(_onPlayerLost);
    _restoredSub = server.onPlayerRestored.listen(_onPlayerRestored);

    await HostBackground.start(gameName: saved.name, code: saved.code);

    _addLog(EventType.info,
        'Партия восстановлена после перезапуска. Таймер на паузе.');

    // Фон текущей фазы возвращаем сразу, чтобы атмосфера не пропала.
    switch (saved.phase) {
      case GamePhase.night:
        _ambient(A.ambNight);
        break;
      case GamePhase.day:
        _ambient(A.ambDay);
        break;
      case GamePhase.voting:
        _ambient(A.ambVote);
        break;
      default:
        break;
    }

    // Таймер запускаем — но состояние paused держит его на месте,
    // пока ведущий не нажмёт «Продолжить».
    _startTimer();
    notifyListeners();
    return true;
  }

  /// Сохранение текущего состояния. Вызывается на каждой смене фазы
  /// и после каждого изменения состава живых.
  void _persist() {
    final s = _state;
    if (s == null) return;
    if (s.phase == GamePhase.ended) {
      _session.clear();
      return;
    }
    _session.save(s);
  }

  String _generateCode() {
    final buffer = StringBuffer();
    for (var i = 0; i < 6; i++) {
      buffer.write(_rnd.nextInt(10));
    }
    return buffer.toString();
  }

  // ==================== приём сообщений ====================

  void _onMessage(({ClientConn conn, Envelope msg}) event) {
    final s = _state;
    if (s == null) return;
    final msg = event.msg;
    final conn = event.conn;

    switch (msg.type) {
      case Msg.register:
        _handleRegister(conn, msg);
        break;
      case Msg.resyncRequest:
        _handleResync(conn, msg);
        break;
      case Msg.nightAction:
        _handleNightAction(msg);
        break;
      case Msg.vote:
        _handleVote(msg);
        break;
      case Msg.roleAck:
        final ackId = msg.get<String>('playerId');
        if (ackId != null) {
          _updatePlayer(ackId, (p) => p.copyWith(roleAcknowledged: true));
          notifyListeners();
        }
        break;

      case Msg.leave:
        final id = msg.get<String>('playerId');
        if (id != null) _markDisconnected(id);
        break;
    }
  }

  void _handleRegister(ClientConn conn, Envelope msg) {
    final s = _state!;
    final rawName = (msg.get<String>('name') ?? '').trim();
    final name = rawName.isEmpty ? 'Игрок' : rawName;

    // ВАЖНО: возврат в свой слот проверяем ПЕРВЫМ делом — раньше проверок
    // фазы и заполненности. Иначе игрок, у которого разрядился телефон
    // посреди партии, получит отказ «игра уже началась» и не вернётся
    // в собственную роль.
    // Игрок с таким именем уже есть. Два случая:
    //  * он сейчас на связи  -> имя действительно занято, отказ;
    //  * связи с ним нет     -> это он сам вернулся после перезапуска
    //                            приложения, пускаем в его же слот.
    final existingIndex = s.players.indexWhere(
        (p) => p.name.toLowerCase() == name.toLowerCase());
    if (existingIndex != -1) {
      final existing = s.players[existingIndex];
      if (server.isOnline(existing.id)) {
        server.sendToConn(conn,
            Envelope(Msg.registerDenied, {'reason': DenyReason.nameTaken}));
        return;
      }
      // Возврат в собственный слот: роль, статус и голоса сохраняются.
      conn.playerId = existing.id;
      // Старая вкладка того же игрока могла остаться открытой и продолжала
      // бы получать копии сообщений. Закрываем всё, кроме текущего сокета:
      // иначе человек видит игру в двух местах и путается, где настоящая.
      server.dropDuplicates(existing.id, conn);
      _updatePlayer(existing.id, (p) => p.copyWith(isConnected: true));
      server.sendToConn(
        conn,
        Envelope(Msg.reclaimed, {
          'id': existing.id,
          'color': existing.colorHex,
          'gameName': s.name,
        }),
      );
      server.sendToConn(conn, _syncEnvelopeFor(_state!.byId(existing.id)!));
      _addLog(EventType.reconnect, '${existing.name} вернулся в игру',
          visibleToPlayers: false);
      _broadcastLobby();
      notifyListeners();
      return;
    }

    // Новых игроков пускаем только в лобби и только если есть места.
    if (s.phase != GamePhase.waiting) {
      server.sendToConn(conn,
          Envelope(Msg.registerDenied, {'reason': DenyReason.gameStarted}));
      return;
    }
    if (s.players.length >= Rules.maxPlayers) {
      server.sendToConn(
          conn, Envelope(Msg.registerDenied, {'reason': DenyReason.gameFull}));
      return;
    }

    final usedColors = s.players.map((p) => p.colorHex).toSet();
    final color = kPlayerColors.firstWhere(
      (c) => !usedColors.contains(c),
      orElse: () => kPlayerColors[s.players.length % kPlayerColors.length],
    );

    final player = Player(
      id: 'p${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      colorHex: color,
      lastSeen: DateTime.now(),
    );

    conn.playerId = player.id;
    _state = s.copyWith(players: [...s.players, player]);

    server.sendToConn(
      conn,
      Envelope(Msg.registerOk, {
        'id': player.id,
        'color': color,
        'gameName': s.name,
      }),
    );
    _broadcastLobby();
    AudioService.instance.play(A.playerJoined, volume: 0.6);
    notifyListeners();
  }

  void _handleResync(ClientConn conn, Envelope msg) {
    final s = _state!;
    final id = msg.get<String>('playerId');
    var player = s.byId(id);

    // Клиент мог потерять свой id (перезагрузил вкладку, очистил хранилище),
    // но помнит имя. Ищем по имени — для игрока это тот же самый человек.
    if (player == null) {
      final name = (msg.get<String>('name') ?? '').trim().toLowerCase();
      if (name.isNotEmpty) {
        final idx =
            s.players.indexWhere((p) => p.name.toLowerCase() == name);
        if (idx != -1) player = s.players[idx];
      }
    }

    if (player == null) {
      // Игрока нет — например, партия перезапущена.
      server.sendToConn(conn,
          Envelope(Msg.registerDenied, {'reason': DenyReason.gameStarted}));
      return;
    }

    conn.playerId = player.id;
    server.dropDuplicates(player.id, conn);
    _updatePlayer(player.id, (p) => p.copyWith(isConnected: true));

    // Клиент мог не знать своего id (см. поиск по имени выше) — сообщаем.
    server.sendToConn(
      conn,
      Envelope(Msg.reclaimed, {
        'id': player.id,
        'color': player.colorHex,
        'gameName': s.name,
      }),
    );
    server.sendToConn(conn, _syncEnvelopeFor(player));
    _broadcastLobby();
    notifyListeners();
  }

  Envelope _syncEnvelopeFor(Player player) {
    final s = _state!;
    final canAct = _canPlayerAct(player);
    return Envelope(Msg.sync, {
      'phase': s.phase.wire,
      'round': s.round,
      'time': s.timeLeft,
      'paused': s.paused,
      'isAlive': player.isAlive,
      'canAct': canAct,
      'alreadyActed': s.phase == GamePhase.night
          ? s.nightActions.containsKey(player.id)
          : s.votes.containsKey(player.id),
      'role': player.role?.type.name,
      'roleName': player.role?.name,
      'roleEmoji': player.role?.emoji,
      'roleDescription': player.role?.description,
      'teammates': _teammatesFor(player),
      'targets': canAct ? _targetsFor(player) : <Map<String, dynamic>>[],
      'gameName': s.name,
    });
  }

  void _handleNightAction(Envelope msg) {
    final s = _state!;
    if (s.phase != GamePhase.night) return;
    final playerId = msg.get<String>('playerId');
    if (playerId == null) return;
    final player = s.byId(playerId);
    if (player == null || !player.isAlive) return;
    if (!(player.role?.isActiveAtNight ?? false)) return;
    if (s.nightActions.containsKey(playerId)) return; // повторно нельзя

    final target = msg.get<String>('targetId');
    final actions = Map<String, String?>.from(s.nightActions);
    actions[playerId] = target;
    _state = s.copyWith(nightActions: actions);

    server.sendTo(playerId, Envelope(Msg.ack, {'accepted': true}));
    _persist();
    notifyListeners();

    if (_state!.allNightActionsIn) {
      finishNight();
    }
  }

  void _handleVote(Envelope msg) {
    final s = _state!;
    if (s.phase != GamePhase.voting) return;
    final voterId = msg.get<String>('playerId');
    if (voterId == null) return;
    final voter = s.byId(voterId);
    if (voter == null || !voter.isAlive) return;
    if (s.votes.containsKey(voterId)) return; // один голос за тур

    var target = msg.get<String>('targetId');
    // Во втором туре принимаем голоса только за кандидатов тура.
    if (s.runoffCandidates.isNotEmpty &&
        target != null &&
        !s.runoffCandidates.contains(target)) {
      target = null;
    }

    final votes = Map<String, String?>.from(s.votes);
    votes[voterId] = target;
    _state = s.copyWith(votes: votes);

    server.sendTo(voterId, Envelope(Msg.ack, {'accepted': true}));
    _persist();
    notifyListeners();

    if (_state!.allVotesIn) {
      closeVoting();
    }
  }

  void _onPlayerLost(String playerId) {
    final s = _state;
    if (s == null) return;
    final p = s.byId(playerId);
    if (p == null || !p.isConnected) return;
    _markDisconnected(playerId);
  }

  void _markDisconnected(String playerId) {
    final s = _state;
    if (s == null) return;
    _updatePlayer(playerId, (p) => p.copyWith(isConnected: false));
    _addLog(EventType.disconnect,
        '${s.nameOf(playerId)} потерял соединение', visibleToPlayers: false);
    _broadcastLobby();
    notifyListeners();
  }

  void _onPlayerRestored(String playerId) {
    final s = _state;
    if (s == null) return;
    final p = s.byId(playerId);
    if (p == null || p.isConnected) return;
    _updatePlayer(playerId, (p) => p.copyWith(isConnected: true));
    _addLog(EventType.reconnect, '${s.nameOf(playerId)} снова на связи',
        visibleToPlayers: false);
    _broadcastLobby();
    notifyListeners();
  }

  // ==================== лобби ====================

  void _broadcastLobby() {
    final s = _state;
    if (s == null) return;
    server.broadcast(Envelope(Msg.lobby, {
      'gameName': s.name,
      'planned': s.plannedPlayers,
      'players': s.players.map((p) => p.toPublicJson()).toList(),
    }));
  }

  /// Переименование игрока ведущим.
  ///
  /// Игрок сам сменить имя после входа не может — только ведущий.
  /// Новое имя тут же уезжает владельцу и всем в лобби, поэтому
  /// расхождений между экранами не возникает.
  ///
  /// Возвращает текст ошибки или null при успехе.
  String? renamePlayer(String playerId, String rawName) {
    final s = _state;
    if (s == null) return 'Партия не запущена';

    final name = rawName.trim();
    if (name.isEmpty) return 'Имя не может быть пустым';
    if (name.length > 20) return 'Имя длиннее 20 символов';

    final target = s.byId(playerId);
    if (target == null) return 'Игрок не найден';
    if (target.name == name) return null; // менять нечего

    final clash = s.players.any((p) =>
        p.id != playerId && p.name.toLowerCase() == name.toLowerCase());
    if (clash) return 'Такое имя уже занято';

    final oldName = target.name;
    _updatePlayer(playerId, (p) => p.copyWith(name: name));

    // Владельцу — персонально, чтобы он увидел смену у себя на экране.
    server.sendTo(playerId, Envelope(Msg.rename, {'name': name}));
    _addLog(EventType.info, 'Ведущий переименовал: $oldName → $name',
        visibleToPlayers: false);
    _broadcastLobby();
    _persist();
    notifyListeners();
    return null;
  }

  /// Сколько игроков уже подтвердили, что прочитали свою роль.
  int get roleAckCount =>
      _state?.players.where((p) => p.roleAcknowledged).length ?? 0;

  /// Все ли ознакомились с ролями — по этому признаку ведущий понимает,
  /// что можно спокойно начинать первую ночь.
  bool get allRolesAcknowledged {
    final s = _state;
    if (s == null || s.players.isEmpty) return false;
    return s.players.every((p) => p.roleAcknowledged);
  }

  Future<void> kickPlayer(String playerId) async {
    final s = _state;
    if (s == null) return;
    await server.disconnectPlayer(playerId);
    _state = s.copyWith(
      players: s.players.where((p) => p.id != playerId).toList(),
    );
    _broadcastLobby();
    notifyListeners();
  }

  /// Старт партии: раздача ролей и первая ночь.
  void startGame() {
    final s = _state;
    if (s == null || s.players.isEmpty) return;

    final withRoles = GameEngine.assignRoles(
      players: s.players,
      setup: s.roleSetup,
      random: _rnd,
    );

    _state = s.copyWith(players: withRoles, round: 0);

    // Каждому — только его роль. Мафии дополнительно состав команды.
    for (final p in withRoles) {
      server.sendTo(
        p.id,
        Envelope(Msg.roleAssign, {
          'role': p.role!.type.name,
          'roleName': p.role!.name,
          'roleEmoji': p.role!.emoji,
          'roleDescription': p.role!.description,
          'teammates': _teammatesFor(p),
        }),
      );
    }

    _addLog(EventType.info, 'Игра началась. Игроков: ${withRoles.length}');
    _persist();
    _playEverywhere(A.rolesDealt);
    startNight();
  }

  List<Map<String, dynamic>> _teammatesFor(Player p) {
    final s = _state!;
    final type = p.role?.type;
    if (type != RoleType.mafia && type != RoleType.don) {
      return const [];
    }
    return s.players
        .where((m) =>
            m.id != p.id &&
            (m.role?.type == RoleType.mafia || m.role?.type == RoleType.don))
        .map((m) => {
              'name': m.name,
              'isDon': m.role?.type == RoleType.don,
              'isAlive': m.isAlive,
            })
        .toList();
  }

  // ==================== фазы ====================

  void startNight() {
    final s = _state;
    if (s == null) return;

    _state = s.copyWith(
      phase: GamePhase.night,
      round: s.round + 1,
      nightActions: <String, String?>{},
      votes: <String, String?>{},
      runoffCandidates: const [],
      awaitingVoteConfirm: false,
      paused: false,
      clearPendingNight: true,
    );
    _state = _state!.copyWith(timeLeft: _state!.nightDuration);

    _addLog(EventType.phaseStart, 'Ночь ${_state!.round}');
    HostBackground.update(
        title: 'Ночь ${_state!.round} · ${s.name}',
        text: 'Живых ${_state!.alive.length} · сервер работает');
    _persist();
    _playEverywhere(A.nightFalls);
    _ambient(A.ambNight);
    _broadcastPhase();
    _startTimer();
    notifyListeners();
  }

  /// Завершение ночи: разрешение действий и показ сводки ведущему.
  void finishNight() {
    final s = _state;
    if (s == null || s.phase != GamePhase.night) return;
    if (s.pendingNight != null) return; // сводка уже посчитана
    _stopTimer();

    final outcome = GameEngine.resolveNight(s, random: _rnd);
    _state = s.copyWith(pendingNight: outcome, paused: true);
    _persist();
    notifyListeners();
  }

  /// Ручная правка итогов ночи ведущим до оглашения.
  void editNightOutcome(NightOutcome updated) {
    final s = _state;
    if (s == null) return;
    _state = s.copyWith(pendingNight: updated);
    notifyListeners();
  }

  /// Оглашение итогов ночи и переход ко дню.
  void announceNight() {
    final s = _state;
    final outcome = s?.pendingNight;
    if (s == null || outcome == null) return;

    // Применяем смерти.
    var players = s.players;
    for (final id in outcome.killedIds) {
      players = players
          .map((p) => p.id == id
              ? p.copyWith(
                  isAlive: false,
                  eliminatedRound: s.round,
                  eliminationReason: EliminationReason.killed,
                )
              : p)
          .toList();
    }

    _state = s.copyWith(
      players: players,
      lastHealedId: outcome.healedId,
      clearLastHealed: outcome.healedId == null,
      clearPendingNight: true,
    );
    _persist();

    // Лог: публичное — только факт смерти. Проверка комиссара скрыта.
    if (outcome.killedIds.isEmpty) {
      _addLog(EventType.info, 'Ночь ${s.round}: обошлось без жертв');
    } else {
      for (final id in outcome.killedIds) {
        _addLog(EventType.kill, 'Ночь ${s.round}: погиб ${s.nameOf(id)}');
      }
    }
    if (outcome.healedId != null) {
      _addLog(EventType.heal,
          'Доктор лечил ${s.nameOf(outcome.healedId)}', visibleToPlayers: false);
    }
    if (outcome.blockedId != null) {
      _addLog(EventType.block,
          'Заблокирован ${s.nameOf(outcome.blockedId)}', visibleToPlayers: false);
    }
    if (outcome.checkedId != null) {
      _addLog(
        EventType.check,
        'Проверка: ${s.nameOf(outcome.checkedId)} — '
        '${outcome.checkResultIsMafia == true ? 'МАФИЯ' : 'мирный'}',
        visibleToPlayers: false,
      );
    }

    // Драматургия: сначала общий «удар» по факту ночи, затем результат.
    _playEverywhere(
      outcome.killedIds.isEmpty ? A.noDeaths : A.kill,
      volume: outcome.killedIds.isEmpty ? 0.85 : 1.0,
    );

    server.broadcast(Envelope(Msg.nightResult, {
      'round': s.round,
      'killed': outcome.killedIds,
      'killedNames': outcome.killedIds.map(s.nameOf).toList(),
      'text': GameEngine.announcement(s, outcome),
    }));

    // Персональные уведомления погибшим.
    for (final id in outcome.killedIds) {
      server.sendTo(
        id,
        Envelope(Msg.eliminated, {'reason': 'kill', 'round': s.round}),
      );
    }

    if (_checkGameOver()) return;
    startDay();
  }

  void startDay() {
    final s = _state;
    if (s == null) return;
    _state = s.copyWith(
      phase: GamePhase.day,
      paused: false,
      votes: <String, String?>{},
      runoffCandidates: const [],
      awaitingVoteConfirm: false,
    );
    _state = _state!.copyWith(timeLeft: _state!.dayDuration);
    _addLog(EventType.phaseStart, 'День ${_state!.round}');
    HostBackground.update(
        title: 'День ${_state!.round} · ${s.name}',
        text: 'Живых ${_state!.alive.length} · сервер работает');
    _persist();
    _playEverywhere(A.dayBreaks);
    _ambient(A.ambDay);
    _broadcastPhase();
    _startTimer();
    notifyListeners();
  }

  void startVoting({List<String> candidates = const []}) {
    final s = _state;
    if (s == null) return;
    _state = s.copyWith(
      phase: GamePhase.voting,
      votes: <String, String?>{},
      runoffCandidates: candidates,
      awaitingVoteConfirm: false,
      paused: false,
      timeLeft: candidates.isEmpty
          ? (s.votingDuration)
          : (s.runoffDuration),
    );
    _persist();
    _addLog(
      EventType.phaseStart,
      candidates.isEmpty
          ? 'Начинается голосование'
          : 'Второй тур: ${candidates.map(s.nameOf).join(', ')}',
    );

    _playEverywhere(A.voteStart);
    _ambient(A.ambVote);

    if (candidates.isNotEmpty) {
      server.broadcast(Envelope(Msg.voteRunoff, {
        'candidates': candidates
            .map((id) => {'id': id, 'name': s.nameOf(id)})
            .toList(),
      }));
    }
    _broadcastPhase();
    _startTimer();
    notifyListeners();
  }

  /// Закрытие приёма голосов. Результат ведущий подтверждает вручную.
  void closeVoting() {
    final s = _state;
    if (s == null || s.phase != GamePhase.voting) return;
    if (s.awaitingVoteConfirm) return; // уже закрыто
    _stopTimer();
    _state = s.copyWith(paused: true, awaitingVoteConfirm: true);
    notifyListeners();
  }

  /// Подтверждение выбывания по итогам голосования.
  void confirmElimination(String? playerId) {
    final s = _state;
    if (s == null) return;

    if (playerId == null) {
      _addLog(EventType.info, 'Голосование: никто не выбывает');
      server.broadcast(
          Envelope(Msg.voteResult, {'eliminated': null, 'tie': true}));
      startNight();
      return;
    }

    final players = s.players
        .map((p) => p.id == playerId
            ? p.copyWith(
                isAlive: false,
                eliminatedRound: s.round,
                eliminationReason: EliminationReason.voted,
              )
            : p)
        .toList();
    _state = s.copyWith(players: players);
    _persist();

    _addLog(EventType.elimination,
        'День ${s.round}: голосованием выбыл ${s.nameOf(playerId)}');

    _playEverywhere(A.eliminated);

    server.broadcast(Envelope(Msg.voteResult, {
      'eliminated': playerId,
      'eliminatedName': s.nameOf(playerId),
      'tie': false,
    }));
    server.sendTo(playerId,
        Envelope(Msg.eliminated, {'reason': 'vote', 'round': s.round}));

    if (_checkGameOver()) return;
    startNight();
  }

  /// Запуск второго тура между лидерами.
  void startRunoff(List<String> leaders) => startVoting(candidates: leaders);

  // ==================== таймер ====================

  void _startTimer() {
    _stopTimer();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = _state;
      if (s == null || s.paused) return;
      if (s.timeLeft > 0) {
        _state = s.copyWith(timeLeft: s.timeLeft - 1);
        notifyListeners();
      } else {
        _stopTimer();
        _onTimeout();
      }
    });

    // Точная синхронизация времени реже, чем тик: экономим канал.
    _sync = Timer.periodic(Net.timeSyncInterval, (_) {
      final s = _state;
      if (s == null) return;
      server.broadcast(Envelope(Msg.timeUpdate, {
        'time': s.timeLeft,
        'paused': s.paused,
      }));
    });
  }

  void _stopTimer() {
    _tick?.cancel();
    _tick = null;
    _sync?.cancel();
    _sync = null;
  }

  void _onTimeout() {
    final s = _state;
    if (s == null) return;
    switch (s.phase) {
      case GamePhase.night:
        finishNight();
        break;
      case GamePhase.day:
        startVoting();
        break;
      case GamePhase.voting:
        closeVoting();
        break;
      default:
        break;
    }
  }

  void togglePause() {
    final s = _state;
    if (s == null) return;
    _state = s.copyWith(paused: !s.paused);
    server.broadcast(Envelope(Msg.timeUpdate, {
      'time': _state!.timeLeft,
      'paused': _state!.paused,
    }));
    notifyListeners();
  }

  void addTime(int seconds) {
    final s = _state;
    if (s == null) return;
    _state = s.copyWith(timeLeft: s.timeLeft + seconds);
    server.broadcast(Envelope(Msg.timeUpdate, {
      'time': _state!.timeLeft,
      'paused': _state!.paused,
    }));
    notifyListeners();
  }

  /// Досрочное завершение текущей фазы.
  void forceEndPhase() {
    final s = _state;
    if (s == null) return;
    switch (s.phase) {
      case GamePhase.night:
        finishNight();
        break;
      case GamePhase.day:
        startVoting();
        break;
      case GamePhase.voting:
        closeVoting();
        break;
      default:
        break;
    }
  }

  // ==================== рассылка фазы ====================

  void _broadcastPhase() {
    final s = _state;
    if (s == null) return;

    for (final p in s.players) {
      final canAct = _canPlayerAct(p);
      server.sendTo(
        p.id,
        Envelope(Msg.phase, {
          'phase': s.phase.wire,
          'round': s.round,
          'time': s.timeLeft,
          'paused': s.paused,
          'isAlive': p.isAlive,
          'canAct': canAct,
          'targets': canAct ? _targetsFor(p) : <Map<String, dynamic>>[],
          'prompt': _promptFor(p),
        }),
      );
    }
  }

  bool _canPlayerAct(Player p) {
    final s = _state!;
    if (!p.isAlive) return false;
    switch (s.phase) {
      case GamePhase.night:
        return (p.role?.isActiveAtNight ?? false) &&
            !s.nightActions.containsKey(p.id);
      case GamePhase.voting:
        return !s.votes.containsKey(p.id);
      default:
        return false;
    }
  }

  /// Список допустимых целей. Мафия не может выбрать своего.
  List<Map<String, dynamic>> _targetsFor(Player p) {
    final s = _state!;
    Iterable<Player> candidates = s.alive;

    if (s.phase == GamePhase.night) {
      final type = p.role?.type;
      if (type == RoleType.mafia || type == RoleType.don) {
        candidates = candidates.where((c) =>
            c.role?.type != RoleType.mafia && c.role?.type != RoleType.don);
      }
      if (type == RoleType.prostitute || type == RoleType.commissioner) {
        candidates = candidates.where((c) => c.id != p.id);
      }
      if (type == RoleType.doctor && s.lastHealedId != null) {
        candidates = candidates.where((c) => c.id != s.lastHealedId);
      }
    } else if (s.phase == GamePhase.voting) {
      candidates = candidates.where((c) => c.id != p.id);
      if (s.runoffCandidates.isNotEmpty) {
        candidates = candidates.where((c) => s.runoffCandidates.contains(c.id));
      }
    }

    return candidates
        .map((c) => {'id': c.id, 'name': c.name, 'color': c.colorHex})
        .toList();
  }

  String _promptFor(Player p) {
    final s = _state!;
    if (!p.isAlive) return 'Вы выбыли из игры';
    switch (s.phase) {
      case GamePhase.night:
        if (!(p.role?.isActiveAtNight ?? false)) return 'Спите';
        switch (p.role?.type) {
          case RoleType.mafia:
          case RoleType.don:
            return 'Кого убить этой ночью?';
          case RoleType.doctor:
            return 'Кого спасти?';
          case RoleType.commissioner:
            return 'Кого проверить?';
          case RoleType.prostitute:
            return 'Кого заблокировать?';
          case RoleType.maniac:
            return 'Кого убить?';
          default:
            return 'Спите';
        }
      case GamePhase.day:
        return 'Обсуждайте';
      case GamePhase.voting:
        return 'Кого отправляем из города?';
      default:
        return '';
    }
  }

  /// Подсказка ведущему: кого ждём.
  String hostPrompt() {
    final s = _state;
    if (s == null) return '';
    switch (s.phase) {
      case GamePhase.night:
        final waiting = s.pendingActors;
        if (waiting.isEmpty) return 'Все действия собраны. Можно завершать ночь.';
        return 'Ожидаем выбор от: ${waiting.map((p) => p.name).join(', ')}';
      case GamePhase.day:
        return 'Идёт обсуждение. Живых: ${s.alive.length}';
      case GamePhase.voting:
        final waiting = s.pendingVoters;
        if (waiting.isEmpty) return 'Все проголосовали.';
        return 'Не проголосовали: ${waiting.map((p) => p.name).join(', ')}';
      default:
        return '';
    }
  }

  // ==================== завершение ====================

  bool _checkGameOver() {
    final s = _state;
    if (s == null) return false;
    final winner = s.checkWinner();
    if (winner == null) return false;
    _endGame(winner);
    return true;
  }

  void _endGame(WinnerSide winner) {
    final s = _state;
    if (s == null) return;
    _stopTimer();

    _state = s.copyWith(
      phase: GamePhase.ended,
      winner: winner,
      endedAt: DateTime.now(),
      paused: true,
    );
    _addLog(EventType.gameOver, winner.title);
    AudioService.instance.stopAmbient();
    _playEverywhere(switch (winner) {
      WinnerSide.mafia => A.winMafia,
      WinnerSide.maniac => A.winManiac,
      WinnerSide.civilians => A.winCivilians,
      _ => A.noDeaths,
    });

    server.broadcast(Envelope(Msg.gameOver, {
      'winner': winner.name,
      'title': winner.title,
      'reveal': _state!.players
          .map((p) => {
                'name': p.name,
                'role': p.role?.name,
                'emoji': p.role?.emoji,
                'isAlive': p.isAlive,
              })
          .toList(),
    }));

    _history.saveGame(_state!);
    _session.clear();
    notifyListeners();
  }

  /// Досрочное прекращение партии ведущим.
  Future<void> abortGame() async {
    final s = _state;
    if (s == null) return;
    _endGame(WinnerSide.aborted);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await shutdown();
  }

  // ==================== служебное ====================

  void _updatePlayer(String id, Player Function(Player) update) {
    final s = _state;
    if (s == null) return;
    _state = s.copyWith(
      players: s.players.map((p) => p.id == id ? update(p) : p).toList(),
    );
  }

  void _addLog(EventType type, String text, {bool visibleToPlayers = true}) {
    final s = _state;
    if (s == null) return;
    _state = s.copyWith(log: [
      ...s.log,
      GameEvent(
        round: s.round,
        phase: s.phase,
        type: type,
        text: text,
        visibleToPlayers: visibleToPlayers,
      ),
    ]);
  }

  Future<void> shutdown() async {
    _stopTimer();
    await AudioService.instance.stopAmbient();
    await HostBackground.stop();
    await _inboxSub?.cancel();
    await _lostSub?.cancel();
    await _restoredSub?.cancel();
    await server.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    _stopTimer();
    _inboxSub?.cancel();
    _lostSub?.cancel();
    _restoredSub?.cancel();
    server.dispose();
    super.dispose();
  }
}
