import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../core/constants.dart';
import '../storage/device_id.dart';
import 'discovery.dart';
import 'protocol.dart';

enum ConnStatus { idle, searching, connecting, connected, reconnecting, failed }

/// Клиентское подключение к серверу ведущего.
/// Держит ping, сам переподключается при обрыве и запрашивает
/// полную синхронизацию состояния после восстановления связи.
class ClientConnection {
  WebSocket? _socket;
  Timer? _pingTimer;
  StreamSubscription? _sub;

  String? _host;
  int _port = Net.gamePort;
  String? _code;
  String? _playerName;
  String? playerId;

  bool _manualClose = false;
  int _attempt = 0;
  final Random _rnd = Random();

  /// Пауза перед следующей попыткой: 400 мс × 1.6^n, но не больше 8 с,
  /// плюс случайный разброс до 600 мс. Ровно та же формула, что в app.js —
  /// иначе браузерный и нативный игроки ведут себя по-разному в одном зале.
  Duration _retryDelay(int attempt) {
    final base = Net.reconnectBaseDelay.inMilliseconds *
        pow(1.6, min(attempt, 8)).toDouble();
    final capped = min(base, Net.reconnectMaxDelay.inMilliseconds.toDouble());
    final jitter = (_rnd.nextDouble() * Net.reconnectJitter.inMilliseconds);
    return Duration(milliseconds: (capped + jitter).round());
  }

  final _messages = StreamController<Envelope>.broadcast();
  Stream<Envelope> get messages => _messages.stream;

  final _status = StreamController<ConnStatus>.broadcast();
  Stream<ConnStatus> get statusStream => _status.stream;

  ConnStatus status = ConnStatus.idle;

  void _setStatus(ConnStatus s) {
    status = s;
    if (!_status.isClosed) _status.add(s);
  }

  /// Найти хост по коду и подключиться.
  /// [manualHost] — если игрок вводит IP вручную (запасной путь).
  Future<bool> connect({
    required String code,
    required String playerName,
    String? manualHost,
  }) async {
    _manualClose = false;
    _attempt = 0;
    _code = code;
    _playerName = playerName;

    if (manualHost != null && manualHost.isNotEmpty) {
      _host = manualHost;
    } else {
      _setStatus(ConnStatus.searching);
      final found = await DiscoveryService.findHost(code: code);
      if (found == null) {
        _setStatus(ConnStatus.failed);
        return false;
      }
      _host = found.address;
      _port = found.port;
    }

    return _openSocket(register: true);
  }

  Future<bool> _openSocket({required bool register}) async {
    if (_host == null) return false;
    _setStatus(ConnStatus.connecting);
    try {
      final socket = await WebSocket.connect('ws://$_host:$_port')
          .timeout(const Duration(seconds: 8));
      _socket = socket;
      _attempt = 0;
      _setStatus(ConnStatus.connected);

      _sub = socket.listen(
        (raw) {
          if (raw is! String) return;
          final env = Envelope.decode(raw);
          if (env == null) return;
          if (env.type == Msg.registerOk) {
            playerId = env.get<String>('id');
          }
          _messages.add(env); // pong нужен наверху для синхронизации часов
        },
        onDone: _handleDrop,
        onError: (_) => _handleDrop(),
        cancelOnError: true,
      );

      if (register) {
        // deviceId позволяет серверу отличить «он пришёл с планшета»
        // от «кто-то занял его имя». Пустая строка допустима: сервер
        // тогда работает по-старому (только по имени).
        send(Envelope(Msg.register, {
          'name': _playerName,
          'code': _code,
          'deviceId': await DeviceId.get(),
        }));
      } else {
        // Переподключение: просим актуальное состояние.
        send(Envelope(Msg.resyncRequest, {'playerId': playerId, 'name': _playerName}));
      }

      _startPing();
      return true;
    } catch (_) {
      _setStatus(ConnStatus.failed);
      return false;
    }
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(Net.pingInterval, (_) {
      _sendPing();
    });
    _sendPing(); // сразу, чтобы смещение часов было известно как можно раньше
  }

  /// Отправка ping с меткой локального времени: ответ вернёт её эхом,
  /// и клиент сможет посчитать задержку сети и смещение часов.
  /// Клиент сообщает ведущему свою измеренную задержку: по ней ведущий
  /// понимает, сколько форы дать синхронному звуку.
  int reportedRtt = 0;

  void _sendPing() {
    final id = playerId;
    send(Envelope(Msg.ping, {
      if (id != null) 'playerId': id,
      't': DateTime.now().millisecondsSinceEpoch,
      if (reportedRtt > 0) 'rtt': reportedRtt,
    }));
  }

  /// Обрыв связи: переподключаемся, пока не получится или пока игрок
  /// сам не выйдет.
  ///
  /// Сдаваться через N попыток нельзя: телефон игрока засыпает, экран
  /// гаснет, Wi-Fi моргает — за столом это норма, а не сбой. Пока клиент
  /// «жив», он обязан вернуться в партию сам. Статус [ConnStatus.failed]
  /// больше не выставляется автоматически — он остался только для ручного
  /// выхода и для случая, когда хост не найден при первом входе.
  Future<void> _handleDrop() async {
    _pingTimer?.cancel();
    _socket = null;
    if (_manualClose) {
      _setStatus(ConnStatus.idle);
      return;
    }

    _setStatus(ConnStatus.reconnecting);
    while (!_manualClose) {
      _attempt++;
      await Future<void>.delayed(_retryDelay(_attempt));
      if (_manualClose) return;

      // Адрес мог смениться (роуминг, новый день, другая точка доступа) —
      // пробуем найти хост заново по коду игры.
      if (_code != null) {
        final found = await DiscoveryService.findHost(
          code: _code!,
          timeout: const Duration(seconds: 3),
        );
        if (_manualClose) return;
        if (found != null) {
          _host = found.address;
          _port = found.port;
        }
      }
      // Хост не нашли — это не повод сдаваться: следующий круг попробует
      // снова (ведущий мог ещё не поднять сеть после перезапуска).
      if (_host == null) continue;

      final ok = await _openSocket(register: false);
      if (ok) return;
    }
  }

  /// Ручной повтор подключения: сбрасывает паузу, чтобы не ждать
  /// очередные 8 секунд после нажатия «Повторить».
  Future<bool> retry() async {
    _attempt = 0;
    _manualClose = false;
    if (_code != null && _playerName != null) {
      return connect(code: _code!, playerName: _playerName!);
    }
    return false;
  }

  /// Сколько всего было попыток переподключения подряд.
  /// Нужно экрану игрока: там теперь не «попытка N из 3», а честное
  /// «пробуем снова» без верхней границы.
  int get attemptsInARow => _attempt;

  int get attempt => _attempt;

  void send(Envelope env) {
    try {
      final s = _socket;
      if (s != null && s.readyState == WebSocket.open) {
        s.add(env.encode());
      }
    } catch (_) {
      // Потеря пакета обработается переподключением.
    }
  }

  Future<void> close() async {
    _manualClose = true;
    _pingTimer?.cancel();
    await _sub?.cancel();
    await _socket?.close();
    _socket = null;
    _setStatus(ConnStatus.idle);
  }

  Future<void> dispose() async {
    await close();
    await _messages.close();
    await _status.close();
  }
}
