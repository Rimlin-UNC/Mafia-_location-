import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;

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

/// Одна проверка комиссара, как её прислал ведущий.
///
/// [blocked] — проверка не состоялась: комиссара в эту ночь заблокировали.
class CheckInfo {
  final int round;
  final String name;
  final bool isMafia;
  final bool blocked;
  const CheckInfo(this.round, this.name, this.isMafia, {this.blocked = false});

  /// Строка для списка «Ваши проверки».
  String get line => blocked
      ? 'Ночь $round: проверка не состоялась — вас заблокировали'
      : 'Ночь $round: $name — ${isMafia ? 'МАФИЯ' : 'не мафия'}';
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

  // ---------- v1.2.0 ----------

  /// Сколько игроков живо и сколько всего (0 — ведущий ещё не прислал).
  int aliveCount = 0;
  int totalCount = 0;

  /// Идёт ночь знакомства: убийств не будет.
  bool introNight = false;

  /// Кто говорит последнее слово (null — никто) и я ли это.
  String? lastWordName;
  bool lastWordIsMe = false;

  /// Повторное голосование после последнего слова: о ком оно (null — идёт
  /// обычное голосование или не голосование вовсе) и обо мне ли.
  String? verdictName;
  bool verdictIsMe = false;

  /// Проверки комиссара. Пусто у всех остальных ролей.
  ///
  /// Ответ на проверку этой ночи виден на ночном экране — сразу после
  /// выбора и только до рассвета (см. [nightCheck]). Днём он остаётся
  /// ТОЛЬКО внутри «Моя роль»: телефон лежит на столе экраном вверх,
  /// и любая отметка, которая бывает только у комиссара, выдала бы его.
  List<CheckInfo> checks = const [];

  /// Ответ на проверку текущей ночи — для ночного экрана комиссара.
  /// null — не ночь, ответа ещё нет или включена маскировка карты.
  CheckInfo? get nightCheck {
    if (phase != GamePhase.night || disguised) return null;
    for (final c in checks) {
      if (c.round == round) return c;
    }
    return null;
  }

  /// Правила стола из пакета лобби (null — ведущий старой версии).
  Map<String, dynamic>? tableRules;

  /// Сюжетная карточка, которую сейчас показывает ведущий.
  String? storyId;
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
        final rules = msg.get<Map>('rules');
        if (rules != null) tableRules = Map<String, dynamic>.from(rules);
        // Счётчик живых держим свежим и между сменами фаз.
        if (lobby.isNotEmpty) {
          totalCount = lobby.length;
          aliveCount = lobby.where((p) => p.alive).length;
        }
        break;

      case Msg.checkResult:
        // Приходит ночью, сразу после выбора. Баннера нет: ответ рисует
        // ночной экран (nightCheck), а с рассветом он уходит в «Моя роль».
        final target = msg.get<String>('name');
        if (target != null) {
          final r = msg.get<int>('round') ?? round;
          checks = [
            ...checks.where((c) => c.round != r),
            CheckInfo(
              r,
              target,
              msg.get<bool>('isMafia') ?? false,
              blocked: msg.get<bool>('blocked') ?? false,
            ),
          ];
        }
        break;

      case Msg.story:
        storyId = msg.get<String>('id');
        break;

      case Msg.storyDismiss:
        storyId = null;
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
        var text = msg.get<String>('text') ?? '';
        // Открытая карта: роли погибших приходят отдельным полем.
        // До 1.2.0 приложение-игрок его не читало — в браузере роль
        // видели, а в приложении нет.
        // Формат: {id погибшего: wire-имя роли}; имена — в killedNames,
        // в том же порядке, что и killed.
        final revealed = msg.get<Map>('revealed');
        if (revealed != null) {
          final ids = msg.get<List>('killed') ?? const [];
          final names = msg.get<List>('killedNames') ?? const [];
          final parts = <String>[];
          for (var i = 0; i < ids.length && i < names.length; i++) {
            final wire = revealed[ids[i]];
            if (wire is! String) continue;
            parts.add(
                '${names[i]} — ${Role.fromType(_roleTypeFromWire(wire)).name}');
          }
          if (parts.isNotEmpty) text = '$text (${parts.join(', ')})';
        }
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
        final shownRole = msg.get<String>('revealedRole');
        final pardoned = msg.get<String>('pardonedName');
        final text = name == null
            ? (pardoned == null
                ? 'Голосование: никто не выбывает'
                : 'Стол передумал: $pardoned остаётся в игре')
            : shownRole == null
                ? 'Голосованием выбыл $name'
                : 'Голосованием выбыл $name — $shownRole';
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
    final prevPhase = phase;
    final prevSpeaker = lastWordName;
    final prevVerdict = verdictName;
    phase = GamePhaseX.parse(msg.get<String>('phase'));
    round = msg.get<int>('round') ?? round;
    timeLeft = msg.get<int>('time') ?? 0;
    paused = msg.get<bool>('paused') ?? false;
    isAlive = msg.get<bool>('isAlive') ?? isAlive;
    canAct = msg.get<bool>('canAct') ?? false;
    actionSent = msg.get<bool>('alreadyActed') ?? false;
    prompt = msg.get<String>('prompt') ?? prompt;
    gameName = msg.get<String>('gameName') ?? gameName;

    // Поля 1.2.0. Все необязательные: ведущий на 1.1.x их не пришлёт,
    // и экран просто не покажет счётчик.
    aliveCount = msg.get<int>('alive') ?? aliveCount;
    totalCount = msg.get<int>('total') ?? totalCount;
    introNight = msg.get<bool>('intro') ?? false;
    final speaker = msg.get<Map>('lastWord');
    lastWordName = speaker?['name'] as String?;
    lastWordIsMe = speaker != null && speaker['id'] == playerId;
    final accused = msg.get<Map>('verdict');
    verdictName = accused?['name'] as String?;
    verdictIsMe = accused != null && accused['id'] == playerId;

    // Сигнал «фаза сменилась» — тем, кто смотрит не в экран. Одинаковый
    // у всех: вибрация только у активных ролей выдавала бы их соседям.
    // Ошибку платформы игнорируем: на планшете без мотора это не сбой.
    if (phase != prevPhase ||
        lastWordName != prevSpeaker ||
        verdictName != prevVerdict) {
      HapticFeedback.vibrate().catchError((Object _) {});
    }

    // sync приносит комиссару все его проверки заново.
    final syncChecks = msg.get<List>('checks');
    if (syncChecks != null) {
      checks = syncChecks
          .whereType<Map>()
          .map((c) => CheckInfo(
                c['round'] as int? ?? 0,
                c['name'] as String? ?? '',
                c['isMafia'] as bool? ?? false,
                blocked: c['blocked'] == true,
              ))
          .toList();
    }

    // sync после переподключения приносит роль заново.
    final syncRole = msg.get<String>('role');
    if (syncRole != null) roleAsset = A.card(_roleTypeFromWire(syncRole));
    roleName = msg.get<String>('roleName') ?? roleName;
    roleEmoji = msg.get<String>('roleEmoji') ?? roleEmoji;
    roleDescription = msg.get<String>('roleDescription') ?? roleDescription;

    // ВАЖНО: проверяем ПОСЛЕ присвоения roleName. Иначе на перезагруженном
    // клиенте роль ещё null, и экран-предупреждение не покажется — а без
    // подтверждения первая ночь будет ждать этого игрока вечно.
    final syncAck = msg.get<bool>('roleAck');
    if (syncAck != null) {
      roleAcknowledged = syncAck;
      if (!syncAck && roleName != null) awaitingRoleReveal = true;
    }

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
      case GamePhase.rolesCheck:
        // Партия уже идёт, но ночь ещё не объявлена: атмосферу ночи
        // не включаем, иначе за столом решат, что город уже заснул.
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

  /// Голос в повторном голосовании: выгнать или оставить.
  ///
  /// По сети это обычный голос: «выгнать» — голос за единственного
  /// кандидата, «оставить» — голос без кандидата.
  void submitVerdict({required bool exile}) {
    if (!canAct || actionSent) return;
    if (exile) {
      if (targets.isEmpty) return;
      selectedTargetId = targets.first.id;
      submit();
    } else {
      submit(skip: true);
    }
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
