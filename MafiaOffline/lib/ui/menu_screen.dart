import 'package:flutter/material.dart';

import '../core/assets.dart';
import '../host/host_controller.dart';
import '../services/audio_service.dart';
import '../player/player_controller.dart';
import '../storage/app_prefs.dart';
import '../storage/player_session_store.dart';
import '../storage/session_store.dart';
import 'history_screen.dart';
import 'host/host_game_screen.dart';
import 'host/setup_screen.dart';
import 'player/join_screen.dart';
import 'player/player_game_screen.dart';
import 'offer_screen.dart';
import 'role_card_view.dart';
import 'rules_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  final _session = SessionStore();
  final _playerSession = PlayerSessionStore();

  bool _hasSession = false;
  bool _restoring = false;

  /// Сохранённая партия игрока: он уже вошёл под своим именем.
  PlayerSession? _mySession;
  bool _rejoining = false;

  /// Показывать ли кнопку «Я игрок». По умолчанию скрыта: основной способ
  /// для игроков — браузер. Включается в настройках звука/приложения.
  bool _playerModeVisible = false;

  /// Автозапуск первой ночи (настройка ведущего).
  bool _autoStartNight = true;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final has = await _session.hasSession();
    final mine = await _playerSession.load();
    final showPlayer = await AppPrefs.playerModeVisible();
    final autoNight = await AppPrefs.autoStartFirstNight();
    if (mounted) {
      setState(() {
        _hasSession = has;
        _mySession = mine;
        _playerModeVisible = showPlayer;
        _autoStartNight = autoNight;
      });
    }
  }

  /// Возврат в свою партию без повторной регистрации.
  ///
  /// Без этого игрок, вернувшийся на стартовый экран, снова видел форму
  /// «введите имя» и заводил второй профиль: у ведущего появлялись дубли,
  /// а рабочим оставался только последний.
  Future<void> _rejoin() async {
    final s = _mySession;
    if (s == null || _rejoining) return;
    setState(() => _rejoining = true);

    final controller = PlayerController();
    final ok = await controller.join(
      code: s.code,
      name: s.name,
      manualHost: s.host,
    );
    if (!mounted) return;

    if (!ok) {
      setState(() => _rejoining = false);
      controller.dispose();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppColors.bad,
          content: Text('Игра не найдена. Возможно, ведущий её закрыл.'),
        ),
      );
      return;
    }

    // Ждём ответ: приняли нас обратно или отказали.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    setState(() => _rejoining = false);

    final denied = controller.deniedReason;
    if (denied != null) {
      controller.dispose();
      await _playerSession.clear();
      await _checkSession();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppColors.bad,
          content: Text('Вернуться не удалось — партия недоступна.'),
        ),
      );
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => PlayerGameScreen(controller: controller)),
    );
    await _checkSession();
  }

  Future<void> _forgetMySession() async {
    await _playerSession.clear();
    await _checkSession();
  }

  /// Восстановление прерванной партии.
  Future<void> _restore() async {
    setState(() => _restoring = true);
    final controller = HostController();
    final ok = await controller.restoreGame();
    if (!mounted) return;
    setState(() => _restoring = false);

    if (!ok) {
      controller.dispose();
      await _checkSession();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.bad,
          content: Text(controller.lastError ?? 'Не удалось восстановить партию'),
        ),
      );
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => HostGameScreen(controller: controller)),
    );
    await _checkSession();
  }

  Future<void> _discard() async {
    await _session.clear();
    await _checkSession();
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Настройки',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Звук',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
              SwitchListTile(
                value: AudioService.instance.soundEnabled,
                onChanged: (v) async {
                  await AudioService.instance.setSound(v);
                  setSheet(() {});
                },
                title: const Text('Звуки событий'),
                subtitle: const Text('Убийство, рассвет, голосование',
                    style: TextStyle(fontSize: 12, color: AppColors.dim)),
                activeColor: AppColors.accent2,
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                value: AudioService.instance.musicEnabled,
                onChanged: (v) async {
                  await AudioService.instance.setMusic(v);
                  setSheet(() {});
                },
                title: const Text('Атмосферный фон'),
                subtitle: const Text('Тревожный гул ночи, гомон дня',
                    style: TextStyle(fontSize: 12, color: AppColors.dim)),
                activeColor: AppColors.accent2,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 8),
              const Text(
                'Звук синхронизирован: событие звучит на всех телефонах '
                'одновременно, независимо от того, у кого какие часы.',
                style: TextStyle(fontSize: 11.5, color: AppColors.dim),
              ),

              const Divider(height: 28, color: AppColors.line),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Дополнительно',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
              SwitchListTile(
                value: _autoStartNight,
                onChanged: (v) async {
                  await AppPrefs.setAutoStartFirstNight(v);
                  setSheet(() {});
                  if (mounted) setState(() => _autoStartNight = v);
                },
                title: const Text('Начинать первую ночь автоматически'),
                subtitle: const Text(
                  'Когда все прочитали роль — ночь начинается сама. '
                  'Если выключить, ведущий нажмёт кнопку сам; ночь всё '
                  'равно не начнётся, пока кто-то не подтвердил роль.',
                  style: TextStyle(fontSize: 12, color: AppColors.dim),
                ),
                activeColor: AppColors.accent2,
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                value: _playerModeVisible,
                onChanged: (v) async {
                  await AppPrefs.setPlayerModeVisible(v);
                  setSheet(() {});
                  if (mounted) setState(() => _playerModeVisible = v);
                },
                title: const Text('Режим игрока в приложении'),
                subtitle: const Text(
                  'Запасной путь, если у кого-то не открывается браузер. '
                  'Обычно игроки заходят по QR-коду.',
                  style: TextStyle(fontSize: 12, color: AppColors.dim),
                ),
                activeColor: AppColors.accent2,
                contentPadding: EdgeInsets.zero,
              ),

              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Закрыть'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PhaseBackground(
        asset: A.bgNight,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            // Меню стало выше одного экрана (добавились «Правила и роли»),
            // поэтому прокручиваем: на низких экранах Column со Spacer
            // давала overflow. Spacer внутри прокрутки невозможен —
            // высота не ограничена, поэтому вместо него фиксированный отступ.
            child: SingleChildScrollView(
              child: Column(
                children: [
                  const SizedBox(height: 26),
                  const Text('🎭', style: TextStyle(fontSize: 60)),
                  const SizedBox(height: 8),
                  const Text(
                    'Мафия Offline',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Игра по локальной сети · интернет не нужен',
                    style: TextStyle(color: AppColors.dim, fontSize: 13),
                  ),
                  const SizedBox(height: 22),

                  // Баннер восстановления прерванной партии.
                  if (_hasSession)
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.warn.withAlpha(30),
                        border: Border.all(color: AppColors.warn.withAlpha(120)),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.restore, color: AppColors.warn, size: 20),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Найдена незавершённая партия',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Можно продолжить с того же места: роли, живые '
                            'игроки и лог сохранены. Игроки переподключатся сами.'
                            '\nНовая партия удалит это сохранение — сначала '
                            'завершите или забудьте старую.',
                            style: TextStyle(fontSize: 12, color: AppColors.dim),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.warn,
                                    minimumSize: const Size.fromHeight(42),
                                  ),
                                  onPressed: _restoring ? null : _restore,
                                  child: _restoring
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : const Text('Продолжить'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size.fromHeight(42),
                                  ),
                                  onPressed: _restoring ? null : _discard,
                                  child: const Text('Забыть',
                                      style: TextStyle(fontSize: 13)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 18),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.podcasts),
                    label: const Text('Я ведущий — создать игру'),
                    onPressed: () async {
                      // Новая партия затирает сохранение старой (SessionStore
                      // перезапишется при первом же изменении состояния).
                      // Раньше об этом нигде не говорилось — ведущий узнавал
                      // постфактум, когда «Продолжить» пропадало.
                      if (_hasSession) {
                        // Навигатор берём до await: после диалога context
                        // может уже не принадлежать живому виджету, а
                        // анализатор справедливо требует mounted у State.
                        final nav = Navigator.of(context);
                        final go = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: AppColors.panel,
                            title: const Text('Начать новую партию?',
                                style: TextStyle(fontSize: 17)),
                            content: const Text(
                              'Незавершённая партия будет удалена. Если она '
                              'нужна — сначала нажмите «Продолжить».',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Остаться'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Удалить и начать',
                                    style: TextStyle(color: AppColors.warn)),
                              ),
                            ],
                          ),
                        );
                        if (go != true) return;
                        if (!mounted) return;
                        await nav.push(
                          MaterialPageRoute(builder: (_) => const SetupScreen()),
                        );
                        await _checkSession();
                        return;
                      }
                      await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SetupScreen()),
                      );
                      await _checkSession();
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_mySession != null)
                    // Игрок уже в партии — предлагаем вернуться, а не
                    // регистрироваться заново.
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.ok.withAlpha(28),
                        border: Border.all(color: AppColors.ok.withAlpha(120)),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.person_pin_circle,
                                  color: AppColors.ok, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Вы играете как «${_mySession!.name}»',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Игра ${_mySession!.code}. Вернитесь, чтобы '
                            'продолжить с той же ролью.',
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.dim),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.ok,
                                    minimumSize: const Size.fromHeight(44),
                                  ),
                                  onPressed: _rejoining ? null : _rejoin,
                                  child: _rejoining
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : const Text('Вернуться в игру'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size.fromHeight(44),
                                  ),
                                  onPressed:
                                      _rejoining ? null : _forgetMySession,
                                  child: const Text('Выйти',
                                      style: TextStyle(fontSize: 13)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    )
                  else if (_playerModeVisible)
                    // Режим игрока в приложении спрятан: игроки заходят
                    // через браузер по QR-коду, ставить APK им не нужно.
                    // Кнопка остаётся доступной через настройки — на случай,
                    // если браузер подведёт и понадобится запасной путь.
                    OutlinedButton.icon(
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Я игрок — подключиться'),
                      onPressed: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const JoinScreen()),
                        );
                        await _checkSession();
                      },
                    )
                  else
                    const InfoCard(
                      icon: Icons.phone_iphone,
                      text: 'Игроки заходят через браузер: покажите им QR-код '
                          'после создания игры. Приложение нужно только вам.',
                      color: AppColors.dim,
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.history, size: 18),
                          label: const Text('История'),
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const HistoryScreen()),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.volume_up, size: 18),
                          label: const Text('Звук'),
                          onPressed: _openSettings,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Правила — рядом с входом, до партии: ведущий обычно
                  // показывает этот экран новичкам, пока те читают роли.
                  OutlinedButton.icon(
                    icon: const Icon(Icons.menu_book, size: 18),
                    label: const Text('Правила и роли'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const RulesScreen()),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: AppColors.panel.withAlpha(220),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.line),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.wifi_tethering,
                            size: 18, color: AppColors.accent2),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Все устройства должны быть в одной сети. Проще всего: '
                            'ведущий включает раздачу Wi-Fi, игроки подключаются '
                            'к ней. Доступ в интернет не требуется.',
                            style:
                                TextStyle(fontSize: 12, color: AppColors.dim),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Авторские права — на главном экране, а не в «О программе»:
                  // человек должен видеть, кому принадлежит игра, ещё до партии.
                  const SizedBox(height: 22),
                  const CopyrightLine(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
