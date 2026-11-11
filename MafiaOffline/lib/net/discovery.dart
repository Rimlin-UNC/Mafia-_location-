import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';

/// UDP-обнаружение хоста в локальной сети.
///
/// Благодаря этому игроку достаточно ввести 6-значный код — IP-адрес
/// ведущего приложение находит само. Интернет не нужен: работает
/// внутри Wi-Fi сети или раздачи с телефона ведущего.
class DiscoveryService {
  RawDatagramSocket? _socket;

  /// Сторона ведущего: слушаем широковещательные запросы и отвечаем,
  /// если код совпал с нашим.
  Future<void> startResponder({
    required String gameCode,
    required String gameName,
    required int playersPlanned,
    required int Function() liveConnectedCount,
  }) async {
    await stop();
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      Net.discoveryPort,
      reuseAddress: true,
      reusePort: false,
    );
    socket.broadcastEnabled = true;
    _socket = socket;

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      try {
        final raw = utf8.decode(dg.data);
        final query = jsonDecode(raw);
        if (query is! Map) return;
        if (query['q'] != 'mafia_discover') return;

        // Отвечаем либо на конкретный код, либо на запрос "покажи все игры".
        final askedCode = query['code'] as String?;
        if (askedCode != null && askedCode.isNotEmpty && askedCode != gameCode) {
          return;
        }

        final reply = jsonEncode({
          'r': 'mafia_host',
          'code': gameCode,
          'name': gameName,
          'port': Net.gamePort,
          'connected': liveConnectedCount(),
          'planned': playersPlanned,
        });
        socket.send(utf8.encode(reply), dg.address, dg.port);
      } catch (_) {
        // Повреждённый пакет игнорируем.
      }
    });
  }

  /// Сторона игрока: рассылаем широковещательный запрос и ждём ответа хоста.
  /// Возвращает найденный адрес или null по истечении таймаута.
  static Future<HostInfo?> findHost({
    required String code,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    RawDatagramSocket? socket;
    final completer = Completer<HostInfo?>();
    Timer? repeatTimer;
    Timer? timeoutTimer;

    Future<void> cleanup() async {
      repeatTimer?.cancel();
      timeoutTimer?.cancel();
      socket?.close();
    }

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket?.receive();
        if (dg == null) return;
        try {
          final reply = jsonDecode(utf8.decode(dg.data));
          if (reply is! Map) return;
          if (reply['r'] != 'mafia_host') return;
          if (reply['code'] != code) return;
          if (!completer.isCompleted) {
            completer.complete(HostInfo(
              address: dg.address.address,
              port: reply['port'] as int? ?? Net.gamePort,
              gameName: reply['name'] as String? ?? 'Игра',
              connected: reply['connected'] as int? ?? 0,
              planned: reply['planned'] as int? ?? 0,
            ));
          }
        } catch (_) {
          // игнорируем мусор
        }
      });

      final payload =
          utf8.encode(jsonEncode({'q': 'mafia_discover', 'code': code}));

      void blast() {
        for (final target in _broadcastTargets()) {
          try {
            socket?.send(payload, target, Net.discoveryPort);
          } catch (_) {
            // Некоторые адреса могут быть недоступны — это нормально.
          }
        }
      }

      blast();
      // Повторяем: первый пакет может потеряться при пробуждении Wi-Fi.
      repeatTimer = Timer.periodic(const Duration(milliseconds: 700), (_) => blast());
      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete(null);
      });

      final result = await completer.future;
      await cleanup();
      return result;
    } catch (_) {
      await cleanup();
      return null;
    }
  }

  static List<InternetAddress> _broadcastTargets() {
    return [
      InternetAddress('255.255.255.255'),
      // Типичные адреса раздачи с Android-телефона.
      InternetAddress('192.168.43.255'),
      InternetAddress('192.168.49.255'),
      InternetAddress('172.20.10.15'),
    ];
  }

  /// Локальный IPv4-адрес устройства — показываем ведущему для ручного ввода.
  static Future<String?> localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      // Предпочитаем адрес точки доступа / Wi-Fi.
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.address.startsWith('192.168.') ||
              addr.address.startsWith('172.') ||
              addr.address.startsWith('10.')) {
            return addr.address;
          }
        }
      }
      for (final iface in interfaces) {
        if (iface.addresses.isNotEmpty) return iface.addresses.first.address;
      }
    } catch (_) {
      // Нет доступа к списку интерфейсов.
    }
    return null;
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
  }
}

class HostInfo {
  final String address;
  final int port;
  final String gameName;
  final int connected;
  final int planned;

  const HostInfo({
    required this.address,
    required this.port,
    required this.gameName,
    required this.connected,
    required this.planned,
  });
}
