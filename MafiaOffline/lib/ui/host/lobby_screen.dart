import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/constants.dart';
import '../../core/lobby_plan.dart';
import '../../host/host_controller.dart';
import '../../net/join_code.dart';
import '../../storage/wifi_store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'host_game_screen.dart';
import 'wifi_setup_screen.dart';

/// Лобби: код игры, QR, список подключившихся.
class LobbyScreen extends StatefulWidget {
  final HostController controller;
  const LobbyScreen({super.key, required this.controller});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  HostController get c => widget.controller;

  final _wifiStore = WifiStore();
  WifiConfig _wifi = const WifiConfig();
  bool _wifiEnabled = true;
  bool _wifiCombined = true;

  @override
  void initState() {
    super.initState();
    c.addListener(_update);
    _loadWifi();
  }

  Future<void> _loadWifi() async {
    final cfg = await _wifiStore.load();
    final on = await _wifiStore.isEnabled();
    final combined = await _wifiStore.isCombined();
    if (!mounted) return;
    setState(() {
      _wifi = cfg;
      _wifiEnabled = on;
      _wifiCombined = combined;
    });
  }

  Future<void> _openWifiSetup() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const WifiSetupScreen()),
    );
    await _loadWifi();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_update);
    super.dispose();
  }

  Future<bool> _confirmExit() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text('Закрыть игру?'),
        content: const Text('Сервер будет остановлен, игроки отключатся.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Закрыть', style: TextStyle(color: AppColors.bad)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await c.shutdown();
      return true;
    }
    return false;
  }

  /// Переименование игрока. Имя тут же уходит владельцу и в лобби.
  Future<void> _renameDialog(String playerId, String current) async {
    final ctrl = TextEditingController(text: current);
    String? error;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          backgroundColor: AppColors.panel,
          title: const Text('Изменить имя', style: TextStyle(fontSize: 17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLength: 20,
                decoration: InputDecoration(
                  labelText: 'Имя игрока',
                  counterText: '',
                  errorText: error,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Игрок увидит новое имя сразу. Сам менять имя он не может. '
                'В лобби смена имени никому не видна — партия ещё не началась.',
                style: TextStyle(fontSize: 11.5, color: AppColors.dim),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () {
                final err = c.renamePlayer(playerId, ctrl.text);
                if (err == null) {
                  Navigator.pop(ctx);
                } else {
                  setDialog(() => error = err);
                }
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = c.state;
    if (s == null) return const Scaffold(body: SizedBox.shrink());

    final plan = c.lobbyPlan;
    if (plan == null) return const Scaffold(body: SizedBox.shrink());
    final connected = plan.players;
    final enough = plan.enough;
    final full = plan.full;

    // Вопрос 1 из OPEN_QUESTIONS: старт не блокируем, но показываем имена,
    // которые за столом невозможно различить. Решение остаётся за ведущим.
    final shortNames = s.humans
        .where((p) => p.name.trim().length < 2)
        .map((p) => '«${p.name}»')
        .toList();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Навигатор берём до await: после закрытия диалога context
        // может уже не принадлежать живому виджету.
        final nav = Navigator.of(context);
        if (await _confirmExit() && mounted) {
          nav.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Ожидание игроков'),
          actions: [
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 14),
                child: Text(
                  '$connected/${s.plannedPlayers}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _BotSetupCard(controller: c, plan: plan),
                    const SizedBox(height: 10),
                    _JoinWizard(
                      code: s.code,
                      hostAddress: c.hostAddress,
                      wifi: _wifi,
                      wifiEnabled: _wifiEnabled,
                      combined: _wifiCombined,
                      onEditWifi: _openWifiSetup,
                    ),
                    const SizedBox(height: 4),
                    if (s.players.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 30),
                        child: Center(
                          child: Text(
                            'Пока никто не подключился…',
                            style: TextStyle(color: AppColors.dim),
                          ),
                        ),
                      )
                    else
                      for (final p in s.players)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: PlayerTile(
                            name: p.name,
                            colorHex: p.colorHex,
                            subtitle: p.isBot
                                ? 'бот · играет автоматически'
                                : p.isLocal
                                    ? 'это вы · ведущий тоже играет'
                                    : (p.isConnected ? 'подключён' : 'нет связи'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                StatusDot(p.isBot || p.isLocal || p.isConnected
                                    ? AppColors.ok
                                    : AppColors.bad),
                                IconButton(
                                  tooltip: 'Переименовать',
                                  icon: const Icon(Icons.edit, size: 17),
                                  color: AppColors.dim,
                                  onPressed: () => _renameDialog(p.id, p.name),
                                ),
                                IconButton(
                                  tooltip: 'Исключить',
                                  icon: const Icon(Icons.close, size: 18),
                                  color: AppColors.dim,
                                  onPressed: () => c.kickPlayer(p.id),
                                ),
                              ],
                            ),
                          ),
                        ),
                    if (!full && s.players.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.warn.withAlpha(26),
                          border: Border.all(
                              color: AppColors.warn.withAlpha(102)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          // Ботов не считаем: «ожидаем ещё 4» при четырёх
                          // ботах за столом читалось бы как ошибка.
                          _waitingText(s.plannedPlayers - s.humans.length),
                          style: const TextStyle(
                              fontSize: 12.5, color: Color(0xFFF8C778)),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: Text(plan.startLabel),
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            enough ? AppColors.accent : AppColors.warn,
                      ),
                      onPressed: plan.canStart
                          ? () {
                              c.startGame();
                              Navigator.pushReplacement(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      HostGameScreen(controller: c),
                                ),
                              );
                            }
                          : null,
                    ),
                    if (plan.startHint != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          plan.startHint!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.dim),
                        ),
                      ),
                    if (enough && shortNames.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.warning_amber_rounded,
                                size: 16, color: AppColors.warn),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                'Слишком короткие имена: '
                                '${shortNames.join(', ')}. Переименуйте '
                                'карандашом — за столом их не различить.',
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.warn),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Строка «ждём ещё N человек» со склонением и без ложных обещаний:
/// при пустом лобби фраза про ботов — единственное, что объясняет старт.
String _waitingText(int missingHumans) {
  if (missingHumans <= 0) {
    return 'Стол укомплектован. Можно раздавать роли.';
  }
  // «Ожидаем ещё 1 человека», «ещё 2 человека», «ещё 5 человек»:
  // винительный падеж совпадает с родительным, отдельные формы не нужны.
  return 'Ожидаем ещё $missingHumans ${missingHumans == 1 ? 'человека' : 'человек'}. '
      'Можно начать раньше: '
      'если за столом меньше ${Rules.minPlayers} игроков, свободные места '
      'займут боты. Роли подстроятся под фактический состав.';
}

/// Боты в лобби: путь для одного человека и добор для неполного стола.
class _BotSetupCard extends StatelessWidget {
  final HostController controller;
  final LobbyPlan plan;

  const _BotSetupCard({required this.controller, required this.plan});

  @override
  Widget build(BuildContext context) {
    final s = controller.state;
    if (s == null) return const SizedBox.shrink();
    final local = s.localPlayer;
    final humans = s.humans.length;
    final full = plan.full;
    final enough = plan.enough;

    void error(String text) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: AppColors.bad, content: Text(text)),
      );
    }

    return PanelCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.smart_toy_outlined,
                    size: 20, color: AppColors.accent2),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Не хватает игроков?',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  plan.composition,
                  style: const TextStyle(fontSize: 11.5, color: AppColors.dim),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              local != null
                  ? 'Вы играете как ${local.name}. Роль и ходы будут на этом экране; кнопки ведущего останутся доступными.'
                  : humans == 0
                      ? 'Можно играть одному: вы получите роль, а остальные места займут боты. Либо подключите людей по QR.'
                      : 'Люди остаются за столом, а боты занимают только свободные места и играют по общим правилам.',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.dim, height: 1.35),
            ),
            const SizedBox(height: 10),
            // Стол, забитый ботами, — тоже повод показать кнопку:
            // иначе «Играть одному» исчезает, а партия из автоматов
            // не стартует (см. LobbyPlan.canStart).
            if (local == null && (!full || humans == 0))
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  // person_play появился в Material Symbols позже 3.24.5:
                  // со старым Icons сборка APK не компилируется вовсе,
                  // а CI (analyze) падает с undefined_getter.
                  icon: const Icon(Icons.person_add_alt_1, size: 18),
                  label: Text(humans == 0 ? 'Играть одному' : 'Ведущий тоже играет'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent),
                  onPressed: () {
                    final problem = controller.startSolo();
                    if (problem != null) error(problem);
                  },
                ),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.smart_toy_outlined, size: 17),
                  label: const Text('+1 бот'),
                  // botRoom, а не full: стол мог быть создан «без плана»
                  // (planned == 0), и тогда упереться можно только в 20.
                  onPressed: plan.botRoom == 0
                      ? null
                      : () {
                          if (controller.addBots() == 0) {
                            error('Стол уже заполнен');
                          }
                        },
                ),
                if (!enough && s.players.isNotEmpty)
                  TextButton.icon(
                    icon: const Icon(Icons.group_add, size: 17),
                    label: Text('Добрать до ${Rules.minPlayers}'),
                    onPressed: () =>
                        controller.fillBotsTo(Rules.minPlayers),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Мастер подключения.
///
/// Первым показывается ЕДИНЫЙ КОД: сеть Wi-Fi и вход в игру в одном QR
/// (см. `JoinCode`). Приложению «Мафия» его хватает целиком — одно
/// сканирование, и игрок за столом. Камера телефона видит в нём обычный
/// код сети и подключает к Wi-Fi; войти в игру через браузер она по нему
/// не может — один QR для камеры означает одно действие. Для таких
/// игроков остаётся вторая вкладка со ссылкой на игру.
///
/// Почему вкладки, а не два кода рядом: люди сканируют то, что видят,
/// и не читают подписи. Два кода на одном экране гарантированно приводят
/// к тому, что половина стола отсканирует не тот. Показываем строго один,
/// а переход ко второму — осознанное действие ведущего.
class _JoinWizard extends StatefulWidget {
  final String code;
  final String? hostAddress;
  final WifiConfig wifi;
  final bool wifiEnabled;

  /// Добавлять ли в код сети номер игры (единый код).
  final bool combined;
  final VoidCallback onEditWifi;

  const _JoinWizard({
    required this.code,
    required this.hostAddress,
    required this.wifi,
    required this.wifiEnabled,
    required this.combined,
    required this.onEditWifi,
  });

  @override
  State<_JoinWizard> createState() => _JoinWizardState();
}

class _JoinWizardState extends State<_JoinWizard> {
  /// 0 — единый код (или код сети), 1 — ссылка на игру для браузера.
  int _step = 0;

  bool get _hasWifiStep => widget.wifiEnabled && widget.wifi.isUsable;

  /// Единый код показываем, только когда есть что в него положить.
  bool get _single => _hasWifiStep && widget.combined;

  /// Содержимое первого кода: сеть вместе с игрой или только сеть.
  String get _wifiPayload => _single
      ? JoinCode.build(
          wifi: widget.wifi,
          code: widget.code,
          host: widget.hostAddress,
        )
      : widget.wifi.toQrPayload();

  String get _gameUrl =>
      'http://${widget.hostAddress ?? ''}:${Net.gamePort}/?g=${widget.code}';

  @override
  Widget build(BuildContext context) {
    // Шага Wi-Fi нет — сразу показываем ссылку на игру.
    final step = _hasWifiStep ? _step : 1;

    return PanelCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        child: Column(
          children: [
            if (_hasWifiStep) _stepTabs(),
            if (_hasWifiStep) const SizedBox(height: 14),
            if (step == 0) _wifiStep() else _gameStep(),
          ],
        ),
      ),
    );
  }

  Widget _stepTabs() {
    Widget tab(int i, String label, IconData icon) {
      final active = _step == i;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _step = i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: active ? AppColors.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 16,
                    color: active ? Colors.white : AppColors.dim),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: active ? FontWeight.bold : FontWeight.normal,
                    color: active ? Colors.white : AppColors.dim,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          tab(0, _single ? 'Один код' : '1. Сеть',
              _single ? Icons.qr_code_2 : Icons.wifi),
          tab(1, _single ? 'Для браузера' : '2. Игра',
              _single ? Icons.public : Icons.sports_esports),
        ],
      ),
    );
  }

  Widget _wifiStep() {
    final w = widget.wifi;
    return Column(
      children: [
        Text(
          _single
              ? 'Один код — и сеть, и вход в игру'
              : 'Шаг 1 — подключиться к сети',
          style: const TextStyle(fontSize: 13, color: AppColors.dim),
        ),
        const SizedBox(height: 10),
        _QrBox(
          data: _wifiPayload,
          label: _single
              ? 'Единый код: Wi-Fi ${w.ssid} и игра ${widget.code}'
              : 'Wi-Fi: ${w.ssid}',
        ),
        const SizedBox(height: 10),
        Text(
          w.ssid,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        if (w.security != WifiSecurity.open)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SelectableText(
              'пароль: ${w.password}',
              style: const TextStyle(fontSize: 14, color: AppColors.accent2),
            ),
          ),
        const SizedBox(height: 10),
        Text(
          _single
              ? 'В приложении «Мафия»: «Я игрок» → «Сканировать QR» — '
                  'телефон сам подключится к сети и войдёт в игру.\n'
                  'Камерой телефона: код подключит к Wi-Fi, '
                  'вход в игру — на вкладке «Для браузера».'
              : 'Наведите камеру — телефон предложит подключиться.\n'
                  'Если не сработало, введите пароль вручную.',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 11.5, color: AppColors.dim, height: 1.35),
        ),
        const SizedBox(height: 10),
        if (_single) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.fullscreen, size: 18),
              label: const Text('Показать крупно',
                  style: TextStyle(fontSize: 12.5)),
              onPressed: () => _showFullscreen(
                context,
                data: _wifiPayload,
                note: 'Wi-Fi: ${w.ssid}',
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('Изменить', style: TextStyle(fontSize: 12.5)),
                onPressed: widget.onEditWifi,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: _single
                  ? OutlinedButton.icon(
                      icon: const Icon(Icons.public, size: 16),
                      label: const Text('Вход через браузер',
                          style: TextStyle(fontSize: 12.5)),
                      onPressed: () => setState(() => _step = 1),
                    )
                  : ElevatedButton.icon(
                      icon: const Icon(Icons.arrow_forward, size: 16),
                      label: const Text('Все подключились',
                          style: TextStyle(fontSize: 12.5)),
                      onPressed: () => setState(() => _step = 1),
                    ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _gameStep() {
    final noAddress = widget.hostAddress == null;

    return Column(
      children: [
        Text(
          _single
              ? 'Вход через браузер — после подключения к сети'
              : (_hasWifiStep ? 'Шаг 2 — войти в игру' : 'Код игры'),
          style: const TextStyle(fontSize: 13, color: AppColors.dim),
        ),
        const SizedBox(height: 4),
        Text(
          widget.code,
          style: const TextStyle(
            fontSize: 38,
            fontWeight: FontWeight.bold,
            letterSpacing: 8,
          ),
        ),
        const SizedBox(height: 10),
        if (noAddress)
          const InfoCard(
            icon: Icons.wifi_off,
            text: 'Адрес не определён. Включите Wi-Fi или точку доступа '
                'и перезапустите игру.',
            color: AppColors.bad,
          )
        else ...[
          _QrBox(data: _gameUrl, label: 'Ссылка на игру'),
          const SizedBox(height: 10),
          SelectableText(
            'http://${widget.hostAddress}:${Net.gamePort}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.accent2,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Игра открывается прямо в браузере — устанавливать\n'
            'ничего не нужно. Работает на iPhone и Android.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: AppColors.dim, height: 1.35),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (_hasWifiStep)
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: Text(_single ? 'Один код' : 'К сети',
                        style: const TextStyle(fontSize: 12.5)),
                    onPressed: () => setState(() => _step = 0),
                  ),
                ),
              if (_hasWifiStep) const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.fullscreen, size: 18),
                  label: const Text('Показать крупно',
                      style: TextStyle(fontSize: 12.5)),
                  onPressed: () => _showFullscreen(context, data: _gameUrl),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Крупный QR во весь экран: ведущий поднимает телефон, и код сканируют
  /// сразу несколько человек с расстояния метра-двух.
  ///
  /// [note] — подпись под номером игры (для единого кода — имя сети).
  void _showFullscreen(BuildContext context,
      {required String data, String? note}) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (ctx) {
        final side = MediaQuery.of(ctx).size.width * 0.82;
        return GestureDetector(
          onTap: () => Navigator.pop(ctx),
          child: Container(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: QrImageView(
                      data: data,
                      size: side,
                      backgroundColor: Colors.white,
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    widget.code,
                    style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 8,
                      color: Colors.white,
                    ),
                  ),
                  if (note != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      note,
                      style:
                          const TextStyle(fontSize: 14, color: Colors.white70),
                    ),
                  ],
                  const SizedBox(height: 6),
                  const Text(
                    'нажмите, чтобы закрыть',
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// QR в белой рамке. Белый фон обязателен: на тёмном коды читаются плохо,
/// а на телефонах с автояркостью — почти никак.
class _QrBox extends StatelessWidget {
  final String data;
  final String label;
  const _QrBox({required this.data, required this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: QrImageView(
          data: data,
          size: 172,
          backgroundColor: Colors.white,
          // Средний уровень коррекции: код остаётся читаемым, даже если
          // на экран падает блик или его частично заслонили пальцем.
          errorCorrectionLevel: QrErrorCorrectLevel.M,
        ),
      ),
    );
  }
}
