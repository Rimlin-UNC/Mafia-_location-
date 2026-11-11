import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../net/join_code.dart';
import '../theme.dart';

export '../../net/join_code.dart' show ScannedGame;

/// Экран сканирования QR-кода.
///
/// Ведущий показывает один из двух кодов:
///   * единый код `WIFI:…;G:482913@192.168.43.1;;` — в нём и сеть, и игра;
///     экран входа сам подключит телефон к Wi-Fi и войдёт в игру;
///   * ссылку `http://192.168.43.1:8088/?g=482913` — только игра.
/// В обоих случаях мы забираем и номер игры, и адрес хоста — значит
/// подключение произойдёт без поиска по сети. Сам разбор — в `ScannedGame`.
///
/// ВАЖНО по устройству экрана (версия 1.0.3):
/// в 1.0.2 приложение падало при открытии сканера. Причин было три, и все
/// устранены здесь:
///   1. разрешение камеры не запрашивалось — теперь спрашиваем ДО создания
///      контроллера и показываем понятный экран при отказе;
///   2. контроллер создавался в поле класса и никогда не запускался —
///      теперь создаётся после выдачи разрешения и стартует явно;
///   3. не обрабатывался жизненный цикл — при сворачивании приложения
///      камера оставалась занятой. Теперь останавливаем и возобновляем.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

enum _Stage { checking, denied, ready, failed }

class _QrScanScreenState extends State<QrScanScreen>
    with WidgetsBindingObserver {
  MobileScannerController? _controller;
  StreamSubscription<BarcodeCapture>? _sub;

  _Stage _stage = _Stage.checking;
  bool _handled = false;
  bool _torchOn = false;
  String? _error;
  String? _fatal;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prepare();
  }

  /// Запрос разрешения и запуск камеры.
  ///
  /// Всё обёрнуто в try/catch: на некоторых устройствах камера может быть
  /// занята другим приложением или отсутствовать вовсе. Такие случаи должны
  /// приводить к понятному экрану, а не к закрытию приложения.
  Future<void> _prepare() async {
    try {
      var status = await Permission.camera.status;
      if (status.isDenied) {
        status = await Permission.camera.request();
      }

      if (!mounted) return;

      if (!status.isGranted) {
        setState(() => _stage = _Stage.denied);
        return;
      }

      final controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        facing: CameraFacing.back,
        // Явно отключаем автозапуск: стартуем сами и ловим ошибки.
        autoStart: false,
      );
      _controller = controller;
      _sub = controller.barcodes.listen(_onDetect, onError: (_) {});

      await controller.start();
      if (!mounted) return;
      setState(() => _stage = _Stage.ready);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _fatal = '$e';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    // Пока контроллер не готов, трогать его нельзя: диалог разрешения
    // сам вызывает смену жизненного цикла.
    if (controller == null || _stage != _Stage.ready) return;

    switch (state) {
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        return;
      case AppLifecycleState.resumed:
        _sub ??= controller.barcodes.listen(_onDetect, onError: (_) {});
        controller.start().catchError((_) {});
      case AppLifecycleState.inactive:
        _sub?.cancel();
        _sub = null;
        controller.stop().catchError((_) {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _sub = null;
    // Контроллер освобождаем после super.dispose(), как требует пакет.
    final controller = _controller;
    _controller = null;
    super.dispose();
    controller?.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled || !mounted) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;

      final parsed = ScannedGame.tryParse(raw);
      if (parsed != null) {
        _handled = true;
        Navigator.pop(context, parsed);
        return;
      }
      // Код сети без номера игры: ведущий выключил «единый код».
      // Говорим об этом прямо — иначе игрок будет сканировать его снова.
      final wifiOnly = JoinCode.parse(raw) != null;
      setState(() => _error = wifiOnly
          ? 'Это код сети Wi-Fi, игры в нём нет. Подключитесь к сети '
              'и наведите на второй код ведущего.'
          : 'Это не код игры «Мафия». Наведите на QR ведущего.');
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Сканирование кода'),
        actions: [
          if (_stage == _Stage.ready)
            IconButton(
              tooltip: 'Фонарик',
              icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
              onPressed: () async {
                try {
                  await _controller?.toggleTorch();
                  if (mounted) setState(() => _torchOn = !_torchOn);
                } catch (_) {
                  // Фонарика может не быть — это не повод падать.
                }
              },
            ),
        ],
      ),
      body: switch (_stage) {
        _Stage.checking => _message(
            icon: Icons.photo_camera,
            title: 'Запрашиваем доступ к камере…',
            text: 'Разрешите доступ, чтобы отсканировать код ведущего.',
            spinner: true,
          ),
        _Stage.denied => _message(
            icon: Icons.no_photography,
            title: 'Нет доступа к камере',
            text: 'Разрешение не выдано. Его можно включить в настройках '
                'телефона — или просто ввести код игры вручную.',
            primary: ('Открыть настройки', openAppSettings),
          ),
        _Stage.failed => _message(
            icon: Icons.error_outline,
            title: 'Камера недоступна',
            text: 'Не удалось запустить камеру. Возможно, её занимает другое '
                'приложение. Введите код игры вручную.\n\n${_fatal ?? ''}',
          ),
        _Stage.ready => _scanner(),
      },
    );
  }

  Widget _scanner() {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();

    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: controller,
          errorBuilder: (context, error, child) => _message(
            icon: Icons.no_photography,
            title: 'Ошибка камеры',
            text: 'Введите код игры вручную.\n\n${error.errorCode.name}',
          ),
        ),
        IgnorePointer(
          child: Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.accent2, width: 3),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 40,
          child: Column(
            children: [
              if (_error != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.bad.withAlpha(220),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(190),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Наведите камеру на QR-код на экране ведущего',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(backgroundColor: Colors.black54),
                icon: const Icon(Icons.keyboard),
                label: const Text('Ввести код вручную'),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Единый экран состояния: ожидание, отказ, ошибка.
  Widget _message({
    required IconData icon,
    required String title,
    required String text,
    bool spinner = false,
    (String, VoidCallback)? primary,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 48, color: AppColors.dim),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.dim),
            ),
            if (spinner) ...[
              const SizedBox(height: 22),
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ],
            const SizedBox(height: 24),
            if (primary != null) ...[
              ElevatedButton(
                onPressed: primary.$2,
                child: Text(primary.$1),
              ),
              const SizedBox(height: 10),
            ],
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Ввести код вручную'),
            ),
          ],
        ),
      ),
    );
  }
}
