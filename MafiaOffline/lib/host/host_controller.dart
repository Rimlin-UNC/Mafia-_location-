import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/game_engine.dart';
import '../core/lobby_plan.dart';
import '../core/story_deck.dart';
import '../models/game_event.dart';
import '../models/game_phase.dart';
import '../models/game_state.dart';
import '../models/player.dart';
import '../models/role.dart';
import '../core/assets.dart';
import '../core/bot_engine.dart';
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

  /// Когда боты должны сделать очередной ход/голос или высказаться днём.
  /// null — в текущей фазе делать нечего. Время не сохраняется: после
  /// восстановления партии пауза назначается заново.
  DateTime? _botsAt;
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
    bool piercingShot = false,
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
      piercingShot: piercingShot,
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
      _lastError = _explainServerError(e);
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

  /// Понятная причина, почему сервер не поднялся.
  ///
  /// Раньше ведущий видел `SocketException: Address already in use (OS
  /// Error: 98), errno = 98` — строка из недр системы, по которой нельзя
  /// принять решение. Самая частая причина на телефоне: прошлая партия не
  /// закрылась штатно (свернули приложение, не нажали «Завершить»), и порт
  /// 8088 остался занят. Вторая по частоте — та же игра уже открыта вторым
  /// окном. Обе лечатся понятным действием, поэтому и текст — про действие.
  String _explainServerError(Object e) {
    final text = e.toString();
    if (text.contains('Address already in use') ||
        text.contains('errno = 98') ||
        text.contains('bind')) {
      return 'Порт 8088 занят. Скорее всего, игра уже запущена в другом '
          'окне приложения — закройте его и попробуйте снова. '
          'Если не помогло, перезапустите приложение.';
    }
    if (text.contains('Permission denied')) {
      return 'Система не разрешила открыть порт 8088. '
          'Проверьте, не включён ли режим экономии или блокировщик сети.';
    }
    return 'Не удалось запустить сервер: $e';
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
    // Бот не может нажать «Понятно». Если сохранение пришло из версии,
    // где флаг не выставлялся, гейт первой ночи завис бы навсегда:
    // живые уже готовы, а ждём бота, который этого не сделает.
    if (saved.phase == GamePhase.rolesCheck && saved.bots.isNotEmpty) {
      _state = saved.copyWith(
        players: saved.players
            .map((p) => p.isBot && !p.roleAcknowledged
                ? p.copyWith(roleAcknowledged: true)
                : p)
            .toList(),
      );
    }
    try {
      hostAddress = await server.start(
        gameCode: saved.code,
        gameName: saved.name,
        plannedPlayers: saved.plannedPlayers,
      );
    } catch (e) {
      _lastError = _explainServerError(e);
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
    // Боты после перезапуска приложения не должны «ждать» ведущего:
    // дедлайн их хода в сохранении не лежит, поэтому назначаем новый.
    // Флаг paused сам остановит ход до снятия паузы (см. _maybeRunBots).
    _scheduleBots();

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

  /// Разбор входящего сообщения.
  ///
  /// Всё тело обёрнуто в try/catch намеренно. Обработчик висит на широковеща­
  /// тельном потоке сервера: необработанное исключение от ОДНОГО клиента
  /// (битый JSON нужного типа, неожидаемая строка вместо числа, эмулятор
  /// WebSocket) уходило в зону ошибок потока и роняло подписку. Дальше
  /// сервер работал, а ведущий не получал уже ни одного сообщения: партия
  /// замирала, и восстановить её можно было только перезапуском.
  ///
  /// Теперь сбой одного сообщения — это только это сообщение. Пишем в лог
  /// и живём дальше.
  /// Сколько сообщений не удалось разобрать — только для ограничения
  /// записей в лог (см. [_onMessage]).
  int _badMessageCount = 0;

  void _onMessage(({ClientConn conn, Envelope msg}) event) {
    final s = _state;
    if (s == null) return;
    final msg = event.msg;
    final conn = event.conn;

    try {
      _dispatchMessage(conn, msg);
    } catch (e) {
      // В лог партии пишем первые три сбоя: они бывают при обновлении
      // клиента и полезны в разборе, но клиент, который шлёт мусор
      // пачками, не должен раздувать лог и отвлекать ведущего.
      _badMessageCount++;
      debugPrint('Mafia: сообщение ${msg.type} отклонено: $e');
      if (_badMessageCount <= 3) {
        _addLog(
          EventType.info,
          'Пропущена некорректная команда от игрока',
          visibleToPlayers: false,
        );
      }
    }
  }

  void _dispatchMessage(ClientConn conn, Envelope msg) {
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

    if (player == null || player.isBot || player.isLocal) {
      // Игрока нет — например, партия перезапущена. Слоты ботов и
      // локального игрока по сети недоступны: иначе по имени можно
      // получить чужую роль через sync.
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
      // Наблюдение свидетеля: последнее, что он видел. Как и проверки,
      // это персональная улика — сосед по столу её видеть не должен.
      if (player.role?.type == RoleType.witness && s.watchTargetId != null)
        'watch': {
          'round': s.watchRound,
          'name': s.nameOf(s.watchTargetId),
          'acted': s.watchActed == true,
        },
      // Охотник всегда видит свою метку: она переживает ночи, и «на кого
      // она стоит» — главное, что ему нельзя забыть.
      if (player.role?.type == RoleType.hunter && s.hunterMarkId != null)
        'hunterMark': {'name': s.nameOf(s.hunterMarkId)},
      // Запуганный должен понимать, почему у него нет кнопок голосования.
      if (s.isSilencedNow(player)) 'silenced': true,
    });
  }

  void _handleNightAction(Envelope msg) {
    final playerId = msg.get<String>('playerId');
    if (playerId != null) _applyNightAction(playerId, msg.get<String>('targetId'), piercing: msg.get<bool>('piercing') == true);
  }

  /// Общий путь для ночного хода из сети и для локального игрока.
  void _applyNightAction(String playerId, String? target, {bool piercing = false}) {
    final s = _state;
    if (s == null || s.phase != GamePhase.night || s.pendingNight != null) return;
    final player = s.byId(playerId);
    if (player == null || !player.isAlive || player.isBot) return;
    // actsTonight учитывает ночь знакомства: ход убийцы в первую ночь
    // сервер не примет, даже если клиент его пришлёт.
    if (!s.actsTonight(player)) return;
    if (s.nightActions.containsKey(playerId)) return; // повторно нельзя
    // Проверка цели обязательна: иначе изменённый клиент мог бы вылечить
    // себя, застрелить мафию по своей команде или выбрать мёртвого.
    final legal = GameEngine.legalTargetsFor(s, player)
        .map((p) => p.id)
        .toSet();
    if (target != null && !legal.contains(target)) return;

    final actions = Map<String, String?>.from(s.nightActions);
    actions[playerId] = target;
    _state = s.copyWith(nightActions: actions,
      piercingRequests: [...s.piercingRequests,
        if (piercing && target != null && s.canRequestPiercing(player)) playerId],
    );

    server.sendTo(playerId, Envelope(Msg.ack, {'accepted': true}));
    _persist();
    // Комиссар видит ответ сразу, как выбрал игрока. Вызываем после
    // каждого хода, а не только комиссарского: если он сходил раньше
    // проститутки, ответ приходит в момент её хода.
    _deliverCheck();
    // Свидетель — наоборот: ждёт, пока объект наблюдения сходит.
    _deliverWatch();
    notifyListeners();

    _afterHumanAction();
  }

  /// Ход локального игрока (ведущий сам играет против ботов или людей).
  void submitLocalNightAction(String? targetId, {bool piercing = false}) {
    final local = _state?.localPlayer;
    if (local != null) _applyNightAction(local.id, targetId, piercing: piercing);
  }

  void _afterHumanAction() {
    final s = _state;
    if (s == null || s.phase != GamePhase.night) return;
    if (s.humanNightActionsIn) _fillBotNightActions();
    if (_state!.allNightActionsIn) finishNight();
  }

  /// Сообщить комиссару результат проверки, как только он известен.
  ///
  /// Вызывается после каждого ночного хода, при закрытии ночи и перед
  /// оглашением. Безопасно вызывать сколько угодно раз: за одну ночь
  /// комиссар получает ровно один ответ (см. [checkKnownNow]).
  ///
  /// В журнал проверка пишется всегда — он нужен для `sync` и протокола.
  /// Пакет комиссару уходит, только если стол так играет.
  void _deliverCheck() {
    final s = _state;
    if (s == null) return;
    final check = checkKnownNow(s);
    if (check == null) return;
    final already = s.checks.any((c) =>
        c.round == check.round && c.commissionerId == check.commissionerId);
    if (already) return;

    _state = s.copyWith(checks: [...s.checks, check]);
    _persist();
    if (s.privateCheck) {
      // Только на сокет комиссара. Клиент показывает ответ на ночном
      // экране до рассвета, а потом — только внутри «Моя роль».
      server.sendTo(
        check.commissionerId,
        Envelope(Msg.checkResult, checkWire(s, check)),
      );
    }
  }

  /// Свидетель узнаёт итог своего наблюдения.
  ///
  /// Отправляем не сразу, как он выбрал (в отличие от комиссара): наблюдение
  /// целиком зависит от того, сходил ли объект, а он мог сходить позже.
  /// Поэтому вызов — и на каждом ночном ходе, и при закрытии ночи; сокет
  /// получает только ИТОГ, и повторной отправки не будет, пока раунд
  /// наблюдения не сменится.
  void _deliverWatch() {
    final s = _state;
    if (s == null || s.phase != GamePhase.night) return;
    final w = s.witness;
    if (w == null) return;
    final target = s.nightActions[w.id];
    if (target == null) return;
    // Пока объект не сходил, ответ был бы «не выходил» — и мог бы
    // оказаться неправдой. Ждём его хода так же, как комиссар ждёт
    // проститутку; закрытие ночи снимет ожидание принудительно.
    final watched = s.byId(target);
    if (watched != null &&
        s.actsTonight(watched) &&
        !s.nightActions.containsKey(target)) {
      return;
    }
    final acted = watched != null && s.actsTonight(watched);
    if (s.watchRound == s.round && s.watchTargetId == target) {
      if (s.watchActed == acted) return; // уже сообщили то же самое
    }
    _state = s.copyWith(
      watchTargetId: target,
      watchActed: acted,
      watchRound: s.round,
    );
    _persist();
    server.sendTo(
      w.id,
      Envelope(Msg.watchResult, {
        'round': s.round,
        'name': s.nameOf(target),
        'acted': acted,
      }),
    );
  }

  void _handleVote(Envelope msg) {
    final voterId = msg.get<String>('playerId');
    if (voterId != null) _applyVote(voterId, msg.get<String>('targetId'));
  }

  void _applyVote(String voterId, String? target) {
    final s = _state;
    if (s == null || s.phase != GamePhase.voting) return;
    final voter = s.byId(voterId);
    if (voter == null || !voter.isAlive || voter.isBot) return;
    // Запуганный шантажистом в этот день не голосует. Проверка нужна и
    // здесь: клиент мог открыть экран до шантажа и нажать кнопку после.
    if (s.isSilencedNow(voter)) return;
    // В повторном голосовании обвиняемый не голосует за самого себя.
    if (s.isVerdictVote && voterId == s.verdictId) return;
    if (s.votes.containsKey(voterId)) return; // один голос за тур

    final legal = GameEngine.legalTargetsFor(s, voter)
        .map((p) => p.id)
        .toSet();
    // Некорректная цель от старого/изменённого клиента считается
    // воздержанием: человека нельзя лишать голоса целиком.
    if (target != null && !legal.contains(target)) target = null;

    final votes = Map<String, String?>.from(s.votes);
    votes[voterId] = target;
    _state = s.copyWith(votes: votes);

    server.sendTo(voterId, Envelope(Msg.ack, {'accepted': true}));
    _persist();
    notifyListeners();

    if (_state!.humanVotesIn) _fillBotVotes();
    if (_state!.allVotesIn) closeVoting();
  }

  /// Голос локального игрока. null — «воздержаться» или «оставить»
  /// в повторном голосовании, тот же смысл, что и у обычного клиента.
  void submitLocalVote(String? targetId) {
    final local = _state?.localPlayer;
    if (local != null) _applyVote(local.id, targetId);
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

  // ==================== боты и локальный игрок ====================

  int get botCount => _state?.bots.length ?? 0;
  bool get hasLocalPlayer => _state?.localPlayer != null;

  /// План лобби для экрана: сколько мест, сколько ботов, можно ли стартовать.
  /// Правило живёт в [LobbyPlan], чтобы его проверял тест без виджетов.
  LobbyPlan? get lobbyPlan {
    final s = _state;
    if (s == null) return null;
    return LobbyPlan(
      players: s.players.length,
      planned: s.plannedPlayers,
      bots: s.bots.length,
    );
  }

  /// Добавить ботов в лобби. Возвращает, сколько добавлено фактически
  /// (при заполненном столе — меньше запрошенного или ноль).
  int addBots({int count = 1}) {
    final s = _state;
    if (s == null || s.phase != GamePhase.waiting) return 0;
    final before = s.players.length;
    // Размер стола — тоже граница: «+1 бот» не должен превращать
    // партию на 8 в партию на 9, если ведущий так не задумывал.
    final room =
        botRoomFor(players: s.players.length, planned: s.plannedPlayers);
    if (count > room) count = room;
    _state = BotEngine.addBots(s, count);
    final added = _state!.players.length - before;
    if (added > 0) {
      _addLog(EventType.info,
          'Ведущий добавил ботов: $added (всего ${_state!.bots.length})',
          visibleToPlayers: false);
      _broadcastLobby();
      _persist();
      notifyListeners();
    }
    return added;
  }

  int fillBotsTo(int target) {
    final s = _state;
    if (s == null) return 0;
    final bounded = target < 0
        ? 0
        : (target > Rules.maxPlayers ? Rules.maxPlayers : target);
    return addBots(count: bounded - s.players.length);
  }

  /// Добавить в слот ведущего его собственного игрока. Роль будет
  /// показана на экране ведущего; WebSocket для этого не нужен.
  String? addLocalPlayer({String name = 'Ведущий'}) {
    var st = _state;
    if (st == null) return 'Партия не запущена';
    if (st.phase != GamePhase.waiting) return 'Игрок уже не может войти в лобби';
    if (st.localPlayer != null) return null;

    // Стол мог быть занят ботами под завязку: человек нажал «+1 бот»,
    // а потом решил сыграть сам. Освобождаем место за счёт бота, иначе
    // «Играть одному» упиралось бы в «нет свободного места» на ровном
    // месте — и партия из одних автоматов оставалась единственным выходом.
    //
    // Работаем с локальной копией явно не-nullable: тело цикла меняет
    // состояние, и промоушен `_state` внутри while анализатор не держит.
    var players = st.players;
    var planned = st.plannedPlayers;
    while (botRoomFor(players: players.length, planned: planned) == 0 &&
        players.any((p) => p.isBot)) {
      final lastBot = players.lastWhere((p) => p.isBot);
      players = players.where((p) => p.id != lastBot.id).toList();
    }
    if (botRoomFor(players: players.length, planned: planned) == 0) {
      return 'В лобби нет свободного места';
    }
    if (players.length != st.players.length) {
      st = st.copyWith(players: players);
    }

    final base = name.trim().isEmpty ? 'Ведущий' : name.trim();
    final used = st.players.map((p) => p.name.toLowerCase()).toSet();
    var unique = base;
    var suffix = 2;
    while (used.contains(unique.toLowerCase())) {
      unique = '$base $suffix';
      suffix++;
    }
    final usedColors = st.players.map((p) => p.colorHex).toSet();
    // Снимок длины — ДО возможного изменения состава. Иначе замыкание
    // orElse захватывает переменную, которую анализатор уже не считает
    // non-nullable, и падает с unchecked_use_of_nullable_value.
    final seatCount = st.players.length;
    var color = colorForSlot(seatCount);
    if (usedColors.contains(color)) {
      color = kPlayerColors.firstWhere(
        (c) => !usedColors.contains(c),
        orElse: () => colorForSlot(seatCount),
      );
    }

    var index = 1;
    while (st.players.any((p) => p.id == 'local-$index')) {
      index++;
    }
    _state = st.copyWith(players: [
      ...st.players,
      Player(
        id: 'local-$index',
        name: unique,
        colorHex: color,
        isConnected: true,
        isLocal: true,
      ),
    ]);
    _addLog(EventType.info, 'Ведущий тоже играет: $unique',
        visibleToPlayers: false);
    _broadcastLobby();
    _persist();
    notifyListeners();
    return null;
  }

  /// Путь «играть одному»: локальный игрок + боты до выбранного размера
  /// стола. Существующие подключения людей не заменяются ботами.
  String? startSolo() {
    final s = _state;
    if (s == null) return 'Партия не запущена';
    final error = addLocalPlayer();
    if (error != null) return error;
    fillBotsTo(s.plannedPlayers > 0 ? s.plannedPlayers : Rules.minPlayers);
    return null;
  }

  void acknowledgeLocalRole() {
    final local = _state?.localPlayer;
    if (local != null) _applyRoleAck(local.id);
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
    final ackId = msg.get<String>('playerId');
    if (ackId != null) _applyRoleAck(ackId);
  }

  void _applyRoleAck(String ackId) {
    final s = _state;
    if (s == null) return;

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
    // У бота нет экрана: снять у него «роль прочитана» значило бы навсегда
    // остановить гейт первой ночи — вернуть флаг больше некому.
    if (p.isBot) return 'Бот не читает роль на экране';
    if (!p.isLocal && !server.isOnline(p.id)) return 'Игрок не на связи';

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
    // Удалили того, о ком шла речь (последнее слово или повторное
    // голосование), — решать больше нечего, наступает ночь.
    final wasAccused = playerId == s.lastWordId || playerId == s.verdictId;
    _state = s.copyWith(
      players: s.players.where((p) => p.id != playerId).toList(),
    );
    _broadcastLobby();
    if (wasAccused) {
      _stopTimer();
      if (_checkGameOver()) return;
      startNight();
      return;
    }
    _persist();
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
    // Партия из одних ботов — не игра: смотреть, как автоматы голосуют
    // друг за друга, ведущему неинтересно и выглядит это как поломка.
    // Экран лобби такую кнопку и не включает, но проверка нужна и здесь:
    // старт зовут и другие места (восстановление, автостарт).
    if (s.humans.isEmpty) {
      _lastError = 'За столом нет живых игроков. Нажмите «Играть одному»';
      _addLog(EventType.info,
          'Старт отменён: за столом только боты. Нажмите «Играть одному».');
      notifyListeners();
      return;
    }

    // Недостающих до минимально играбельного стола добавляем только
    // при старте: в лобби человек всё ещё может подключиться и занять слот.
    if (s.players.length < Rules.minPlayers) {
      fillBotsTo(Rules.minPlayers);
    }
    final current = _state!;
    final withRoles = GameEngine.assignRoles(
      players: current.players,
      setup: current.roleSetup,
      random: _rnd,
    ).map((p) => p.copyWith(
      roleAcknowledged: p.isBot ? true : p.roleAcknowledged,
    )).toList();

    _state = current.copyWith(
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

    _addLog(EventType.info,
        'Игра началась. Игроков: ${withRoles.length} '
        '(людей: ${current.humans.length}, ботов: ${current.bots.length})');
    // В лог, а значит и в протокол партии: через месяц никто не вспомнит,
    // с открытой ли картой играли, а спор «так не договаривались» будет.
    _addLog(EventType.info,
        'Правила стола: ${TableRules.describe(_state!).join('; ')}');
    _persist();
    _playEverywhere(A.rolesDealt);
    _broadcastPhase();
    notifyListeners();
  }

  /// Союзники на карточке роли. С 1.12.0 это ВСЯ мафия, включая
  /// шантажиста: он не стреляет, но он свой, и команда обязана его знать.
  List<Map<String, dynamic>> _teammatesFor(Player p) {
    final s = _state!;
    final role = p.role;
    if (role == null || role.side != Side.mafia) return const [];
    return s.players
        .where((m) => m.id != p.id && m.role?.side == Side.mafia)
        .map((m) => {
              'name': m.name,
              'isDon': m.role?.type == RoleType.don,
              'isAlive': m.isAlive,
            })
        .toList();
  }

  // ==================== автоматические ходы ботов ====================

  void _scheduleBots() {
    final s = _state;
    if (s == null || !s.hasBots) {
      _botsAt = null;
      return;
    }
    final seconds = Rules.botActMinSeconds +
        _rnd.nextInt(Rules.botActMaxSeconds - Rules.botActMinSeconds + 1);
    _botsAt = DateTime.now().add(Duration(seconds: seconds));
  }

  void _maybeRunBots() {
    final s = _state;
    if (s == null || s.paused || !s.hasBots || _botsAt == null) return;
    if (DateTime.now().isBefore(_botsAt!)) return;
    _botsAt = null;

    switch (s.phase) {
      case GamePhase.night:
        _fillBotNightActions();
        if (_state!.allNightActionsIn) finishNight();
        break;
      case GamePhase.voting:
        _fillBotVotes();
        if (_state!.allVotesIn) closeVoting();
        break;
      case GamePhase.day:
        _emitBotSpeech();
        break;
      default:
        break;
    }
  }

  void _fillBotNightActions() {
    final s = _state;
    if (s == null || s.phase != GamePhase.night) return;
    final additions = BotEngine.nightActionsFor(s, _rnd);
    if (additions.isEmpty) return;
    _state = s.copyWith(nightActions: {...s.nightActions, ...additions},
      piercingRequests: [...s.piercingRequests, ...BotEngine.piercingRequestsFor(s, additions, _rnd)],
    );
    _deliverCheck();
    _persist();
    notifyListeners();
  }

  void _fillBotVotes() {
    final s = _state;
    if (s == null || s.phase != GamePhase.voting) return;
    final additions = BotEngine.votesFor(s, _rnd);
    if (additions.isEmpty) return;
    _state = s.copyWith(votes: {...s.votes, ...additions});
    _persist();
    notifyListeners();
  }

  void _emitBotSpeech() {
    final s = _state;
    if (s == null || s.phase != GamePhase.day || !s.hasBots) return;
    if (s.lastBotSpeechRound == s.round) return;
    final lines = BotEngine.dayLinesFor(s, _rnd);
    for (final line in lines) {
      final text = '${s.nameOf(line.playerId)}: ${line.text}';
      _addLog(EventType.info, text);
      server.broadcast(Envelope(Msg.botSpeech, {
        'playerId': line.playerId,
        'name': s.nameOf(line.playerId),
        'text': line.text,
        'round': s.round,
      }));
    }
    _state = _state!.copyWith(lastBotSpeechRound: s.round);
    _persist();
    notifyListeners();
  }

  // ==================== фазы ====================

  void startNight() {
    final s = _state;
    if (s == null) return;

    _state = s.copyWith(
      phase: GamePhase.night,
      round: s.round + 1,
      piercingRequests: const [],
      nightActions: <String, String?>{},
      votes: <String, String?>{},
      runoffCandidates: const [],
      awaitingVoteConfirm: false,
      paused: false,
      clearPendingNight: true,
      clearLastWord: true,
      clearVerdict: true,
      // Запугивание и наблюдение живут ровно один день. Охотник свою
      // метку НЕ теряет: она действует, пока он её не сменит.
      clearSilenced: true,
      clearWatch: true,
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
    _scheduleBots();
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
    _botsAt = null;
    // Даже при ручном завершении ночи боты должны успеть сходить:
    // иначе кнопка ведущего «Далее» отнимала бы у города их ходы.
    _fillBotNightActions();
    final current = _state!;

    final outcome = GameEngine.resolveNight(current, random: _rnd);
    _state = current.copyWith(pendingNight: outcome, paused: true);
    _persist();
    // Ночь закрыта: если комиссар ждал хода проститутки, а она так
    // и не сходила, ответ уходит ему сейчас — до рассвета. Свидетель
    // получает свой факт тогда же: объект мог вообще не ходить, и «не
    // выходил» — это законный ответ, а не отсутствие ответа.
    _deliverCheck();
    _deliverWatch();
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
    if (_state?.pendingNight == null) return;
    // Обычно комиссар получил ответ ещё ночью (см. _deliverCheck).
    // Здесь — страховка: например, партию восстановили после перезапуска
    // уже на сводке ночи. Повторно ответ не уйдёт.
    _deliverCheck();
    _deliverWatch();

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

    // Запугивание живёт до конца наступающего дня: раунд остаётся тем же,
    // что и у ночи, поэтому снять его можно только явно на старте
    // следующей ночи (см. startNight).
    final hunter = s.hunter;
    final hunterDied =
        hunter != null && outcome.killedIds.contains(hunter.id);
    final mark =
        outcome.hunterMarkId ?? (hunterDied ? null : s.hunterMarkId);
    _state = s.copyWith(
      players: players,
      piercingSpent: s.piercingSpent || outcome.piercingUsed,
      lastHealedId: outcome.healedId,
      clearLastHealed: outcome.healedId == null,
      lastGuardedId: outcome.guardedId,
      clearLastGuarded: outcome.guardedId == null,
      clearPendingNight: true,
      silencedId: outcome.silencedId,
      silencedRound: s.round,
      clearSilenced: outcome.silencedId == null,
      watchTargetId: outcome.watchedId,
      watchActed: outcome.watchedActed,
      watchRound: s.round,
      clearWatch: outcome.watchedId == null,
      // Метка охотника переживает ночь, в которую её не меняли: он мог
      // быть заблокирован или промолчать по таймеру, и терять из-за этого
      // уже объявленную метку было бы нечестно. Снимается она только
      // со смертью охотника.
      hunterMarkId: mark,
      clearHunterMark: mark == null,
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
    if (outcome.guardedId != null) {
      _addLog(
        EventType.info,
        outcome.guardDiedId != null
            ? 'Телохранитель прикрыл ${s.nameOf(outcome.guardedId)} и погиб сам'
            : 'Телохранитель прикрывал ${s.nameOf(outcome.guardedId)}',
        visibleToPlayers: false,
      );
    }
    if (outcome.silencedId != null) {
      _addLog(
        EventType.info,
        'Шантажист запугал ${s.nameOf(outcome.silencedId)}: '
        'сегодня он не голосует',
        visibleToPlayers: false,
      );
    }
    if (outcome.watchedId != null) {
      _addLog(
        EventType.info,
        'Свидетель наблюдал за ${s.nameOf(outcome.watchedId)}: '
        '${outcome.watchedActed == true ? 'выходил из дома' : 'не выходил'}',
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
    //
    // Выбывший остаётся за столом смотрителем, и ему нужен контекст:
    // кем он был (карточку роли он уже видел, но за вечер забудет) и
    // кто ещё погиб этой же ночью. Чужие роли сюда не попадают —
    // открытая карта остаётся настройкой стола.
    for (final id in outcome.killedIds) {
      server.sendTo(
        id,
        Envelope(Msg.eliminated, {
          'reason': 'kill',
          'round': s.round,
          'role': s.byId(id)?.role?.name,
          'roleEmoji': s.byId(id)?.role?.emoji,
          'alsoKilled': [
            for (final other in outcome.killedIds)
              if (other != id) s.nameOf(other),
          ],
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
      clearVerdict: true,
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
    _scheduleBots();
    notifyListeners();
  }

  /// Начало голосования: обычного, второго тура или повторного.
  ///
  /// [candidates] — участники второго тура (пусто — голосуют за любого).
  /// [verdictId] — повторное голосование после последнего слова: кандидат
  /// один, вопрос — «выгнать или оставить». Технически это тот же тур
  /// с одним кандидатом: голос за него — «выгнать», пропуск — «оставить».
  /// Поэтому клиент старой версии из кэша отработает его без изменений.
  void startVoting({
    List<String> candidates = const [],
    String? verdictId,
  }) {
    final s = _state;
    if (s == null) return;
    final isVerdict = verdictId != null;
    _state = s.copyWith(
      phase: GamePhase.voting,
      votes: <String, String?>{},
      runoffCandidates: candidates,
      awaitingVoteConfirm: false,
      paused: false,
      clearLastWord: true,
      verdictId: verdictId,
      clearVerdict: !isVerdict,
      timeLeft: candidates.isEmpty
          ? (s.votingDuration)
          : (s.runoffDuration),
    );
    _persist();
    _addLog(
      EventType.phaseStart,
      isVerdict
          ? 'Повторное голосование: выгнать ${s.nameOf(verdictId)} '
              'или оставить'
          : candidates.isEmpty
              ? 'Начинается голосование'
              : 'Второй тур: ${candidates.map(s.nameOf).join(', ')}',
    );

    _playEverywhere(A.voteStart);
    _ambient(A.ambVote);

    // В повторном голосовании пакет «второй тур» не шлём: клиент показал бы
    // «Второй тур голосования», а это другой вопрос. Всё нужное — в `phase`.
    if (candidates.isNotEmpty && !isVerdict) {
      server.broadcast(Envelope(Msg.voteRunoff, {
        'candidates': candidates
            .map((id) => {'id': id, 'name': s.nameOf(id)})
            .toList(),
      }));
    }
    _broadcastPhase();
    _startTimer();
    _scheduleBots();
    notifyListeners();
  }

  /// Закрытие приёма голосов. Результат ведущий подтверждает вручную.
  void closeVoting() {
    final s = _state;
    if (s == null || s.phase != GamePhase.voting) return;
    if (s.awaitingVoteConfirm) return; // уже закрыто
    _stopTimer();
    _botsAt = null;
    _fillBotVotes();
    _state = _state!.copyWith(paused: true, awaitingVoteConfirm: true);
    _persist();
    notifyListeners();
  }

  /// Подтверждение итога голосования ведущим.
  ///
  /// С правилом «последнее слово» путь выбывающего — в три шага:
  ///  1. первое голосование (и второй тур при ничьей) выбирает игрока;
  ///  2. он говорит последнее слово — ещё живой, ещё в игре;
  ///  3. повторное голосование решает: выгнать или оставить.
  /// Этот метод вызывается на шаге 1 и на шаге 3; какой сейчас — видно
  /// по [GameState.verdictId].
  void confirmElimination(String? playerId) {
    final s = _state;
    if (s == null) return;

    if (playerId == null) {
      // Никто не выбывает: ничья или стол передумал после последнего слова.
      final pardoned = s.verdictId;
      _addLog(
        EventType.info,
        pardoned == null
            ? 'Голосование: никто не выбывает'
            : 'Повторное голосование: ${s.nameOf(pardoned)} остаётся в игре '
                '(выгнать — ${s.verdictExile}, оставить — ${s.verdictKeep})',
      );
      // Счётчик «город не может решить»: две ничьи подряд включают
      // сюжетную карточку тупика. Сбрасывается, как только кого-то выгнали.
      _state = s.copyWith(noDeathsStreak: s.noDeathsStreak + 1);
      server.broadcast(Envelope(Msg.voteResult, {
        'eliminated': null,
        'tie': pardoned == null,
        // Старый клиент этого поля не знает и покажет «никто не выбывает» —
        // что тоже правда.
        if (pardoned != null) 'pardonedName': s.nameOf(pardoned),
      }));
      _maybeShowStory();
      startNight();
      return;
    }

    // Шаг 1 → шаг 2: стол выбрал игрока, но он ещё не выбыл.
    if (shouldGiveLastWord(s)) {
      _startLastWord(playerId);
      return;
    }

    // Охотник, уходя, забирает с собой того, на кого оставил метку.
    // Правило работает и при изгнании голосованием — иначе «выгоняем
    // охотника» было бы бесплатной операцией для города.
    final revenge = <String>[];
    final exiled = s.byId(playerId);
    if (exiled?.role?.type == RoleType.hunter) {
      final mark = s.hunterMarkId;
      if (mark != null && mark != playerId) {
        final target = s.byId(mark);
        if (target != null && target.isAlive) revenge.add(mark);
      }
    }

    final players = s.players
        .map((p) => p.id == playerId || revenge.contains(p.id)
            ? p.copyWith(
                isAlive: false,
                eliminatedRound: s.round,
                eliminationReason: p.id == playerId
                    ? EliminationReason.voted
                    : EliminationReason.killed,
              )
            : p)
        .toList();
    // Город всё-таки решил — счётчик ничьих обнуляется.
    _state = s.copyWith(
      players: players,
      noDeathsStreak: 0,
      // Метка израсходована: следующий охотник (если его раздадут)
      // начинает с чистого листа.
      clearHunterMark: revenge.isNotEmpty,
    );
    _persist();

    _addLog(EventType.elimination,
        'День ${s.round}: голосованием выбыл ${s.nameOf(playerId)}');
    for (final id in revenge) {
      _addLog(EventType.kill,
          'Охотник ${s.nameOf(playerId)} забрал с собой ${s.nameOf(id)}');
    }

    _playEverywhere(A.eliminated);

    server.broadcast(Envelope(Msg.voteResult, {
      'eliminated': playerId,
      'eliminatedName': s.nameOf(playerId),
      'tie': false,
      // Открытая карта: роль выбывшего видна всем сразу.
      if (s.openCards)
        'revealedRole': s.byId(playerId)?.role?.name,
    }));
    server.sendTo(
        playerId,
        Envelope(Msg.eliminated, {
          'reason': 'vote',
          'round': s.round,
          'role': s.byId(playerId)?.role?.name,
          'roleEmoji': s.byId(playerId)?.role?.emoji,
        }));
    _broadcastLobby();

    _maybeShowStory(exile: true);

    if (_checkGameOver()) return;
    startNight();
  }

  /// Последнее слово того, кого выбрал стол: короткая фаза с таймером
  /// перед повторным голосованием. Игрок ещё жив и может переубедить стол.
  ///
  /// Отдельной фазы в [GamePhase] нет намеренно: это тот же день, просто
  /// говорит один человек. Никто не ходит и не голосует, поэтому старый
  /// клиент из кэша покажет обычный «День» и ничего не сломает.
  void _startLastWord(String playerId) {
    final s = _state;
    if (s == null) return;
    final votesFor = s.voteTally[playerId] ?? 0;
    _state = s.copyWith(
      phase: GamePhase.day,
      lastWordId: playerId,
      clearVerdict: true,
      paused: false,
      timeLeft: Rules.lastWordSeconds,
      votes: <String, String?>{},
      runoffCandidates: const [],
      awaitingVoteConfirm: false,
    );
    _addLog(
      EventType.info,
      'Голосование: стол выбрал ${s.nameOf(playerId)} (голосов: $votesFor). '
      'Последнее слово',
    );
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
  /// Дальше — повторное голосование: стол решает, выгнать или оставить.
  void endLastWord() {
    final s = _state;
    final speaker = s?.lastWordId;
    if (s == null || speaker == null) return;
    _stopTimer();
    // Говоривший мог исчезнуть из партии (ведущий удалил игрока) —
    // тогда голосовать не о ком, сразу ночь.
    if (s.byId(speaker)?.isAlive != true) {
      startNight();
      return;
    }
    startVoting(candidates: [speaker], verdictId: speaker);
  }

  /// Запуск второго тура между лидерами.
  void startRunoff(List<String> leaders) => startVoting(candidates: leaders);

  // ==================== таймер ====================

  /// Момент последнего учтённого тика. По нему считается реально
  /// прошедшее время, а не число срабатываний таймера (см. [_startTimer]).
  DateTime? _lastTickAt;

  void _startTimer() {
    _stopTimer();
    // Отсчёт по РЕАЛЬНОМУ времени, а не по числу тиков.
    //
    // Timer.periodic не гарантирует секунду: Android замораживает таймеры,
    // когда экран ведущего гаснет и служба переднего плана ещё не поднялась,
    // а при высокой нагрузке тики сдвигаются. Раньше `timeLeft--` на каждом
    // тике означал, что за фон из 3 секунд реального времени уходила 1
    // секунда игрового — фаза «Ночи» висела втрое дольше, и стол ждал
    // ведущего. Теперь мы запоминаем момент старта и вычитаем реальную
    // разницу: пропущенные тики не теряются.
    _lastTickAt = DateTime.now();

    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      // Сначала — автоматы: они могут завершить фазу до тика таймера.
      _maybeRunBots();
      final s = _state;
      if (s == null || s.paused) {
        // На паузе время не идёт: сдвигаем точку отсчёта, чтобы после
        // снятия паузы не вычесть всё время простоя.
        _lastTickAt = DateTime.now();
        return;
      }
      final now = DateTime.now();
      final elapsed = now.difference(_lastTickAt!).inSeconds;
      if (elapsed <= 0) return; // тик пришёл раньше секунды — не вычитаем
      _lastTickAt = now;

      final left = s.timeLeft - elapsed;
      if (left > 0) {
        _state = s.copyWith(timeLeft: left);
        notifyListeners();
      } else {
        _state = s.copyWith(timeLeft: 0);
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

  /// Приложение вернулось из фона.
  ///
  /// Пока процесс был заморожен (экран погас, система придушила службу),
  /// Timer.periodic не срабатывал: `timeLeft` застывало, хотя реальное
  /// время шло. Со службой переднего плана Android обычно не замораживает
  /// ведущего, но на iOS и на «злых» прошивках это случается.
  ///
  /// Здесь мы догоняем пропущенное: если фаза не на паузе, вычитаем
  /// реально прошедшее время и, если оно вышло, сразу завершаем фазу —
  /// вместо того чтобы позволить столу ждать ещё минуту.
  void onResume() {
    final s = _state;
    if (s == null || s.paused || _lastTickAt == null) return;
    if (s.phase == GamePhase.ended) return;
    // В раздаче ролей и в лобби таймера нет: timeLeft = 0, и «догон»
    // мгновенно завершил бы фазу, которую завершает человек, а не часы.
    if (s.phase == GamePhase.waiting || s.phase == GamePhase.rolesCheck) return;

    final elapsed = DateTime.now().difference(_lastTickAt!).inSeconds;
    if (elapsed <= 0) return;
    _lastTickAt = DateTime.now();

    if (elapsed < s.timeLeft) {
      _state = s.copyWith(timeLeft: s.timeLeft - elapsed);
      notifyListeners();
      return;
    }

    // Время фазы истекло, пока приложение спало.
    _state = s.copyWith(timeLeft: 0);
    _stopTimer();
    _onTimeout();
  }

  void _stopTimer() {
    _tick?.cancel();
    _tick = null;
    _sync?.cancel();
    _sync = null;
    _botsAt = null;
  }

  void _onTimeout() {
    final s = _state;
    if (s == null) return;
    // Последнее слово идёт в фазе «день», но заканчивается повторным
    // голосованием, а не обычным — перехватываем до общего переключателя.
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
    if (_state!.paused) {
      _botsAt = null;
    } else {
      _scheduleBots();
    }
    // Пауза и её снятие — тоже сдвиг точки отсчёта: пока стояли,
    // реальное время шло, и без этого первая же проверка вычла бы
    // всё время простоя.
    _lastTickAt = DateTime.now();
    server.broadcast(Envelope(Msg.timeUpdate, {
      'time': _state!.timeLeft,
      'paused': _state!.paused,
    }));
    notifyListeners();
  }

  void addTime(int seconds) {
    // Точка отсчёта сдвигается: иначе следующая проверка вычла бы время,
    // которое только что добавили, и кнопка «+1 мин» не работала бы.
    _lastTickAt = DateTime.now();
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
    final accused = s.isVerdictVote ? s.byId(s.verdictId) : null;
    return {
      'phase': s.phase.wire,
      'round': s.round,
      'time': s.timeLeft,
      'paused': s.paused,
      'isAlive': p.isAlive,
      'canPierce': canAct && s.canRequestPiercing(p),
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
      // Повторное голосование: о ком оно (null — обычное голосование).
      // Клиент по этому полю подписывает кнопки «Выгнать» и «Оставить».
      'verdict': accused == null
          ? null
          : {'id': accused.id, 'name': accused.name},
      // Шантаж: игрок должен понимать, почему у него нет кнопок.
      if (s.isSilencedNow(p)) 'silenced': true,
    };
  }

  bool _canPlayerAct(Player p) {
    final s = _state!;
    if (!p.isAlive) return false;
    switch (s.phase) {
      case GamePhase.night:
        return s.actsTonight(p) && !s.nightActions.containsKey(p.id);
      case GamePhase.voting:
        // В повторном голосовании обвиняемый только ждёт решения.
        if (s.isVerdictVote && p.id == s.verdictId) return false;
        // Запуганный шантажистом сегодня не голосует: кнопки ему не
        // показываем вовсе, иначе он нажмёт, а голос молча не засчитается.
        if (s.isSilencedNow(p)) return false;
        return !s.votes.containsKey(p.id);
      default:
        return false;
    }
  }

  /// Список допустимых целей. Правило — в GameEngine, чтобы сервер,
  /// браузерный игрок и бот не могли выбрать разные вещи.
  List<Map<String, dynamic>> _targetsFor(Player p) =>
      GameEngine.legalTargetsFor(_state!, p)
          .map((c) => {'id': c.id, 'name': c.name, 'color': c.colorHex})
          .toList();

  String _promptFor(Player p) {
    final s = _state!;
    if (!p.isAlive) return 'Вы выбыли из игры';
    // Последнее слово: говорящий ещё в игре, после него стол голосует снова.
    if (s.lastWordId != null) {
      return p.id == s.lastWordId
          ? 'Ваше последнее слово'
          : 'Последнее слово: ${s.nameOf(s.lastWordId)}';
    }
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
          case RoleType.bodyguard:
            return 'Кого прикрыть собой?';
          case RoleType.witness:
            return 'За кем наблюдать?';
          case RoleType.hunter:
            return 'Кого забрать с собой?';
          case RoleType.blackmailer:
            return 'Кого запугать на завтра?';
          default:
            return 'Спите';
        }
      case GamePhase.day:
        return 'Обсуждайте';
      case GamePhase.voting:
        if (s.isVerdictVote) {
          return p.id == s.verdictId
              ? 'Стол решает вашу судьбу'
              : 'Выгнать ${s.nameOf(s.verdictId)} или оставить?';
        }
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
        // Боты роль «прочитали» в момент раздачи: просить их нажать
        // «Понятно» бессмысленно, и в подсказке они только мешают.
        final waiting = s.unacknowledged.where((p) => !p.isBot).toList();
        if (s.unacknowledged.isEmpty) {
          return 'Все прочитали роль — начинаем ночь.';
        }
        if (waiting.isEmpty) {
          return 'Все люди готовы — осталось дождаться ботов.';
        }
        // Считаем по всем игрокам, а не по отфильтрованному списку:
        // иначе при одном «молчащем» боте выходило бы «6 из 6».
        final ready = s.players.length - s.unacknowledged.length;
        return 'Роли изучают ($ready из ${s.players.length}): '
            '${waiting.map((p) => p.name).join(', ')}';
      case GamePhase.night:
        // Ботов в списке ожидания нет: они ходят сами через 2–5 секунд,
        // и ведущий не должен искать их за столом.
        final waiting = s.pendingActors.where((p) => !p.isBot).toList();
        final botsPending = s.pendingActors.any((p) => p.isBot);
        if (s.isIntroNight) {
          if (waiting.isEmpty && !botsPending) {
            return 'Ночь знакомства: мафия узнала своих. Можно будить город — '
                'сегодня никто не погибает.';
          }
          return waiting.isEmpty
              ? 'Ночь знакомства: комиссар из ботов проверяет — это 2–5 секунд.'
              : 'Ночь знакомства: мафия узнаёт своих, комиссар проверяет. '
                  'Ждём: ${waiting.map((p) => p.name).join(', ')}';
        }
        if (waiting.isEmpty && !botsPending) {
          return 'Все действия собраны. Можно завершать ночь.';
        }
        if (waiting.isEmpty) {
          return 'Все люди сходили — боты доигрывают свой ход (2–5 секунд).';
        }
        return 'Ожидаем выбор от: ${waiting.map((p) => p.name).join(', ')}'
            '${botsPending ? ' (боты ходят сами)' : ''}';
      case GamePhase.day:
        if (s.lastWordId != null) {
          return 'Последнее слово: ${s.nameOf(s.lastWordId)}. '
              'Договорил раньше — нажмите «Слово сказано». '
              'Дальше стол голосует ещё раз: выгнать или оставить.';
        }
        return s.hasBots
            ? 'Идёт обсуждение. Живых: ${s.alive.length}. '
                'Боты высказываются сами — прочитайте их реплики в журнале.'
            : 'Идёт обсуждение. Живых: ${s.alive.length}';
      case GamePhase.voting:
        final waiting = s.pendingVoters.where((p) => !p.isBot).toList();
        if (s.isVerdictVote) {
          final name = s.nameOf(s.verdictId);
          if (waiting.isEmpty) {
            return s.allVotesIn
                ? 'Повторное голосование по игроку $name: все высказались.'
                : 'Повторное голосование по игроку $name: люди высказались, '
                    'боты доголосуют сами.';
          }
          return 'Выгнать $name или оставить? Не проголосовали: '
              '${waiting.map((p) => p.name).join(', ')}';
        }
        if (s.allVotesIn) return 'Все проголосовали.';
        if (waiting.isEmpty) {
          return 'Люди проголосовали — боты доголосуют сами (2–5 секунд).';
        }
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
                'isBot': p.isBot,
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

  /// Остановка сервера и таймеров.
  ///
  /// Идемпотентна: вызывается и по кнопке, и из `dispose()` экрана как
  /// страховка. Флаг [_shutDown] нужен из-за `notifyListeners()`: после
  /// `super.dispose()` контроллера оповещать подписчиков уже нельзя —
  /// Flutter бросает «A HostController was used after being disposed».
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    _stopTimer();
    await AudioService.instance.stopAmbient();
    await HostBackground.stop();
    await _inboxSub?.cancel();
    await _lostSub?.cancel();
    await _restoredSub?.cancel();
    await server.stop();
    notifyListeners();
  }

  bool _shutDown = false;
  bool _disposed = false;

  /// Оповещение подписчиков с защитой от «после dispose».
  ///
  /// Таймеры и сетевые колбэки живут независимо от жизненного цикла
  /// контроллера: последний тик может прийти между `dispose()` и отменой
  /// таймера (или сокет прислать сообщение в тот же кадр). Штатный
  /// `notifyListeners()` в этот момент бросает исключение и роняет кадр —
  /// в дебаге это видно как красный экран, в релизе как пропущенная
  /// отрисовка.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimer();
    _inboxSub?.cancel();
    _lostSub?.cancel();
    _restoredSub?.cancel();
    server.dispose();
    super.dispose();
  }
}
