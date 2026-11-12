import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../net/client_connection.dart';
import '../../net/discovery.dart';
import '../../net/protocol.dart';
import '../../net/wifi_joiner.dart';
import '../../player/player_controller.dart';
import '../../storage/wifi_store.dart';
import '../rules_screen.dart';
import '../theme.dart';
import 'player_game_screen.dart';
import 'qr_scan_screen.dart';

/// Подключение игрока: код игры + имя. IP находится автоматически.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

/// Что происходит с сетью после сканирования единого кода.
enum _NetStage {
  /// Единый код не сканировали — карточки сети на экране нет.
  none,

  /// Проверяем, не в сети ли ведущего телефон уже сейчас.
  probing,

  /// Открыто системное окно «Сохранить сеть?».
  asking,

  /// Сеть сохранена, ждём, пока телефон к ней подключится.
  waiting,

  /// Само не подключилось: показываем имя сети и пароль.
  manual,

  /// Ведущий отвечает — можно входить.
  online,
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

  /// Сеть ведущего из единого кода и ход подключения к ней.
  WifiConfig? _wifi;
  _NetStage _net = _NetStage.none;

  /// Идёт ли ещё опрос ведущего. Когда он остановлен, карточка перестаёт
  /// обещать, что игра «найдётся сама».
  bool _netPolling = false;

  /// Номер попытки: новое сканирование отменяет прежний опрос.
  int _netRun = 0;

  /// Сколько ждать автоматического подключения, прежде чем показать
  /// имя сети и пароль, и когда прекратить опрос совсем.
  static const _autoWait = Duration(seconds: 12);
  static const _giveUp = Duration(minutes: 3);

  @override
  void dispose() {
    _netRun++;
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

    // Имя введено заранее — после сканирования входим без лишнего нажатия.
    // Запоминаем это сейчас: пока телефон подключается к сети, игрок может
    // начать набирать имя, и входить с половиной имени нельзя.
    final nameReady = _nameCtrl.text.trim().isNotEmpty;

    setState(() {
      _codeCtrl.text = result.code;
      _error = null;
      // Новый код отменяет адрес из прежнего: иначе после кода другой игры
      // мы стучались бы к старому ведущему.
      _scannedHost = result.host;
      if (result.host != null) _hostCtrl.text = result.host!;
      _wifi = result.wifi;
      _net = _NetStage.none;
      _netPolling = false;
    });
    _netRun++;

    // Единый код: сначала сеть, потом игра.
    if (result.wifi != null) {
      final online = await _ensureNetwork(result);
      if (!mounted || !online) return;
    }

    if (nameReady && _nameCtrl.text.trim().isNotEmpty && !_busy) {
      await _join();
    }
  }

  /// Отвечает ли ведущий. Если адреса в коде нет — ищем игру по сети
  /// и запоминаем найденный адрес.
  Future<bool> _hostReachable(ScannedGame game) async {
    final host = _scannedHost;
    if (host != null) return WifiJoiner.hostAlive(host, port: game.port);

    final found = await DiscoveryService.findHost(
      code: game.code,
      timeout: const Duration(milliseconds: 1500),
    );
    if (found == null) return false;
    _scannedHost = found.address;
    return true;
  }

  /// Подключение к сети из единого кода. Возвращает `true`, когда ведущий
  /// начал отвечать.
  ///
  /// Порядок:
  ///   1. телефон уже в нужной сети — ничего не спрашиваем;
  ///   2. иначе просим систему сохранить сеть и подключиться;
  ///   3. опрашиваем ведущего раз в секунду. Не важно, как телефон попадёт
  ///      в сеть — сам, или игрок выберет её вручную, — вход продолжится.
  Future<bool> _ensureNetwork(ScannedGame game) async {
    final wifi = game.wifi;
    if (wifi == null) return true;

    final run = _netRun;
    bool stale() => !mounted || run != _netRun;

    setState(() {
      _net = _NetStage.probing;
      _netPolling = true;
    });
    if (await _hostReachable(game)) {
      if (stale()) return false;
      setState(() {
        _net = _NetStage.online;
        _netPolling = false;
      });
      return true;
    }
    if (stale()) return false;

    setState(() => _net = _NetStage.asking);
    final added = await WifiJoiner.addNetwork(wifi);
    if (stale()) return false;

    // Только после свежего сохранения система подключается сама.
    // Во всех остальных случаях сразу показываем, что делать руками.
    final auto = added == WifiJoinResult.saved;
    setState(() => _net = auto ? _NetStage.waiting : _NetStage.manual);

    final started = DateTime.now();
    while (true) {
      if (await _hostReachable(game)) {
        if (stale()) return false;
        setState(() {
          _net = _NetStage.online;
          _netPolling = false;
        });
        return true;
      }
      if (stale()) return false;

      final waited = DateTime.now().difference(started);
      if (waited > _giveUp) {
        setState(() {
          _net = _NetStage.manual;
          _netPolling = false;
        });
        return false;
      }
      if (_net == _NetStage.waiting && waited > _autoWait) {
        setState(() => _net = _NetStage.manual);
      }

      await Future<void>.delayed(const Duration(seconds: 1));
      if (stale()) return false;
    }
  }

  Future<void> _openWifiSettings() async {
    final ok = await WifiJoiner.openWifiSettings();
    if (!mounted) return;
    if (ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Откройте настройки Wi-Fi телефона вручную'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _copyWifiPassword(String password) {
    Clipboard.setData(ClipboardData(text: password));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Пароль скопирован'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Карточка сети под кнопкой сканирования: что сейчас происходит
  /// и что делать, если телефон не подключился сам.
  Widget _netCard() {
    final wifi = _wifi;
    if (wifi == null || _net == _NetStage.none) return const SizedBox.shrink();

    final name = '«${wifi.ssid}»';
    final hasPassword = wifi.security != WifiSecurity.open;

    late final String title;
    late final Color color;
    var spinner = true;

    // Подсказка для ручного подключения. Про мобильный интернет — не зря:
    // у сети ведущего нет выхода в интернет, и часть телефонов продолжает
    // слать запросы через сотовую связь, хотя Wi-Fi уже подключён.
    final manualHint = StringBuffer(
        'Откройте Wi-Fi и выберите сеть $name');
    if (hasPassword) manualHint.write(' — если спросит пароль, он ниже');
    manualHint.write('. ');
    manualHint.write(_netPolling
        ? 'Игра найдётся сама, как только телефон окажется в сети. '
            'Сеть подключена, а игры нет — выключите мобильный интернет.'
        : 'Затем нажмите «Подключиться».');

    switch (_net) {
      case _NetStage.none:
      case _NetStage.probing:
        title = 'Проверяем сеть…';
        color = AppColors.accent2;
      case _NetStage.asking:
        title = 'Сеть $name: подтвердите сохранение в окне телефона';
        color = AppColors.accent2;
      case _NetStage.waiting:
        title = 'Подключаемся к сети $name…';
        color = AppColors.accent2;
      case _NetStage.manual:
        title = 'Подключитесь к сети $name';
        color = AppColors.warn;
        spinner = _netPolling;
      case _NetStage.online:
        title = 'Вы в сети ведущего';
        color = AppColors.ok;
        spinner = false;
    }

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        border: Border.all(color: color.withAlpha(102)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (spinner)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: color),
                )
              else
                Icon(
                  _net == _NetStage.online ? Icons.check_circle : Icons.wifi,
                  size: 18,
                  color: color,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (_net == _NetStage.manual) ...[
            const SizedBox(height: 8),
            Text(
              manualHint.toString(),
              style: const TextStyle(
                  fontSize: 12.5, color: AppColors.dim, height: 1.35),
            ),
            if (hasPassword) ...[
              const SizedBox(height: 6),
              SelectableText(
                'пароль: ${wifi.password}',
                style:
                    const TextStyle(fontSize: 14, color: AppColors.accent2),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.wifi, size: 16),
                    label: const Text('Открыть Wi-Fi',
                        style: TextStyle(fontSize: 12.5)),
                    onPressed: _openWifiSettings,
                  ),
                ),
                if (hasPassword) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Пароль',
                          style: TextStyle(fontSize: 12.5)),
                      onPressed: () => _copyWifiPassword(wifi.password),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
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
      appBar: AppBar(
        title: const Text('Подключение к игре'),
        actions: [
          // Правила доступны до входа: новичок должен понять игру, а не
          // разбираться в ней уже за столом, когда все ждут.
          IconButton(
            tooltip: 'Правила и роли',
            icon: const Icon(Icons.menu_book_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RulesScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 20),
            const Center(child: Text('📱', style: TextStyle(fontSize: 54))),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'Отсканируйте код ведущего или введите его цифры',
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
            _netCard(),
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
