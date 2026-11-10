import 'dart:async';
import 'dart:io';

import '../core/constants.dart';
import 'discovery.dart';
import 'web_assets.dart';
import 'protocol.dart';

/// Подключённый клиент.
class ClientConn {
  final WebSocket socket;
  String? playerId;
  DateTime lastSeen;

  /// Наименьшая измеренная задержка до этого клиента, мс.
  /// По ней ведущий подбирает фору для синхронного звука.
  int bestRttMs = 0;

  /// Когда соединение установлено — по нему отсекаем «мёртвые» сокеты,
  /// которые открылись и не представились.
  final DateTime openedAt;

  /// Сколько сообщений пришло за текущее окно — примитивная защита от
  /// клиента, сошедшего с ума и молотящего в сокет без остановки.
  int _msgCount = 0;
  DateTime _windowStart;

  ClientConn(this.socket)
      : lastSeen = DateTime.now(),
        openedAt = DateTime.now(),
        _windowStart = DateTime.now();

  /// true, если клиент превысил разумный темп (60 сообщений за 10 секунд).
  /// Нормальный игрок шлёт 2 ping в 10 секунд плюс редкие действия.
  bool get isFlooding {
    final now = DateTime.now();
    if (now.difference(_windowStart) > const Duration(seconds: 10)) {
      _windowStart = now;
      _msgCount = 0;
    }
    return ++_msgCount > 60;
  }
}

/// Локальный сервер, работающий прямо на телефоне ведущего.
///
/// Поднимает HttpServer с WebSocket-апгрейдом на порту [Net.gamePort]
/// и UDP-респондер для автообнаружения. Интернет не требуется:
/// достаточно, чтобы устройства были в одной сети (общий Wi-Fi
/// или точка доступа, раздаваемая телефоном ведущего).
///
/// ## Что сделано ради устойчивости
///
/// * **Ограничение параллельных отдач.** Когда 20 человек одновременно
///   сканируют QR, телефон получает 20 запросов страницы, следом 20×8 карт
///   и 20×3 звука. Без ограничителя dart:io пытается обслужить всё сразу,
///   память выедается буферами и процесс убивает система. Семафор держит
///   не больше [_maxParallelStatic] отдач, остальные ждут в очереди
///   миллисекунды.
/// * **Условные запросы.** Повторный заход отвечает 304 без тела.
/// * **Сжатие.** Текст отдаётся в gzip, если браузер его принимает.
/// * **Отсев молчунов.** Сокет, не представившийся за 30 секунд,
///   закрывается: это либо оборванная вкладка, либо сканер портов.
class HostServer {
  HttpServer? _server;
  final DiscoveryService _discovery = DiscoveryService();
  final List<ClientConn> _clients = [];
  Timer? _healthTimer;

  /// Входящее сообщение: (соединение, конверт).
  final _inbox = StreamController<({ClientConn conn, Envelope msg})>.broadcast();
  Stream<({ClientConn conn, Envelope msg})> get inbox => _inbox.stream;

  /// Игрок пропал со связи дольше таймаута.
  final _lost = StreamController<String>.broadcast();
  Stream<String> get onPlayerLost => _lost.stream;

  /// Игрок восстановил связь.
  final _restored = StreamController<String>.broadcast();
  Stream<String> get onPlayerRestored => _restored.stream;

  bool get isRunning => _server != null;
  String? boundAddress;

  /// Код текущей партии — подставляется в веб-страницу, чтобы игроку
  /// не пришлось вводить его вручную после перехода по QR.
  String? _gameCode;

  /// Одновременных отдач статики. Больше четырёх на телефоне не ускоряет:
  /// упирается в Wi-Fi, зато раздувает пиковую память.
  static const int _maxParallelStatic = 4;
  int _activeStatic = 0;
  final List<Completer<void>> _staticQueue = [];

  /// О ком уже сообщили как о потерянном — чтобы не слать событие
  /// каждые 3 секунды, пока человек ищет зарядку.
  final Set<String> _reportedLost = {};

  int get connectedCount => _clients.where((c) => c.playerId != null).length;

  /// Сколько всего сокетов открыто, включая непредставившиеся.
  /// Полезно ведущему: видно, что люди грузят страницу.
  int get socketCount => _clients.length;

  /// Запуск сервера. [gameCode] используется UDP-обнаружением.
  Future<String?> start({
    required String gameCode,
    required String gameName,
    required int plannedPlayers,
  }) async {
    await stop();

    _server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      Net.gamePort,
      shared: false,
    );

    // Не держим соединение открытым вечно: браузер, ушедший в фон,
    // иначе занимает слот до самого таймаута системы.
    _server!.idleTimeout = const Duration(seconds: 30);

    // Заголовок Server ни к чему — экономим байты на каждом ответе.
    _server!.serverHeader = null;

    _gameCode = gameCode;
    WebAssets.invalidateHtml();
    _server!.listen(_handleRequest, onError: (_) {});

    boundAddress = await DiscoveryService.localIp();

    await _discovery.startResponder(
      gameCode: gameCode,
      gameName: gameName,
      playersPlanned: plannedPlayers,
      liveConnectedCount: () => connectedCount,
    );

    // Контроль живости: раз в 3 секунды проверяем, от кого давно нет ping.
    _healthTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final now = DateTime.now();
      for (final c in List<ClientConn>.from(_clients)) {
        final id = c.playerId;

        // Сокет открыт, но игрок так и не представился — закрываем.
        if (id == null &&
            now.difference(c.openedAt) > const Duration(seconds: 30)) {
          _drop(c);
          continue;
        }
        if (id == null) continue;

        if (now.difference(c.lastSeen) > Net.pingTimeout) {
          // Сообщаем один раз, а не каждые три секунды.
          if (_reportedLost.add(id)) _lost.add(id);
        }
      }
    });

    return boundAddress;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    // Не WebSocket — значит браузер просит страницу или ассет.
    // Отдаём веб-клиент: играть можно с любого устройства без установки.
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      await _serveStatic(request);
      return;
    }

    try {
      final socket = await WebSocketTransformer.upgrade(request);

      // Пинг-понг на уровне протокола WebSocket: система сама заметит
      // разрыв, даже если приложение игрока заморожено в фоне.
      socket.pingInterval = const Duration(seconds: 15);

      final conn = ClientConn(socket);
      _clients.add(conn);

      socket.listen(
        (raw) {
          if (raw is! String) return;
          if (conn.isFlooding) return;

          final msg = Envelope.decode(raw);
          if (msg == null) return;

          conn.lastSeen = DateTime.now();

          // ping обрабатываем прямо здесь — не тревожим игровую логику.
          if (msg.type == Msg.ping) {
            final id = conn.playerId;
            if (id != null && _reportedLost.remove(id)) {
              _restored.add(id);
            }
            // Клиент присылает свой rtt из прошлого обмена — берём минимум.
            final reported = msg.get<int>('rtt');
            if (reported != null && reported > 0 && reported < 5000) {
              conn.bestRttMs = conn.bestRttMs == 0
                  ? reported
                  : (reported < conn.bestRttMs ? reported : conn.bestRttMs);
            }
            // В ответ кладём время ведущего и эхо метки клиента —
            // по ним клиент вычисляет смещение часов для общего звука.
            _send(
              conn,
              Envelope(Msg.pong, {
                'hostTime': DateTime.now().millisecondsSinceEpoch,
                'echo': msg.get<int>('t') ?? 0,
              }),
            );
            return;
          }
          _inbox.add((conn: conn, msg: msg));
        },
        onDone: () => _clients.remove(conn),
        onError: (_) => _clients.remove(conn),
        cancelOnError: true,
      );
    } catch (_) {
      // Не удалось поднять сокет — игнорируем, клиент попробует снова.
    }
  }

  /// Пропуск в очереди на отдачу статики.
  Future<void> _acquireSlot() {
    if (_activeStatic < _maxParallelStatic) {
      _activeStatic++;
      return Future.value();
    }
    final c = Completer<void>();
    _staticQueue.add(c);
    return c.future;
  }

  void _releaseSlot() {
    if (_staticQueue.isNotEmpty) {
      _staticQueue.removeAt(0).complete();
    } else {
      _activeStatic--;
    }
  }

  /// Раздача веб-клиента.
  Future<void> _serveStatic(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;

    // Служебная проверка: клиент дёргает её, чтобы понять, жив ли хост,
    // не поднимая WebSocket. Отвечаем до всякой очереди — это дёшево.
    if (path == '/ping') {
      try {
        response
          ..statusCode = HttpStatus.ok
          ..headers.set(HttpHeaders.contentTypeHeader, 'text/plain')
          ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
          ..write('ok');
        await response.close();
      } catch (_) {}
      return;
    }

    await _acquireSlot();
    try {
      final asset = WebAssets.resolve(path);
      if (asset == null) {
        // Любой неизвестный путь ведёт на страницу игры, а не на 404:
        // человек мог опечататься в адресе или открыть старую ссылку.
        response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/')
          ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        await response.close();
        return;
      }

      final isHtml = path == '/' || path.endsWith('.html');

      // Сжимаем только то, что того стоит, и только если браузер согласен.
      final acceptsGzip = (request.headers.value(HttpHeaders.acceptEncodingHeader) ?? '')
          .toLowerCase()
          .contains('gzip');

      Uint8ListLike? body;
      var encoded = false;

      if (acceptsGzip && WebAssets.isCompressible(path)) {
        final packed = await WebAssets.loadGzipped(path, gameCode: _gameCode);
        if (packed != null) {
          body = packed;
          encoded = true;
        }
      }
      body ??= await WebAssets.load(path, gameCode: _gameCode);

      if (body == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final etag = WebAssets.etagFor(path, body.length);

      // Браузер уже держит этот файл — не гоним мегабайты повторно.
      // Особенно важно для звуков: игрок, перезагрузивший страницу,
      // иначе снова тянет 3 МБ через точку доступа ведущего.
      if (!isHtml && request.headers.value(HttpHeaders.ifNoneMatchHeader) == etag) {
        response
          ..statusCode = HttpStatus.notModified
          ..headers.set(HttpHeaders.etagHeader, etag);
        await response.close();
        return;
      }

      response
        ..statusCode = HttpStatus.ok
        ..headers.set(HttpHeaders.contentTypeHeader, WebAssets.contentTypeFor(path))
        // Страницу не кешируем: код партии в ней меняется.
        // Картинки и звуки — кешируем надолго, они статичны.
        ..headers.set(
          HttpHeaders.cacheControlHeader,
          isHtml ? 'no-store' : 'public, max-age=604800, immutable',
        )
        ..headers.set('X-Content-Type-Options', 'nosniff');

      if (!isHtml) response.headers.set(HttpHeaders.etagHeader, etag);
      if (encoded) response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');

      // Явная длина позволяет браузеру показать прогресс и не гадать,
      // а нам — не держать chunked-обвязку.
      response.headers.contentLength = body.length;
      response.add(body);
      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    } finally {
      _releaseSlot();
    }
  }

  void _send(ClientConn conn, Envelope env) {
    try {
      if (conn.socket.readyState == WebSocket.open) {
        conn.socket.add(env.encode());
      }
    } catch (_) {
      // Разрыв обработается в onDone.
    }
  }

  void _drop(ClientConn c) {
    _clients.remove(c);
    try {
      c.socket.close();
    } catch (_) {}
  }

  /// Отправить конкретному игроку.
  void sendTo(String playerId, Envelope env) {
    for (final c in _clients) {
      if (c.playerId == playerId) _send(c, env);
    }
  }

  /// Отправить по конкретному соединению (когда playerId ещё не назначен).
  void sendToConn(ClientConn conn, Envelope env) => _send(conn, env);

  /// Разослать всем зарегистрированным игрокам.
  ///
  /// Кодируем сообщение ОДИН раз, а не в каждом _send: при 20 игроках
  /// это 20 лишних проходов jsonEncode по одной и той же структуре.
  void broadcast(Envelope env) {
    final payload = env.encode();
    for (final c in _clients) {
      if (c.playerId != null) _sendRaw(c, payload);
    }
  }

  /// Разослать всем, кроме указанных.
  void broadcastExcept(Set<String> excludeIds, Envelope env) {
    final payload = env.encode();
    for (final c in _clients) {
      final id = c.playerId;
      if (id != null && !excludeIds.contains(id)) _sendRaw(c, payload);
    }
  }

  void _sendRaw(ClientConn conn, String payload) {
    try {
      if (conn.socket.readyState == WebSocket.open) {
        conn.socket.add(payload);
      }
    } catch (_) {}
  }

  /// Худшая задержка среди подключённых — сколько форы дать общему звуку.
  int get worstRttMs {
    var worst = 0;
    for (final c in _clients) {
      if (c.playerId != null && c.bestRttMs > worst) worst = c.bestRttMs;
    }
    return worst;
  }

  bool isOnline(String playerId) {
    for (final c in _clients) {
      if (c.playerId == playerId) {
        return DateTime.now().difference(c.lastSeen) <= Net.pingTimeout;
      }
    }
    return false;
  }

  /// Отключить игрока (исключение из лобби).
  Future<void> disconnectPlayer(String playerId) async {
    for (final c in List<ClientConn>.from(_clients)) {
      if (c.playerId == playerId) {
        _send(c, Envelope(Msg.kick, {'reason': 'removed_by_host'}));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await c.socket.close();
        _clients.remove(c);
      }
    }
  }

  /// Закрыть все соединения игрока, кроме указанного.
  ///
  /// Нужно, когда человек открыл игру в двух вкладках или вернулся
  /// с нового устройства: старый сокет висит «живым» и получает копии
  /// сообщений, а игрок видит их в брошенной вкладке.
  void dropDuplicates(String playerId, ClientConn keep) {
    for (final c in List<ClientConn>.from(_clients)) {
      if (c.playerId == playerId && !identical(c, keep)) {
        _send(c, Envelope(Msg.kick, {'reason': 'another_device'}));
        _drop(c);
      }
    }
  }

  Future<void> stop() async {
    _healthTimer?.cancel();
    _healthTimer = null;
    _reportedLost.clear();
    for (final c in List<ClientConn>.from(_clients)) {
      try {
        await c.socket.close();
      } catch (_) {}
    }
    _clients.clear();
    await _discovery.stop();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> dispose() async {
    await stop();
    await _inbox.close();
    await _lost.close();
    await _restored.close();
  }
}

/// Псевдоним: и Uint8List, и List<int> подходят для response.add.
typedef Uint8ListLike = List<int>;
