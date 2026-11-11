import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../storage/wifi_store.dart';

/// Чем закончилась попытка подключить телефон к сети ведущего.
enum WifiJoinResult {
  /// Сеть сохранена, система подключается к ней сама.
  saved,

  /// Сеть уже была сохранена в телефоне. Система окно не показывает
  /// и сама не переключается — если телефон сейчас в другой сети,
  /// сеть ведущего придётся выбрать вручную (пароль вводить не нужно).
  exists,

  /// Игрок закрыл системное окно, не сохранив сеть.
  cancelled,

  /// Телефон так не умеет: Android старше 11, iPhone, сеть с WEP.
  unsupported,

  /// Система отказала: например, пароль не подходит под требования WPA.
  failed,
}

/// Подключение телефона игрока к Wi-Fi ведущего по данным из единого кода.
///
/// На Android 11 и новее открывается системное окно «Сохранить сеть?».
/// После согласия система сама сохраняет сеть и подключается к ней —
/// ровно то же делает камера телефона, прочитав код Wi-Fi. Отдельных
/// разрешений для этого не нужно: сеть добавляет не приложение, а система,
/// и только с согласия владельца телефона.
///
/// Во всех остальных случаях возвращается причина, и экран входа
/// показывает имя сети и пароль для ручного подключения.
class WifiJoiner {
  static const channel = MethodChannel('mafia_offline/wifi');

  /// Значение поля `security` для нативной стороны.
  static String securityWire(WifiSecurity s) {
    switch (s) {
      case WifiSecurity.wpa:
        return 'wpa';
      case WifiSecurity.wep:
        return 'wep';
      case WifiSecurity.open:
        return 'open';
    }
  }

  static Future<WifiJoinResult> addNetwork(WifiConfig cfg) async {
    // WEP система через это окно не принимает — не тратим на него диалог.
    if (cfg.security == WifiSecurity.wep) return WifiJoinResult.unsupported;
    if (!cfg.isUsable) return WifiJoinResult.failed;

    try {
      final r = await channel.invokeMethod<String>('addNetwork', {
        'ssid': cfg.ssid,
        'password': cfg.security == WifiSecurity.open ? '' : cfg.password,
        'security': securityWire(cfg.security),
        'hidden': cfg.hidden,
      });
      switch (r) {
        case 'saved':
          return WifiJoinResult.saved;
        case 'exists':
          return WifiJoinResult.exists;
        case 'cancelled':
          return WifiJoinResult.cancelled;
        case 'unsupported':
          return WifiJoinResult.unsupported;
        default:
          return WifiJoinResult.failed;
      }
    } on MissingPluginException {
      // Платформа без нативной части (iPhone, тесты).
      return WifiJoinResult.unsupported;
    } catch (_) {
      return WifiJoinResult.failed;
    }
  }

  /// Открывает системный список сетей Wi-Fi. `false` — открыть не удалось.
  static Future<bool> openWifiSettings() async {
    try {
      return await channel.invokeMethod<bool>('openWifiSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Отвечает ли ведущий по этому адресу — то есть оказался ли телефон
  /// в его сети. Дёргаем служебный `/ping`: он дешёвый и отвечает `ok`.
  static Future<bool> hostAlive(
    String host, {
    int port = Net.gamePort,
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client
          .getUrl(Uri(scheme: 'http', host: host, port: port, path: '/ping'))
          .timeout(timeout);
      final res = await req.close().timeout(timeout);
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      return res.statusCode == HttpStatus.ok && body.trim() == 'ok';
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
