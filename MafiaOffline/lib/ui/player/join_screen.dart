import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../net/client_connection.dart';
import '../../net/protocol.dart';
import '../../player/player_controller.dart';
import '../theme.dart';
import 'player_game_screen.dart';
import 'qr_scan_screen.dart';

/// Подключение игрока: код игры + имя. IP находится автоматически.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _codeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();

  PlayerController? _controller;
  bool _busy = false;
  bool _showManual = false;
  String? _error;

  /// Адрес хоста, полученный из QR — с ним подключение мгновенное,
  /// без поиска по сети.
  String? _scannedHost;

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    super.dispose();
  }

  /// Сканирование QR ведущего. Код и адрес хоста подставляются сами,
  /// игроку остаётся только ввести имя.
  Future<void> _scanQr() async {
    final result = await Navigator.push<ScannedGame>(
      context,
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result == null || !mounted) return;

    setState(() {
      _codeCtrl.text = result.code;
      _error = null;
      if (result.host != null) {
        _hostCtrl.text = result.host!;
        _scannedHost = result.host;
      }
    });

    // Имя уже введено — подключаемся сразу, без лишнего нажатия.
    if (_nameCtrl.text.trim().isNotEmpty) {
      await _join();
    }
  }

  Future<void> _join() async {
    final code = _codeCtrl.text.trim();
    final name = _nameCtrl.text.trim();

    if (code.length != 6) {
      setState(() => _error = 'Код должен состоять из 6 цифр');
      return;
    }
    if (name.isEmpty) {
      setState(() => _error = 'Введите имя');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final controller = PlayerController();
    _controller = controller;

    final ok = await controller.join(
      code: code,
      name: name,
      manualHost: _scannedHost ??
          (_showManual ? _hostCtrl.text.trim() : null),
    );

    if (!mounted) return;

    if (!ok) {
      setState(() {
        _busy = false;
        _showManual = true;
        _error = 'Игра не найдена. Проверьте, что вы в одной сети '
            'с телефоном ведущего, или введите его адрес вручную.';
      });
      controller.dispose();
      _controller = null;
      return;
    }

    // Ждём ответ сервера: registerOk или отказ.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;

    final denied = controller.deniedReason;
    if (denied != null) {
      setState(() {
        _busy = false;
        _error = _denyText(denied);
      });
      controller.dispose();
      _controller = null;
      return;
    }

    setState(() => _busy = false);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerGameScreen(controller: controller),
      ),
    );
  }

  String _denyText(String reason) {
    switch (reason) {
      case DenyReason.nameTaken:
        return 'Это имя уже занято — выберите другое';
      case DenyReason.gameFull:
        return 'В игре нет свободных мест';
      case DenyReason.gameStarted:
        return 'Игра уже началась';
      case DenyReason.badVersion:
        return 'Версия игры не совпадает с ведущим. Обновите страницу '
            'или приложение — и подключитесь снова.';
      default:
        return 'Не удалось подключиться';
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _controller?.status;

    return Scaffold(
      appBar: AppBar(title: const Text('Подключение к игре')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 20),
            const Center(child: Text('📱', style: TextStyle(fontSize: 54))),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'Введите код, который показывает ведущий',
                style: TextStyle(color: AppColors.dim, fontSize: 13),
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _codeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(
                  fontSize: 28, letterSpacing: 10, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                labelText: 'Код игры',
                counterText: '',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Сканировать QR'),
                    onPressed: _busy ? null : _scanQr,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _nameCtrl,
              maxLength: 20,
              decoration: const InputDecoration(
                labelText: 'Ваше имя',
                counterText: '',
              ),
            ),
            if (_showManual) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _hostCtrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Адрес ведущего (например 192.168.43.1)',
                  helperText: 'Показан на экране ведущего под QR-кодом',
                  helperStyle: TextStyle(fontSize: 11),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (_error != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.bad.withAlpha(31),
                  border:
                      Border.all(color: AppColors.bad.withAlpha(102)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_error!,
                    style: const TextStyle(fontSize: 13, color: Color(0xFFFF9AA4))),
              ),
            if (_busy)
              Column(
                children: [
                  const LinearProgressIndicator(),
                  const SizedBox(height: 10),
                  Text(
                    status == ConnStatus.searching
                        ? 'Ищем игру в локальной сети…'
                        : 'Подключаемся…',
                    style:
                        const TextStyle(fontSize: 12.5, color: AppColors.dim),
                  ),
                ],
              )
            else
              ElevatedButton(
                onPressed: _join,
                child: const Text('Подключиться'),
              ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.panel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.line),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 18, color: AppColors.accent2),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Интернет не нужен. Подключитесь к той же сети Wi-Fi, '
                      'что и ведущий, — или к раздаче с его телефона.',
                      style: TextStyle(fontSize: 12.5, color: AppColors.dim),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
