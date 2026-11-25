import 'package:flutter/material.dart';

import '../../core/assets.dart';
import '../../core/game_engine.dart';
import '../../core/story_deck.dart';
import '../../host/host_controller.dart';
import '../../models/game_phase.dart';
import '../../models/game_state.dart';
import '../../models/player.dart';
import '../../models/role.dart';
import '../story_card_view.dart';
import '../role_card_view.dart';
import '../app_sheet.dart';
import '../theme.dart';
import '../widgets.dart';
import 'night_result_sheet.dart';
import 'voting_sheet.dart';

/// Основной экран ведущего: три зоны — таймер, игроки, лог и подсказки.
class HostGameScreen extends StatefulWidget {
  final HostController controller;
  const HostGameScreen({super.key, required this.controller});

  @override
  State<HostGameScreen> createState() => _HostGameScreenState();
}

class _HostGameScreenState extends State<HostGameScreen>
    with WidgetsBindingObserver {
  HostController get c => widget.controller;
  bool _revealRoles = false;
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    c.addListener(_update);
    // Возврат из фона: экран ведущего гаснет чаще всех, и после долгой
    // паузы состояние на экране может разойтись с реальным — например,
    // пока процесс был заморожен, фаза успела смениться. Перерисовываем
    // и просим контроллер пересобрать время по факту, а не по числу
    // тиков (см. HostController.onResume).
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      c.onResume();
      _update();
    }
  }

  void _update() {
    if (!mounted) return;
    setState(() {});
    _maybeOpenSheet();
  }

  /// Автоматически показываем итоги ночи / голосования, когда они готовы.
  void _maybeOpenSheet() {
    final s = c.state;
    if (s == null || _sheetOpen) return;

    if (s.pendingNight != null) {
      _sheetOpen = true;
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        // Нижняя кнопка «Огласить» не должна уходить под системную
        // навигацию: на жестовой навигации её срезало край экрана.
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => NightResultSheet(controller: c),
      ).then((_) => _sheetOpen = false);
      return;
    }

    if (s.phase == GamePhase.voting && s.awaitingVoteConfirm) {
      _sheetOpen = true;
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        // Нижняя кнопка «Огласить» не должна уходить под системную
        // навигацию: на жестовой навигации её срезало край экрана.
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => VotingSheet(controller: c),
      ).then((_) => _sheetOpen = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_update);
    // Страховка от утечки сервера.
    //
    // Экран партии можно покинуть тремя путями: «Прервать» (там shutdown
    // уже вызван), «В главное меню» на итогах (тоже) и системной кнопкой
    // «Назад» — а на экране итогов её никто не перехватывал. В последнем
    // случае экран исчезал, а HttpServer на 8088 продолжал жить в
    // контроллере: следующая партия падала с «Address already in use»,
    // и ведущий видел ошибку вместо игры.
    //
    // shutdown() вызывается ещё раз осознанно: он идемпотентен (stop()
    // у сервера переносит null-проверки), а цена повторного вызова —
    // ноль. Цена пропущенного — несоздаваемая игра.
    c.shutdown();
    super.dispose();
  }

  Future<void> _confirmAbort() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text('Прервать партию?'),
        content: const Text(
            'Игра завершится досрочно и сохранится в истории как прерванная.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Прервать', style: TextStyle(color: AppColors.bad)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await c.abortGame();
      if (mounted) Navigator.popUntil(context, (r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = c.state;
    if (s == null) return const Scaffold(body: SizedBox.shrink());

    if (s.phase == GamePhase.ended) {
      return _GameOverView(controller: c);
    }

    final isNight = s.phase == GamePhase.night;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmAbort();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Полный лог',
              icon: const Icon(Icons.receipt_long),
              onPressed: () => _showFullLog(s),
            ),
            IconButton(
              tooltip: 'Прервать',
              icon: const Icon(Icons.stop_circle_outlined),
              color: AppColors.bad,
              onPressed: _confirmAbort,
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ---- Зона 1: фаза и таймер ----
              PhaseBanner(
                title: s.lastWordId != null
                    ? 'Последнее слово'
                    : s.isVerdictVote
                        ? 'Повторное голосование'
                        : s.isIntroNight
                            ? 'Ночь знакомства'
                            : s.phase.title,
                right: s.phase == GamePhase.rolesCheck
                    ? '${s.players.length - s.unacknowledged.length}'
                        ' из ${s.players.length} готовы'
                    : 'Раунд ${s.round} · живых ${s.alive.length}'
                        '/${s.players.length}',
                isNight: isNight,
              ),
              // ---- Гейт раздачи ролей: первая ночь ждёт всех ----
              if (s.phase == GamePhase.rolesCheck &&
                  s.localPlayer != null &&
                  !s.localPlayer!.roleAcknowledged) ...[
                const SizedBox(height: 10),
                _LocalRoleRevealCard(controller: c, player: s.localPlayer!),
              ] else if (c.waitingForRoleCheck) ...[
                const SizedBox(height: 10),
                _RoleCheckCard(controller: c),
              ],
              if (s.phase != GamePhase.rolesCheck && s.localPlayer != null) ...[
                const SizedBox(height: 10),
                _LocalPlayerPanel(controller: c),
              ],
              // Таймер в фазе раздачи ролей не имеет смысла: ночь ещё
              // не началась, время не идёт. Показываем вместо него
              // панель готовности (выше).
              if (s.phase != GamePhase.rolesCheck) ...[
              const SizedBox(height: 10),
              PanelCard(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Column(
                    children: [
                      Text(
                        formatTime(s.timeLeft),
                        style: const TextStyle(
                          fontSize: 46,
                          fontWeight: FontWeight.bold,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(
                        s.paused ? '⏸ пауза' : 'до конца фазы',
                        style: const TextStyle(
                            color: AppColors.dim, fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: _MiniButton(
                                label: s.paused ? '▶ Пуск' : '⏸ Пауза',
                                onTap: c.togglePause,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _MiniButton(
                                label: '+1 мин',
                                onTap: () => c.addTime(60),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _MiniButton(
                                label: '+30 с',
                                onTap: () => c.addTime(30),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.skip_next, size: 18),
                          label: Text(_forceLabel(s)),
                          onPressed: c.forceEndPhase,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              ],

              // ---- Зона 3 (подсказка) ----
              const SizedBox(height: 4),
              InfoCard(
                icon: Icons.campaign,
                text: c.hostPrompt(),
                color: AppColors.accent,
              ),

              // Сюжетная карточка момента: автоматически в переломные
              // моменты, либо вручную кнопкой ниже.
              if (StoryDeck.byId(s.storyId) != null) ...[
                const SizedBox(height: 8),
                _StoryBanner(
                  card: StoryDeck.byId(s.storyId)!,
                  onShow: () => _openStory(StoryDeck.byId(s.storyId)!),
                  onClose: c.dismissStory,
                ),
              ],
              const SizedBox(height: 8),
              _MiniButton(
                label: '🎬 Кадр партии',
                onTap: () => _pickStory(s),
              ),

              // ---- Зона 2: игроки ----
              Row(
                children: [
                  const Text('Игроки',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const Spacer(),
                  if (s.players.any((p) => p.role != null))
                    _MiniButton(
                      label: _revealRoles ? '🙈 Скрыть роли' : '👁 Показать роли',
                      onTap: () => setState(() => _revealRoles = !_revealRoles),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              for (final p in s.players)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: PlayerTile(
                    name: p.name,
                    colorHex: p.colorHex,
                    alive: p.isAlive,
                    highlighted: isNight && s.actsTonight(p) ||
                        p.id == s.lastWordId ||
                        p.id == s.verdictId,
                    subtitle: _playerSubtitle(s, p),
                    onTap: () => _renameDialog(p.id, p.name),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Повторный показ роли (вопрос 4 из OPEN_QUESTIONS).
                        // Боту показывать нечего: у него нет экрана.
                        if (p.role != null && !p.isBot)
                          IconButton(
                            tooltip: 'Показать роль ещё раз',
                            icon: const Icon(Icons.visibility_outlined,
                                size: 18),
                            color: AppColors.dim,
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _reshareRole(p.id, p.name),
                          ),
                        _playerTrailing(s, p.id) ??
                            const SizedBox.shrink(),
                      ],
                    ),
                  ),
                ),

              // ---- Зона 3: лог ----
              const SizedBox(height: 6),
              const Text('Последние события',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF101219),
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (s.log.isEmpty)
                      const Text('Пока пусто',
                          style:
                              TextStyle(color: AppColors.dim, fontSize: 12))
                    else
                      for (final e in s.log.reversed.take(4))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            e.text,
                            style: TextStyle(
                              fontSize: 12,
                              color: e.visibleToPlayers
                                  ? const Color(0xFFAAB0C6)
                                  : AppColors.warn,
                            ),
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

  /// Повторно отправить игроку его роль. Ошибки — снекбаром, чтобы
  /// ведущий понимал, почему ничего не произошло.
  Future<void> _reshareRole(String playerId, String name) async {
    final err = c.reshareRole(playerId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: err == null ? AppColors.panel2 : AppColors.bad,
        content: Text(err ??
            'Роль отправлена повторно: $name. Экран-предупреждение '
                'появится у него заново.'),
      ),
    );
  }

  /// Переименование прямо во время партии — тапом по игроку.
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
              if (c.state?.phase != GamePhase.waiting &&
                  c.state?.phase != GamePhase.rolesCheck)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.allowRenameInGame
                            ? 'Имя видно всем: смена имени посреди партии — '
                                'подсказка столу.'
                            : 'Посреди партии имена менять нельзя. '
                                'Можно разрешить для этой партии.',
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.dim),
                      ),
                    ),
                    Switch(
                      value: c.allowRenameInGame,
                      activeColor: AppColors.accent,
                      onChanged: (v) {
                        c.setAllowRenameInGame(v);
                        setDialog(() {});
                      },
                    ),
                  ],
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
                final err = c.renamePlayer(
                  playerId,
                  ctrl.text,
                  allowDuringGame: c.allowRenameInGame,
                );
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

  /// Подпись под именем в списке ведущего.
  ///
  /// Бот и локальный игрок — первыми: иначе «роль прочитана» или «нет связи»
  /// выглядели бы как проблема у живого человека, а это не так.
  String _playerSubtitle(GameState s, Player p) {
    if (_revealRoles && p.role != null) {
      return '${p.role!.emoji} ${p.role!.name}';
    }
    if (!p.isAlive) {
      if (p.isBot) return 'бот · выбыл';
      return p.isLocal ? 'это вы · выбыли' : 'выбыл';
    }
    if (p.isBot) return 'бот · играет сам';
    if (p.isLocal) return 'это вы';
    if (p.id == s.lastWordId) return 'говорит последнее слово';
    if (p.id == s.verdictId) return 'ждёт решения стола';
    if (p.role == null) return 'в лобби';
    return p.roleAcknowledged ? 'роль прочитана' : 'изучает роль';
  }

  String _forceLabel(GameState s) {
    if (s.lastWordId != null) return 'Слово сказано → голосовать ещё раз';
    if (s.isIntroNight) return 'Разбудить город';
    switch (s.phase) {
      case GamePhase.rolesCheck:
        return 'Начать ночь, не дожидаясь';
      case GamePhase.night:
        return 'Завершить ночь → рассвет';
      case GamePhase.day:
        return 'Перейти к голосованию';
      case GamePhase.voting:
        return 'Закрыть голосование';
      default:
        return 'Далее';
    }
  }

  Widget? _playerTrailing(GameState s, String playerId) {
    final p = s.byId(playerId);
    if (p == null) return null;
    if (p.id == s.lastWordId) {
      return const Text('🎤', style: TextStyle(fontSize: 14));
    }
    // В повторном голосовании обвиняемый не голосует — «ждём» ему не ставим.
    if (p.id == s.verdictId) {
      return const Text('⚖', style: TextStyle(fontSize: 14));
    }
    if (!p.isAlive) return const Text('☠', style: TextStyle(fontSize: 14));
    if (!p.isConnected) return const StatusDot(AppColors.bad);

    if (s.phase == GamePhase.rolesCheck && p.role != null) {
      return Icon(
        p.roleAcknowledged ? Icons.check_circle : Icons.hourglass_top,
        color: p.roleAcknowledged ? AppColors.ok : AppColors.warn,
        size: 20,
      );
    }
    if (s.phase == GamePhase.night && s.actsTonight(p)) {
      return s.nightActions.containsKey(p.id)
          ? const Icon(Icons.check, color: AppColors.ok, size: 20)
          : const StatusDot(AppColors.warn);
    }
    if (s.phase == GamePhase.voting) {
      // Запуганный шантажистом в этот день не голосует. Без пометки
      // ведущий ждал бы его голос до конца таймера.
      if (s.isSilencedNow(p)) {
        return const Text('🕶', style: TextStyle(fontSize: 14));
      }
      return s.votes.containsKey(p.id)
          ? const Icon(Icons.check, color: AppColors.ok, size: 20)
          : const StatusDot(AppColors.warn);
    }
    return const StatusDot(AppColors.ok);
  }

  /// Полноэкранный показ карточки ведущему. У игроков она появляется
  /// сама — сервер рассылает её отдельным пакетом.
  void _openStory(StoryCard card) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (_, __, ___) => StoryCardView(
          card: card,
          onClose: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  /// Ручной выбор карточки: список всех, с пометкой уже показанных.
  /// Нужен, когда ведущий хочет подчеркнуть момент, а условие не совпало.
  void _pickStory(GameState s) {
    // Список всех карточек длиннее экрана телефона, поэтому шторка
    // занимает почти весь экран, а прокручивается только список:
    // заголовок остаётся на месте.
    showAppSheet<void>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Кадр партии',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text(
                  'Показать всем игрокам карточку момента. Правила не меняет.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.dim),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                for (final card in StoryDeck.all)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.movie_outlined),
                    title: Text(card.title,
                        style: const TextStyle(fontSize: 14.5)),
                    subtitle: Text(card.caption,
                        style: const TextStyle(fontSize: 12)),
                    trailing: s.storySeen.contains(card.id)
                        ? const Icon(Icons.done, size: 18, color: AppColors.ok)
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      c.showStory(card.id);
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showFullLog(GameState s) {
    showAppSheet<void>(
      context,
      // Высоту задаёт сам DraggableScrollableSheet (доля экрана) —
      // внешний потолок не нужен, иначе ему не хватит места под прокрутку.
      maxHeightFactor: 1.0,
      showHandle: false,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            const Text('История партии',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            // Правила стола — перед хронологией: в споре «как мы
            // договаривались» ведущий открывает лог и читает ответ.
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.panel2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ПРАВИЛА СТОЛА',
                      style: TextStyle(
                          fontSize: 11,
                          color: AppColors.dim,
                          letterSpacing: 1)),
                  const SizedBox(height: 6),
                  for (final line in TableRules.describe(s))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text('• $line',
                          style: const TextStyle(fontSize: 13)),
                    ),
                ],
              ),
            ),
            for (final e in s.log.reversed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      e.visibleToPlayers
                          ? Icons.circle
                          : Icons.visibility_off,
                      size: 9,
                      color: e.visibleToPlayers
                          ? AppColors.accent2
                          : AppColors.warn,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(e.text,
                          style: const TextStyle(fontSize: 13)),
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

/// Панель фазы раздачи ролей.
///
/// Ведущий видит прогресс «N из M» и поимённо тех, кто ещё читает.
/// Первая ночь начнётся сама, когда последний нажмёт «Понятно»; кнопка
/// ниже — аварийный выход для случая «человек отошёл».
class _RoleCheckCard extends StatelessWidget {
  final HostController controller;
  const _RoleCheckCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    final s = controller.state;
    if (s == null) return const SizedBox.shrink();
    final total = s.players.length;
    // Боты роль уже «прочитали» (startGame ставит им флаг сам). Если
    // старый слот всё же остался без флага, в список ожидания его не
    // ставим: подойти к боту и попросить нажать «Понятно» нельзя.
    final waiting = s.unacknowledged.where((p) => !p.isBot).toList();
    final ready = controller.roleAckCount;
    // Бот не нажмёт «Понятно» никогда, поэтому для карточки он готов.
    // Иначе при одном неотмеченном боте экран показывал бы «Читают: »
    // с пустым списком имён.
    final done = waiting.isEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: done ? AppColors.ok.withAlpha(26) : AppColors.accent.withAlpha(26),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: done ? AppColors.ok.withAlpha(120) : AppColors.accent.withAlpha(120),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(done ? '✅' : '🎴', style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  done ? 'Все прочитали роль' : 'Роли розданы — ждём игроков',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
              Text('$ready / $total',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : ready / total,
              minHeight: 6,
              backgroundColor: AppColors.line,
              valueColor: AlwaysStoppedAnimation<Color>(
                  done ? AppColors.ok : AppColors.accent2),
            ),
          ),
          const SizedBox(height: 10),
          if (!done) ...[
            const Text(
              'Первая ночь начнётся автоматически, когда все нажмут '
              '«Понятно, я готов». Не начинайте вслух, пока не увидите 100%.',
              style: TextStyle(fontSize: 12, color: AppColors.dim),
            ),
            const SizedBox(height: 8),
            Text(
              'Читают: ${waiting.map((p) => p.name).join(', ')}',
              style: const TextStyle(fontSize: 12.5, color: Color(0xFFF8C778)),
            ),
          ] else
            const Text(
              'Начинаем ночь…',
              style: TextStyle(fontSize: 12, color: AppColors.dim),
            ),
          if (!done) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.fast_forward, size: 17),
                label: const Text('Начать ночь не дожидаясь',
                    style: TextStyle(fontSize: 12.5)),
                onPressed: () => _confirmSkip(context, waiting.length),
              ),
            ),
          ],
          // Все готовы, но автозапуск выключен — решение за ведущим.
          if (done && !controller.autoStartFirstNight) ...[
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Начать первую ночь'),
              onPressed: controller.startNight,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmSkip(BuildContext context, int waitingCount) async {
    final names = controller.state?.unacknowledged
            .where((p) => !p.isBot)
            .map((p) => p.name)
            .join(', ') ??
        '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text('Начать ночь?', style: TextStyle(fontSize: 17)),
        content: Text(
          waitingCount == 1
              ? 'Свою роль ещё не подтвердил: $names.\n\n'
                  'Он рискует пропустить свой первый ночной ход.'
              : 'Свою роль ещё не подтвердили: $names.\n\n'
                  'Они рискуют пропустить свой первый ночной ход.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Подождать'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Начать ночь',
                style: TextStyle(color: AppColors.warn)),
          ),
        ],
      ),
    );
    if (ok == true) controller.skipRoleCheck();
  }
}

/// Роль ведущего, который сам играет. До подтверждения карта закрыта:
/// сосед не должен увидеть её раньше времени.
class _LocalRoleRevealCard extends StatefulWidget {
  final HostController controller;
  final Player player;

  const _LocalRoleRevealCard({
    required this.controller,
    required this.player,
  });

  @override
  State<_LocalRoleRevealCard> createState() => _LocalRoleRevealCardState();
}

class _LocalRoleRevealCardState extends State<_LocalRoleRevealCard> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final role = widget.player.role;
    if (role == null) return const SizedBox.shrink();

    return PanelCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            RoleCardView(
              asset: A.card(role.type),
              name: role.name,
              emoji: role.emoji,
              subtitle: _revealed ? role.description : null,
              revealed: _revealed,
              height: 260,
            ),
            const SizedBox(height: 12),
            if (!_revealed) ...[
              const Text(
                'Убедитесь, что никто не смотрит в ваш экран. '
                'Роль знаете только вы.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: AppColors.dim),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                icon: const Icon(Icons.visibility, size: 18),
                label: const Text('Я один — показать роль'),
                onPressed: () => setState(() => _revealed = true),
              ),
            ] else ...[
              Text(
                role.description,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12.5, color: AppColors.dim),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Понятно, я готов'),
                onPressed: widget.controller.acknowledgeLocalRole,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Панель локального игрока: его роль, команда, проверки и кнопки хода.
/// Появляется только после подтверждения роли; до этого карта скрыта.
class _LocalPlayerPanel extends StatefulWidget {
  final HostController controller;
  const _LocalPlayerPanel({required this.controller});

  @override
  State<_LocalPlayerPanel> createState() => _LocalPlayerPanelState();
}

class _LocalPlayerPanelState extends State<_LocalPlayerPanel> {
  String? _selected;
  bool _piercing = false;
  String _signature = '';

  @override
  void didUpdateWidget(covariant _LocalPlayerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final s = widget.controller.state;
    final signature = s == null
        ? ''
        : '${s.phase.name}:${s.round}:${s.isVerdictVote}:${s.verdictId}';
    if (signature != _signature) {
      _signature = signature;
      _piercing = false;
      _selected = null;
    }
  }

  String _prompt(GameState s, Player local) {
    if (s.isVerdictVote) {
      return 'Выгнать ${s.nameOf(s.verdictId)} или оставить?';
    }
    if (s.phase == GamePhase.night) {
      switch (local.role?.type) {
        case RoleType.mafia:
        case RoleType.don:
          return 'Кого убить этой ночью?';
        case RoleType.doctor:
          return 'Кого спасти?';
        case RoleType.commissioner:
          return 'Кого проверить?';
        case RoleType.prostitute:
          return 'Кого заблокировать?';
        case RoleType.maniac:
          return 'Кого убить?';
        case RoleType.bodyguard:
          return 'Кого прикрыть собой?';
        case RoleType.witness:
          return 'За кем наблюдать?';
        case RoleType.hunter:
          return 'Кого забрать с собой?';
        case RoleType.blackmailer:
          return 'Кого запугать на завтра?';
        default:
          return 'Спите';
      }
    }
    return 'Кого отправляем из города?';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.controller.state;
    final local = s?.localPlayer;
    final role = local?.role;
    if (s == null || local == null || role == null) {
      return const SizedBox.shrink();
    }

    final nightTurn = s.phase == GamePhase.night &&
        s.actsTonight(local) &&
        !s.nightActions.containsKey(local.id);
    final voteTurn = s.phase == GamePhase.voting &&
        s.voters.any((p) => p.id == local.id) &&
        !s.votes.containsKey(local.id);
    final acting = !s.paused && (nightTurn || voteTurn);
    final targets = GameEngine.legalTargetsFor(s, local);
    if (_selected != null &&
        !targets.any((t) => t.id == _selected)) {
      _selected = null;
    }

    final mates = s.mafiaTeam
        .where((p) => p.id != local.id)
        .map((p) => p.name)
        .toList();
    final checks = s.privateCheck && role.type == RoleType.commissioner
        ? s.checksBy(local.id).reversed.take(5).toList()
        : const <CheckRecord>[];
    // Свидетель видит ровно один факт — за кем следил и выходил ли тот.
    final watchName =
        role.type == RoleType.witness ? s.nameOf(s.watchTargetId) : null;
    final watchActed = s.watchActed == true;
    final silenced = s.isSilencedNow(local);
    // Охотник видит свою метку всегда: она переживает ночи, и забыть,
    // на кого она стоит, — самая дорогая ошибка в его игре.
    final hunterMark = role.type == RoleType.hunter && s.hunterMarkId != null
        ? s.nameOf(s.hunterMarkId)
        : null;

    return PanelCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(role.emoji, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Вы: ${role.name}',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        !local.isAlive
                            ? 'вы выбыли — наблюдайте за партией'
                            : mates.isNotEmpty
                                ? 'команда: ${mates.join(', ')}'
                                : 'вы в игре',
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.dim),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (acting) ...[
              if (s.canRequestPiercing(local))
                CheckboxListTile(
                  value: _piercing,
                  onChanged: (v) => setState(() => _piercing = v == true),
                  title: const Text('Выстрел навылет'),
                  subtitle: const Text('Один заряд команды. Пробивает лечение, но не телохранителя.'),
                ),
              Text(
                _prompt(s, local),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              if (s.isVerdictVote)
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => widget.controller
                            .submitLocalVote(s.verdictId),
                        child: Text('Выгнать ${s.nameOf(s.verdictId)}'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            widget.controller.submitLocalVote(null),
                        child: const Text('Оставить'),
                      ),
                    ),
                  ],
                )
              else ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selected,
                      isExpanded: true,
                      hint: const Text('Выберите игрока'),
                      items: [
                        for (final target in targets)
                          DropdownMenuItem(
                            value: target.id,
                            child: Text(
                              target.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) => setState(() => _selected = value),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _selected == null
                            ? null
                            : () {
                                if (s.phase == GamePhase.voting) {
                                  widget.controller.submitLocalVote(_selected);
                                } else {
                                  widget.controller
                                      .submitLocalNightAction(_selected, piercing: _piercing);
                                }
                                setState(() => _selected = null);
                              },
                        child: Text(s.phase == GamePhase.voting
                            ? 'Проголосовать'
                            : 'Отправить выбор'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          if (s.phase == GamePhase.voting) {
                            widget.controller.submitLocalVote(null);
                          } else {
                            widget.controller.submitLocalNightAction(null);
                          }
                          setState(() => _selected = null);
                        },
                        child: Text(s.phase == GamePhase.voting
                            ? 'Воздержаться'
                            : 'Пропустить'),
                      ),
                    ),
                  ],
                ),
              ],
            ] else if (silenced && s.phase == GamePhase.voting) ...[
              const Text(
                '🤐 Вас запугал шантажист: сегодня вы не голосуете. '
                'Скажите об этом вслух — стол вправе это учесть.',
                style: TextStyle(fontSize: 12.5, color: AppColors.warn),
              ),
            ] else ...[
              if (s.paused)
                const Text('⏸ Пауза — действия временно недоступны.',
                    style: TextStyle(fontSize: 12, color: AppColors.dim))
              else if (s.lastWordId == local.id)
                const Text(
                  '🎤 Ваше последнее слово. Скажите его вслух, затем нажмите «Слово сказано» ниже.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.warn),
                )
              else if (s.isVerdictVote && s.verdictId == local.id)
                const Text(
                  '⚖ Стол решает вашу судьбу: вы не голосуете, дождитесь итога.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.warn),
                )
              else if (s.nightActions.containsKey(local.id) &&
                  s.phase == GamePhase.night)
                const Text('✅ Ваш ночной ход принят. Ждите рассвета.',
                    style: TextStyle(fontSize: 12.5, color: AppColors.ok))
              else if (s.votes.containsKey(local.id) &&
                  s.phase == GamePhase.voting)
                const Text('✅ Ваш голос принят. Он скрыт от остальных.',
                    style: TextStyle(fontSize: 12.5, color: AppColors.ok))
              else
                const Text('Сейчас от вас не требуется действий.',
                    style: TextStyle(fontSize: 12.5, color: AppColors.dim)),
            ],
            if (watchName != null && s.watchTargetId != null) ...[
              const SizedBox(height: 8),
              const Text('Ваше наблюдение',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
              Text(
                watchActed
                    ? '${s.nameOf(s.watchTargetId)} выходил из дома ночью'
                    : '${s.nameOf(s.watchTargetId)} не выходил из дома',
                style: TextStyle(
                    fontSize: 12,
                    color: watchActed ? AppColors.warn : AppColors.dim),
              ),
            ],
            if (hunterMark != null) ...[
              const SizedBox(height: 8),
              const Text('Ваша метка',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
              Text('$hunterMark погибнет вместе с вами — от ножа или от голосования',
                  style: const TextStyle(fontSize: 12, color: AppColors.warn)),
            ],
            if (checks.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Ваши проверки',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
              for (final check in checks)
                Text(
                  check.blocked
                      ? 'Ночь ${check.round}: проверка не состоялась'
                      : 'Ночь ${check.round}: ${s.nameOf(check.targetId)} — '
                          '${check.isMafia ? 'МАФИЯ' : 'не мафия'}',
                  style: TextStyle(
                      fontSize: 12,
                      color: check.isMafia && !check.blocked
                          ? AppColors.bad
                          : AppColors.dim),
                ),
            ],
            const SizedBox(height: 6),
            const Text(
              'Вы играете за столом: не открывайте список ролей '
              'и не подглядывайте в чужие ночные ходы.',
              style: TextStyle(fontSize: 11, color: AppColors.dim),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _MiniButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.panel2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.line),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12.5),
        ),
      ),
    );
  }
}

/// Экран итогов партии для ведущего.
class _GameOverView extends StatelessWidget {
  final HostController controller;
  const _GameOverView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final s = controller.state!;
    return PopScope(
      // Партия окончена — удерживать ведущего здесь нечем. Но уходя,
      // останавливаем сервер: иначе он остаётся висеть на порту 8088,
      // и следующая игра не запустится.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await controller.shutdown();
        if (context.mounted) {
          Navigator.popUntil(context, (r) => r.isFirst);
        }
      },
      child: _build(context, s),
    );
  }

  Widget _build(BuildContext context, GameState s) {
    return Scaffold(
      appBar: AppBar(title: const Text('Игра окончена')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const SizedBox(height: 10),
                  const Center(
                      child: Text('🎉', style: TextStyle(fontSize: 56))),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      s.winner?.title ?? 'Партия завершена',
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      s.hasBots
                          ? 'Раундов: ${s.round} · игроков: ${s.players.length} '
                              '(ботов: ${s.bots.length})'
                          : 'Раундов: ${s.round} · игроков: ${s.players.length}',
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: AppColors.dim, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('Расклад ролей',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 10),
                  for (final p in s.players)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: PlayerTile(
                        name: p.name,
                        colorHex: p.colorHex,
                        alive: p.isAlive,
                        // Пометка бота — в подписи, а не в имени: имя
                        // игрока ведущий мог задать сам, и портить его
                        // эмодзи в итоговом раскладе не нужно.
                        subtitle: p.isBot
                            ? '🤖 ${p.role?.name ?? ''}'
                            : '${p.role?.emoji ?? ''} ${p.role?.name ?? ''}',
                        trailing: Text(
                          p.isAlive ? 'выжил' : 'выбыл',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.dim),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton(
                onPressed: () async {
                  await controller.shutdown();
                  if (context.mounted) {
                    Navigator.popUntil(context, (r) => r.isFirst);
                  }
                },
                child: const Text('В главное меню'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Полоска «показана карточка» на экране ведущего: напоминает, что кадр
/// до сих пор висит у игроков, и даёт две кнопки — открыть и убрать.
class _StoryBanner extends StatelessWidget {
  final StoryCard card;
  final VoidCallback onShow;
  final VoidCallback onClose;

  const _StoryBanner({
    required this.card,
    required this.onShow,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.accent.withAlpha(24),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withAlpha(110)),
      ),
      child: Row(
        children: [
          const Icon(Icons.movie_outlined, size: 18, color: AppColors.accent2),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Кадр: ${card.title}',
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(onPressed: onShow, child: const Text('Открыть')),
          TextButton(onPressed: onClose, child: const Text('Убрать')),
        ],
      ),
    );
  }
}
