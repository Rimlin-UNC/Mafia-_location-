import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Удержание партии живой, когда экран ведущего погас.
///
/// Android агрессивно усыпляет приложения в фоне: через несколько секунд
/// после выключения экрана процесс замораживается, WebSocket-соединения
/// рвутся, и все игроки отваливаются. Единственный надёжный способ этого
/// избежать — служба переднего плана (foreground service) с постоянным
/// уведомлением. Пока оно висит в шторке, система не трогает процесс.
///
/// Дополнительно держим wakelock, чтобы экран не гас во время партии,
/// пока телефон лежит на столе.
class HostBackground {
  static bool _active = false;
  static bool get isActive => _active;

  /// Инициализация службы. Вызывается один раз при старте приложения.
  static void init() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      FlutterForegroundTask.initCommunicationPort();
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'mafia_host',
          channelName: 'Сервер игры «Мафия»',
          channelDescription:
              'Уведомление держит партию активной при выключенном экране.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(30000),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: true, // Wi-Fi не должен засыпать — на нём вся связь
        ),
      );
    } catch (e) {
      debugPrint('HostBackground.init: $e');
    }
  }

  /// Запуск службы при создании партии.
  static Future<void> start({
    required String gameName,
    required String code,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      // Экран не гаснет, пока идёт партия.
      await WakelockPlus.enable();

      if (Platform.isAndroid) {
        final permission =
            await FlutterForegroundTask.checkNotificationPermission();
        if (permission != NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.restartService();
        } else {
          await FlutterForegroundTask.startService(
            notificationTitle: 'Идёт игра: $gameName',
            notificationText: 'Код $code · сервер работает',
            callback: _startCallback,
          );
        }
      }
      _active = true;
    } catch (e) {
      debugPrint('HostBackground.start: $e');
    }
  }

  /// Обновление текста уведомления — например, при смене фазы.
  static Future<void> update({
    required String title,
    required String text,
  }) async {
    if (!_active || !Platform.isAndroid) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    } catch (_) {}
  }

  /// Остановка службы по окончании партии.
  static Future<void> stop() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await WakelockPlus.disable();
      if (Platform.isAndroid) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      debugPrint('HostBackground.stop: $e');
    } finally {
      _active = false;
    }
  }
}

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_HostTaskHandler());
}

/// Обработчик фоновой задачи.
///
/// Сам сервер живёт в основном изоляте — здесь ничего делать не нужно.
/// Задача существует лишь ради того, чтобы Android считал приложение
/// активным и не замораживал его.
class _HostTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
