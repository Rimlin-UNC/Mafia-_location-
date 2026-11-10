import 'dart:async';
import 'dart:io';

import '../core/constants.dart';
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
        send(Envelope(Msg.register, {'name': _playerName, 'code': _code}));
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

  /// Обрыв связи: до 3 автоматических попыток с интервалом 2 секунды.
  Future<void> _handleDrop() async {
    _pingTimer?.cancel();
    _socket = null;
    if (_manualClose) {
      _setStatus(ConnStatus.idle);
      return;
    }

    _setStatus(ConnStatus.reconnecting);
    while (_attempt < Net.reconnectAttempts && !_manualClose) {
      _attempt++;
      await Future<void>.delayed(Net.reconnectDelay);
      if (_manualClose) return;

      // Адрес мог смениться — пробуем найти хост заново.
      if (_code != null) {
        final found = await DiscoveryService.findHost(
          code: _code!,
          timeout: const Duration(seconds: 3),
        );
        if (found != null) {
          _host = found.address;
          _port = found.port;
        }
      }

      final ok = await _openSocket(register: false);
      if (ok) return;
    }
    _setStatus(ConnStatus.failed);
  }

  /// Ручной повтор подключения.
  Future<bool> retry() async {
    _attempt = 0;
    _manualClose = false;
    if (_code != null && _playerName != null) {
      return connect(code: _code!, playerName: _playerName!);
    }
    return false;
  }

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
