import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/game_engine.dart';
import '../core/story_deck.dart';
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
import '../storage/app_prefs.dart';
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

  /// Ведущий разрешил править имена посреди партии (по умолчанию — нет).
  bool _allowRenameInGame = false;

  /// Начинать ночь автоматически, когда все прочитали роль.
  /// По умолчанию включено; значение приходит из настроек при старте.
  bool _autoStartFirstNight = true;
  bool get autoStartFirstNight => _autoStartFirstNight;

  /// Загрузить настройку из хранилища. Вызывается при создании и
  /// восстановлении партии — до первой раздачи ролей.
  Future<void> loadPrefs() async {
    _autoStartFirstNight = await AppPrefs.autoStartFirstNight();
    notifyListeners();
  }

  /// Переключить автозапуск ночи. Гейт «ночь только после 100%» это
  /// НЕ отключает: меняется лишь то, кто нажимает кнопку.
  void setAutoStartFirstNight(bool value) {
    if (_autoStartFirstNight == value) return;
    _autoStartFirstNight = value;
    AppPrefs.setAutoStartFirstNight(value);
    notifyListeners();
  }

  /// Создание партии и запуск локального сервера.
  Future<bool> createGame({
    required String name,
    required int plannedPlayers,
    required Map<RoleType, int> setup,
    bool openCards = false,
    bool introNight = false,
    bool lastWord = true,
    bool privateCheck = true,
  }) async {
    // Состав проверяем на сервере, а не только на экране: в будущем
    // сюда смогут прийти значения из пресета или из автоматизации.
    final problem = GameEngine.validateSetup(
      setup: setup,
      players: plannedPlayers,
    );
    if (problem != null) {
      _lastError = problem;
      notifyListeners();
      return false;
    }

    final code = _generateCode();
    _state = GameState(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      code: code,
      createdAt: DateTime.now(),
      plannedPlayers: plannedPlayers,
      roleSetup: Map<RoleType, int>.from(setup),
      phase: GamePhase.waiting,
      openCards: openCards,
      introNight: introNight,
      lastWord: lastWord,
      privateCheck: privateCheck,
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
      case GamePhase.rolesCheck:
        // Партия восстановлена на раздаче: роли у игроков уже есть,
        // ночь начнётся сама, когда все подтвердят.
        break;
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

    // Ловушка восстановления: приложение могло упасть между последним
    // «Понятно» и стартом ночи. Тогда все уже подтвердили, а фаза осталась
    // rolesCheck — и партия застыла бы без таймера и без кнопки. Догоняем.
    if (saved.phase == GamePhase.rolesCheck && saved.allRolesAcknowledged) {
      await loadPrefs();
      if (_autoStartFirstNight) startNight();
    }

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
        _handleRoleAck(msg);
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
    final deviceId = msg.get<String>('deviceId');

    // ВАЖНО: возврат в свой слот проверяем ПЕРВЫМ делом — раньше проверок
    // фазы и заполненности. Иначе игрок, у которого разрядился телефон
    // посреди партии, получит отказ «игра уже началась» и не вернётся
    // в собственную роль.
    // Игрок с таким именем уже есть. Два случая:
    //  * он сейчас на связи  -> имя действительно занято, отказ;
    //  * связи с ним нет     -> это он сам вернулся после перезапуска
    //                            приложения, пускаем в его же слот.
    final verdict = resolveRegister(
      name: name,
      deviceId: deviceId,
      state: s,
      isOnline: (id) => server.isOnline(id),
    );
    // Решение принимает чистая функция (её покрывают тесты); здесь —
    // только побочные эффекты: закрыть старые сокеты, отправить пакеты.
    final existingIndex = s.players.indexWhere(
        (p) => p.name.toLowerCase() == name.toLowerCase());
    if (existingIndex != -1 && verdict != RegisterVerdict.denyNameTaken) {
      final existing = s.players[existingIndex];
      // Тот же человек с другого устройства (планшет, вторая вкладка):
      // deviceId совпал — отдаём слот ему и выкидываем старый сокет.
      // Без этой проверки человек, открывший игру на планшете, получал
      // «имя занято» от собственного телефона.
      final sameDevice = verdict == RegisterVerdict.reclaimOtherDevice;
      // Возврат в собственный слот: роль, статус и голоса сохраняются.
      conn.playerId = existing.id;
      if (sameDevice) {
        _addLog(EventType.reconnect,
            '${existing.name} открыл игру на другом устройстве',
            visibleToPlayers: false);
      }
      // Старая вкладка того же игрока могла остаться открытой и продолжала
      // бы получать копии сообщений. Закрываем всё, кроме текущего сокета:
      // иначе человек видит игру в двух местах и путается, где настоящая.
      server.dropDuplicates(existing.id, conn);
      _updatePlayer(
        existing.id,
        (p) => p.copyWith(
          isConnected: true,
          // Старое сохранение могло не знать deviceId — запоминаем при
          // первом же возврате, чтобы следующая попытка опознавалась.
          deviceId: p.deviceId ?? deviceId,
        ),
      );
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
    // Решение — из resolveRegister; здесь только ответ клиенту.
    if (verdict == RegisterVerdict.denyNameTaken) {
      server.sendToConn(
          conn, Envelope(Msg.registerDenied, {'reason': DenyReason.nameTaken}));
      return;
    }
    if (verdict == RegisterVerdict.denyGameStarted) {
      server.sendToConn(conn,
          Envelope(Msg.registerDenied, {'reason': DenyReason.gameStarted}));
      return;
    }
    if (verdict == RegisterVerdict.denyGameFull) {
      server.sendToConn(
          conn, Envelope(Msg.registerDenied, {'reason': DenyReason.gameFull}));
      return;
    }

    // Цвет привязан к номеру слота, а не к «первому свободному»: тогда
    // игрок всегда возвращается в свой цвет и никто не перекрашивается
    // после исключения соседа (вопрос 5 из OPEN_QUESTIONS).
    final usedColors = s.players.map((p) => p.colorHex).toSet();
    var color = colorForSlot(s.players.length);
    // Страховка на случай переселения из старого сохранения.
    if (usedColors.contains(color)) {
      color = kPlayerColors.firstWhere(
        (c) => !usedColors.contains(c),
        orElse: () => colorForSlot(s.players.length),
      );
    }

    final player = Player(
      id: 'p${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      colorHex: color,
      deviceId: deviceId,
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
    return Envelope(Msg.sync, {
      ..._phaseFieldsFor(player),
      'alreadyActed': s.phase == GamePhase.night
          ? s.nightActions.containsKey(player.id)
          : s.votes.containsKey(player.id),
      'role': player.role?.type.name,
      'roleName': player.role?.name,
      'roleEmoji': player.role?.emoji,
      'roleDescription': player.role?.description,
      'teammates': _teammatesFor(player),
      // Клиент мог перезагрузиться до того, как нажал «Понятно».
      // Без этого флага он решил бы, что уже подтвердил, и первая ночь
      // ждала бы его вечно (гейт раздачи ролей).
      'roleAck': player.roleAcknowledged,
      'gameName': s.name,
      // Свои проверки — только комиссару и только если стол так играет.
      // Без этого после перезагрузки страницы он потерял бы всё, что узнал.
      if (s.privateCheck && player.role?.type == RoleType.commissioner)
        'checks': checksWireFor(s, player.id),
    });
  }

  void _handleNightAction(Envelope msg) {
    final s = _state!;
    if (s.phase != GamePhase.night) return;
    final playerId = msg.get<String>('playerId');
    if (playerId == null) return;
    final player = s.byId(playerId);
    if (player == null || !player.isAlive) return;
    // actsTonight учитывает ночь знакомства: ход убийцы в первую ночь
    // сервер не примет, даже если клиент его пришлёт.
    if (!s.actsTonight(player)) return;
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
      // Правила стола: игрок видит их в «Правилах» ещё в лобби и не
      // спрашивает посреди партии, откроют ли карту выбывшего.
      'rules': TableRules.toWire(s),
    }));
  }

  /// Переименование игрока ведущим.
  ///
  /// Игрок сам сменить имя после входа не может — только ведущий.
  /// Новое имя тут же уезжает владельцу и всем в лобби, поэтому
  /// расхождений между экранами не возникает.
  ///
  /// Возвращает текст ошибки или null при успехе.
  ///
  /// [allowDuringGame] — «аварийный» режим ведущего. По умолчанию имя
  /// правится только в лобби и в момент раздачи ролей: смена имени
  /// посреди партии видна всем (пакет `lobby` идёт каждому) и служит
  /// подсказкой столу, что у этого игрока ведущий что-то поправил.
  String? renamePlayer(
    String playerId,
    String rawName, {
    bool allowDuringGame = false,
  }) {
    final s = _state;
    if (s == null) return 'Партия не запущена';
    if (!allowDuringGame &&
        s.phase != GamePhase.waiting &&
        s.phase != GamePhase.rolesCheck) {
      return 'Во время партии имя менять нельзя';
    }

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
  int get roleAckCount => _state?.players.where((p) => p.roleAcknowledged).length ?? 0;

  /// Все ли ознакомились с ролями.
  bool get allRolesAcknowledged => _state?.allRolesAcknowledged ?? false;

  /// Кто ещё не подтвердил роль — ведущему показываем имена, а не только число.
  List<Player> get unacknowledgedPlayers => _state?.unacknowledged ?? const [];

  /// Партия раздала роли и ждёт, пока все прочитают.
  bool get waitingForRoleCheck =>
      _state?.phase == GamePhase.rolesCheck && !allRolesAcknowledged;

  void _handleRoleAck(Envelope msg) {
    final s = _state;
    if (s == null) return;
    final ackId = msg.get<String>('playerId');
    if (ackId == null) return;

    // Само правило — в GameEngine.applyRoleAck: чистая функция, покрыта
    // тестами, не зависит от сервера.
    final result = GameEngine.applyRoleAck(s, ackId);
    if (!result.accepted) return; // уже подтверждено либо роли ещё нет

    final name = s.nameOf(ackId);
    _state = result.state!;
    _addLog(EventType.info, '$name прочитал роль', visibleToPlayers: false);
    _persist();
    notifyListeners();

    // Гейт первой ночи (вопрос 2 из OPEN_QUESTIONS): ночь начинается сама,
    // как только последний подтвердил. Ведущему не нужно ничего нажимать
    // и невозможно случайно начать ночь «мимо» ожидающих.
    if (GameEngine.canStartNight(_state!) && _autoStartFirstNight) {
      _addLog(EventType.info, 'Все ознакомились с ролями — начинаем ночь');
      startNight();
      return;
    }
    if (GameEngine.canStartNight(_state!)) {
      // Настройка «не стартовать автоматически»: ведущий сам нажмёт
      // «Начать ночь». Гейт при этом не снят — просто ждём ведущего.
      _addLog(EventType.info, 'Все прочитали роль, ждём ведущего',
          visibleToPlayers: false);
    }
    _broadcastLobby();
  }

  /// Аварийный запуск ночи, когда кто-то так и не подтвердил роль
  /// (отошёл, разрядился телефон). Ведущий берёт это решение на себя.
  void skipRoleCheck() {
    final s = _state;
    if (s == null || s.phase != GamePhase.rolesCheck) return;
    final missing = GameEngine.pendingRoleNames(s).join(', ');
    _addLog(
      EventType.info,
      missing.isEmpty
          ? 'Ведущий начал первую ночь'
          : 'Ведущий начал ночь, не дождавшись: $missing',
      visibleToPlayers: false,
    );
    startNight();
  }

  /// Повторно показать игроку его роль (вопрос 4 из OPEN_QUESTIONS).
  ///
  /// Сценарий: человек случайно нажал «Понятно», не прочитав, или вернулся
  /// из фона уже после раздачи. Отправляем тот же пакет, что и при раздаче,
  /// и снимаем отметку «прочитал», чтобы экран-предупреждение показался
  /// снова — иначе роль молча всплывёт поверх стола.
  String? reshareRole(String playerId) {
    final s = _state;
    if (s == null) return 'Партия не запущена';
    final p = s.byId(playerId);
    if (p == null) return 'Игрок не найден';
    if (p.role == null) return 'Роли ещё не розданы';
    if (!server.isOnline(p.id)) return 'Игрок не на связи';

    _updatePlayer(p.id, (x) => x.copyWith(roleAcknowledged: false));
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
    _addLog(EventType.info, '${p.name} показана роль повторно',
        visibleToPlayers: false);
    _broadcastLobby();
    _persist();
    notifyListeners();
    return null;
  }

  /// Разрешить/запретить переименование во время партии.
  void setAllowRenameInGame(bool value) {
    if (_allowRenameInGame == value) return;
    _allowRenameInGame = value;
    notifyListeners();
  }

  bool get allowRenameInGame => _allowRenameInGame;

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

  /// Старт партии: раздача ролей.
  ///
  /// Первая ночь НЕ начинается сразу: партия переходит в фазу [rolesCheck],
  /// пока каждый игрок не нажмёт «Понятно» на своей карте. Раздать роль
  /// и тут же увести стол в ночь — значит потерять первый ход половины
  /// игроков, которые ещё читают памятку.
  void startGame() {
    final s = _state;
    if (s == null || s.players.isEmpty) return;

    final withRoles = GameEngine.assignRoles(
      players: s.players,
      setup: s.roleSetup,
      random: _rnd,
    );

    _state = s.copyWith(
      players: withRoles,
      round: 0,
      phase: GamePhase.rolesCheck,
      paused: true,
      timeLeft: 0,
    );

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
    // В лог, а значит и в протокол партии: через месяц никто не вспомнит,
    // с открытой ли картой играли, а спор «так не договаривались» будет.
    _addLog(EventType.info,
        'Правила стола: ${TableRules.describe(_state!).join('; ')}');
    _persist();
    _playEverywhere(A.rolesDealt);
    _broadcastPhase();
    notifyListeners();
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
      clearLastWord: true,
    );
    _state = _state!.copyWith(timeLeft: _state!.nightDuration);

    _addLog(
      EventType.phaseStart,
      _state!.isIntroNight
          ? 'Ночь ${_state!.round} — знакомство'
          : 'Ночь ${_state!.round}',
    );
    HostBackground.update(
        title: 'Ночь ${_state!.round} · ${s.name}',
        text: 'Живых ${_state!.alive.length} · сервер работает');
    _persist();
    _playEverywhere(A.nightFalls);
    _ambient(A.ambNight);
    _broadcastPhase();
    _startTimer();
    // «Город засыпает» — на входе в первую ночь. Раньше карточку
    // выбирали только утром, и она показывалась после ночи, а не до.
    if (_state!.round == 1) _maybeShowStory();
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

    // Проверка комиссара: запоминаем всегда (нужна для sync), а самому
    // комиссару отправляем ниже — только если стол так играет.
    final check = checkRecordFor(s, outcome);

    _state = s.copyWith(
      players: players,
      lastHealedId: outcome.healedId,
      clearLastHealed: outcome.healedId == null,
      clearPendingNight: true,
      checks: check == null ? null : [...s.checks, check],
    );
    _persist();

    // Лог: публичное — только факт смерти. Проверка комиссара скрыта.
    if (s.isIntroNight) {
      _addLog(EventType.info, 'Ночь ${s.round}: знакомство, все живы');
    } else if (outcome.killedIds.isEmpty) {
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
        '${outcome.checkResultIsMafia == true ? 'МАФИЯ' : 'не мафия'}',
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
      // Классика: при выбывании карта открывается. Настройка — на столе
      // ведущего, по умолчанию закрыта.
      if (s.openCards)
        'revealed': {
          for (final id in outcome.killedIds)
            id: s.byId(id)?.role?.type.name,
        },
    }));

    // Персональные уведомления погибшим.
    for (final id in outcome.killedIds) {
      server.sendTo(
        id,
        Envelope(Msg.eliminated, {'reason': 'kill', 'round': s.round}),
      );
    }

    // Результат проверки — лично комиссару. Пакет уходит только на его
    // сокет; клиент показывает его внутри «Моя роль», а не баннером:
    // всплывающая строка «Вася — мафия» на столе выдала бы и роль, и итог.
    if (check != null && s.privateCheck) {
      server.sendTo(
        check.commissionerId,
        Envelope(Msg.checkResult, {
          'round': check.round,
          'name': s.nameOf(check.targetId),
          'isMafia': check.isMafia,
        }),
      );
    }

    // Список стола у игроков: кто жив, кто выбыл (счётчик «живых N из M»).
    _broadcastLobby();

    // Сюжетная карточка момента: первая смерть в партии, тихая ночь
    // или «мафия сравнялась». Показ не блокирует фазу: если ведущий
    // не нажмёт «Дальше», день начнётся сам по таймеру.
    // Ночь знакомства «тихой» не считаем: в ней никто и не мог погибнуть,
    // а карточка намекает, что кого-то спасли.
    _maybeShowStory(
      quietNight: outcome.killedIds.isEmpty && !s.isIntroNight,
    );

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
      clearLastWord: true,
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
      clearLastWord: true,
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
      // Счётчик «город не может решить»: две ничьи подряд включают
      // сюжетную карточку тупика. Сбрасывается, как только кого-то выгнали.
      _state = s.copyWith(noDeathsStreak: s.noDeathsStreak + 1);
      server.broadcast(
          Envelope(Msg.voteResult, {'eliminated': null, 'tie': true}));
      _maybeShowStory();
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
    // Город всё-таки решил — счётчик ничьих обнуляется.
    _state = s.copyWith(players: players, noDeathsStreak: 0);
    _persist();

    _addLog(EventType.elimination,
        'День ${s.round}: голосованием выбыл ${s.nameOf(playerId)}');

    _playEverywhere(A.eliminated);

    server.broadcast(Envelope(Msg.voteResult, {
      'eliminated': playerId,
      'eliminatedName': s.nameOf(playerId),
      'tie': false,
      // Открытая карта: роль выбывшего видна всем сразу.
      if (s.openCards)
        'revealedRole': s.byId(playerId)?.role?.name,
    }));
    server.sendTo(playerId,
        Envelope(Msg.eliminated, {'reason': 'vote', 'round': s.round}));
    _broadcastLobby();

    _maybeShowStory(exile: true);

    if (_checkGameOver()) return;
    // Последнее слово — только если партия продолжается (см.
    // shouldGiveLastWord): после финала речь уже никому не нужна.
    if (shouldGiveLastWord(_state!)) {
      _startLastWord(playerId);
      return;
    }
    startNight();
  }

  /// Последнее слово выбывшего: короткая фаза с таймером перед ночью.
  ///
  /// Отдельной фазы в [GamePhase] нет намеренно: это тот же день, просто
  /// говорит один человек. Никто не ходит и не голосует, поэтому старый
  /// клиент из кэша покажет обычный «День» и ничего не сломает.
  void _startLastWord(String playerId) {
    final s = _state;
    if (s == null) return;
    _state = s.copyWith(
      phase: GamePhase.day,
      lastWordId: playerId,
      paused: false,
      timeLeft: Rules.lastWordSeconds,
      votes: <String, String?>{},
      runoffCandidates: const [],
      awaitingVoteConfirm: false,
    );
    _addLog(EventType.info, 'Последнее слово: ${s.nameOf(playerId)}');
    HostBackground.update(
        title: 'Последнее слово · ${s.name}',
        text: '${s.nameOf(playerId)} · сервер работает');
    _persist();
    _ambient(A.ambDay);
    _broadcastPhase();
    _startTimer();
    notifyListeners();
  }

  /// Конец последнего слова: по таймеру или кнопкой ведущего.
  void endLastWord() {
    final s = _state;
    if (s == null || s.lastWordId == null) return;
    _stopTimer();
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
    // Последнее слово идёт в фазе «день», но заканчивается ночью,
    // а не голосованием — перехватываем до общего переключателя.
    if (s.lastWordId != null) {
      endLastWord();
      return;
    }
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
    if (s.lastWordId != null) {
      endLastWord();
      return;
    }
    switch (s.phase) {
      case GamePhase.rolesCheck:
        skipRoleCheck();
        break;
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
      server.sendTo(p.id, Envelope(Msg.phase, _phaseFieldsFor(p)));
    }
  }

  /// Общая часть пакетов `phase` и `sync`.
  ///
  /// Раньше оба пакета собирались по отдельности и разошлись: в `sync`
  /// не было подсказки, и после переподключения игрок видел текст
  /// прошлой фазы. Теперь новое поле невозможно добавить «только в один».
  Map<String, dynamic> _phaseFieldsFor(Player p) {
    final s = _state!;
    final canAct = _canPlayerAct(p);
    final speaker = s.byId(s.lastWordId);
    return {
      'phase': s.phase.wire,
      'round': s.round,
      'time': s.timeLeft,
      'paused': s.paused,
      'isAlive': p.isAlive,
      'canAct': canAct,
      'targets': canAct ? _targetsFor(p) : <Map<String, dynamic>>[],
      'prompt': _promptFor(p),
      // Общая картина стола: «живых 7 из 10». За столом это видно
      // глазами, а человек, уткнувшийся в телефон, теряет счёт.
      'alive': s.alive.length,
      'total': s.players.length,
      // Ночь знакомства: клиент объясняет, почему у убийц нет целей.
      'intro': s.isIntroNight,
      // Кто говорит последнее слово (null — никто).
      'lastWord': speaker == null
          ? null
          : {'id': speaker.id, 'name': speaker.name},
    };
  }

  bool _canPlayerAct(Player p) {
    final s = _state!;
    if (!p.isAlive) return false;
    switch (s.phase) {
      case GamePhase.night:
        return s.actsTonight(p) && !s.nightActions.containsKey(p.id);
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
      // Себя не выбирают: проститутка, комиссар и доктор (классика —
      // доктор себя не лечит, см. resolveNight).
      if (type == RoleType.prostitute ||
          type == RoleType.commissioner ||
          type == RoleType.doctor) {
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
    // Последнее слово — раньше проверки «выбыл»: говорящий уже выбыл,
    // но именно ему нужно знать, что время пошло.
    if (s.lastWordId != null) {
      return p.id == s.lastWordId
          ? 'Ваше последнее слово'
          : 'Последнее слово: ${s.nameOf(s.lastWordId)}';
    }
    if (!p.isAlive) return 'Вы выбыли из игры';
    switch (s.phase) {
      case GamePhase.rolesCheck:
        return 'Прочитайте свою роль';
      case GamePhase.night:
        // В ночь знакомства мафия тоже получает «Спите»: подсказка
        // крупно показана на экране, и особый текст («запомните своих»)
        // выдал бы роль любому, кто глянул через плечо. Союзников мафия
        // видит на своей карте роли, а вслух знакомство ведёт ведущий.
        if (!s.actsTonight(p)) return 'Спите';
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
      case GamePhase.rolesCheck:
        final waiting = s.unacknowledged;
        if (waiting.isEmpty) return 'Все прочитали роль — начинаем ночь.';
        return 'Роли изучают (${s.players.length - waiting.length} '
            'из ${s.players.length}): ${waiting.map((p) => p.name).join(', ')}';
      case GamePhase.night:
        final waiting = s.pendingActors;
        if (s.isIntroNight) {
          return waiting.isEmpty
              ? 'Ночь знакомства: мафия узнала своих. Можно будить город — '
                  'сегодня никто не погибает.'
              : 'Ночь знакомства: мафия узнаёт своих, комиссар проверяет. '
                  'Ждём: ${waiting.map((p) => p.name).join(', ')}';
        }
        if (waiting.isEmpty) return 'Все действия собраны. Можно завершать ночь.';
        return 'Ожидаем выбор от: ${waiting.map((p) => p.name).join(', ')}';
      case GamePhase.day:
        if (s.lastWordId != null) {
          return 'Последнее слово: ${s.nameOf(s.lastWordId)}. '
              'Договорил раньше — нажмите «Слово сказано».';
        }
        return 'Идёт обсуждение. Живых: ${s.alive.length}';
      case GamePhase.voting:
        final waiting = s.pendingVoters;
        if (waiting.isEmpty) return 'Все проголосовали.';
        return 'Не проголосовали: ${waiting.map((p) => p.name).join(', ')}';
      default:
        return '';
    }
  }

  // ==================== сюжетные карточки ====================

  /// Показать одну уместную карточку. Самая приоритетная из подходящих,
  /// и только если её ещё не показывали в этой партии.
  void _maybeShowStory({bool quietNight = false, bool exile = false}) {
    final s = _state;
    if (s == null) return;
    if (s.phase == GamePhase.ended) return;
    final card = StoryDeck.bestFor(
      s,
      seenIds: s.storySeen.toSet(),
      noDeathsStreak: s.noDeathsStreak,
      quietNight: quietNight,
      exile: exile,
    );
    if (card == null) return;
    _state = s.copyWith(
      storyId: card.id,
      storySeen: [...s.storySeen, card.id],
    );
    // Событие в лог: без него в протоколе не будет видно, что показывали.
    _addLog(EventType.info, 'Кадр: ${card.title}',
        visibleToPlayers: false);
    _broadcastStory(card);
    notifyListeners();
  }

  /// Показать карточку вручную — кнопкой ведущего. Полезно, когда
  /// хочется подчеркнуть момент, а условие не совпало.
  void showStory(String id) {
    final s = _state;
    if (s == null) return;
    final card = StoryDeck.byId(id);
    if (card == null) return;
    _state = s.copyWith(
      storyId: card.id,
      storySeen: s.storySeen.contains(card.id)
          ? s.storySeen
          : [...s.storySeen, card.id],
    );
    _addLog(EventType.info, 'Кадр: ${card.title}', visibleToPlayers: false);
    // До 1.2.0 ручной показ менял только экран ведущего: пакет игрокам
    // не уходил, и «показать всем» показывало карточку одному человеку.
    _broadcastStory(card);
    notifyListeners();
  }

  /// Убрать карточку с экранов. Игрок видит её, пока ведущий не закроет.
  void dismissStory() {
    final s = _state;
    if (s == null || s.storyId == null) return;
    _state = s.copyWith(clearStory: true);
    server.broadcast(Envelope(Msg.storyDismiss, const {}));
    notifyListeners();
  }

  /// Разослать карточку всем: и ведущему (для превью), и игрокам.
  /// Игроку уходит только то, что можно показать: заголовок, фраза,
  /// подпись и путь к картинке. Никакой информации о ролях.
  void _broadcastStory(StoryCard card) {
    server.broadcast(Envelope(Msg.story, {
      'id': card.id,
      'title': card.title,
      'line': card.line,
      'caption': card.caption,
      'image': card.image,
      'phase': _state?.phase.wire,
    }));
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
