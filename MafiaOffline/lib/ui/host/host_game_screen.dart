import 'package:flutter/material.dart';

import '../../host/host_controller.dart';
import '../../models/game_phase.dart';
import '../../models/game_state.dart';
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

class _HostGameScreenState extends State<HostGameScreen> {
  HostController get c => widget.controller;
  bool _revealRoles = false;
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    c.addListener(_update);
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
        backgroundColor: Colors.transparent,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => VotingSheet(controller: c),
      ).then((_) => _sheetOpen = false);
    }
  }

  @override
  void dispose() {
    c.removeListener(_update);
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
                title: s.phase.title,
                right: 'Раунд ${s.round} · живых ${s.alive.length}'
                    '/${s.players.length}',
                isNight: isNight,
              ),
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

              // ---- Зона 3 (подсказка) ----
              const SizedBox(height: 4),
              InfoCard(
                icon: Icons.campaign,
                text: c.hostPrompt(),
                color: AppColors.accent,
              ),

              // ---- Зона 2: игроки ----
              Row(
                children: [
                  const Text('Игроки',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const Spacer(),
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
                    highlighted: isNight &&
                        p.isAlive &&
                        (p.role?.isActiveAtNight ?? false),
                    subtitle: _revealRoles && p.role != null
                        ? '${p.role!.emoji} ${p.role!.name}'
                        : (p.isAlive
                            ? (p.roleAcknowledged ? 'в игре' : 'изучает роль')
                            : 'выбыл'),
                    onTap: () => _renameDialog(p.id, p.name),
                    trailing: _playerTrailing(s, p.id),
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
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 20,
            decoration: InputDecoration(
              labelText: 'Имя игрока',
              counterText: '',
              errorText: error,
            ),
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

  String _forceLabel(GameState s) {
    switch (s.phase) {
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
    if (!p.isAlive) return const Text('☠', style: TextStyle(fontSize: 14));
    if (!p.isConnected) return const StatusDot(AppColors.bad);

    if (s.phase == GamePhase.night && (p.role?.isActiveAtNight ?? false)) {
      return s.nightActions.containsKey(p.id)
          ? const Icon(Icons.check, color: AppColors.ok, size: 20)
          : const StatusDot(AppColors.warn);
    }
    if (s.phase == GamePhase.voting) {
      return s.votes.containsKey(p.id)
          ? const Icon(Icons.check, color: AppColors.ok, size: 20)
          : const StatusDot(AppColors.warn);
    }
    return const StatusDot(AppColors.ok);
  }

  void _showFullLog(GameState s) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
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
                      'Раундов: ${s.round} · игроков: ${s.players.length}',
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
                        subtitle:
                            '${p.role?.emoji ?? ''} ${p.role?.name ?? ''}',
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
