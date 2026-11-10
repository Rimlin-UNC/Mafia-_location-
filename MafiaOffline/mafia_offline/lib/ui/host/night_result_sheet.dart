import 'package:flutter/material.dart';

import '../../core/game_engine.dart';
import '../../host/host_controller.dart';
import '../../models/game_state.dart';
import '../theme.dart';

/// Итоги ночи с возможностью ручной правки до оглашения.
class NightResultSheet extends StatefulWidget {
  final HostController controller;
  const NightResultSheet({super.key, required this.controller});

  @override
  State<NightResultSheet> createState() => _NightResultSheetState();
}

class _NightResultSheetState extends State<NightResultSheet> {
  HostController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final s = c.state;
    final outcome = s?.pendingNight;
    if (s == null || outcome == null) return const SizedBox.shrink();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      maxChildSize: 0.95,
      builder: (_, scroll) => Container(
        decoration: const BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          children: [
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.all(16),
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('Итоги ночи ${s.round}',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text(
                    'Проверьте результат. Любую строку можно изменить '
                    'до оглашения.',
                    style: TextStyle(fontSize: 12.5, color: AppColors.dim),
                  ),
                  const SizedBox(height: 16),

                  if (outcome.mafiaTargetId != null)
                    _OutcomeRow(
                      emoji: '🔫',
                      title: 'Мафия выбрала: ${s.nameOf(outcome.mafiaTargetId)}',
                      subtitle: outcome.killedIds.contains(outcome.mafiaTargetId)
                          ? 'убийство состоялось'
                          : 'жертва спасена доктором',
                      danger: outcome.killedIds.contains(outcome.mafiaTargetId),
                      onEdit: () => _pickTarget(
                        title: 'Кого убила мафия',
                        current: outcome.mafiaTargetId,
                        onPick: (id) => _recompute(mafia: id),
                      ),
                    )
                  else
                    const _OutcomeRow(
                      emoji: '🔫',
                      title: 'Мафия не сделала выбор',
                      subtitle: 'ход пропущен',
                    ),

                  if (outcome.maniacTargetId != null)
                    _OutcomeRow(
                      emoji: '🔪',
                      title: 'Маньяк выбрал: ${s.nameOf(outcome.maniacTargetId)}',
                      subtitle:
                          outcome.killedIds.contains(outcome.maniacTargetId)
                              ? 'убийство состоялось'
                              : 'жертва спасена',
                      danger:
                          outcome.killedIds.contains(outcome.maniacTargetId),
                      onEdit: () => _pickTarget(
                        title: 'Кого убил маньяк',
                        current: outcome.maniacTargetId,
                        onPick: (id) => _recompute(maniac: id),
                      ),
                    ),

                  _OutcomeRow(
                    emoji: '💉',
                    title: outcome.healedId != null
                        ? 'Доктор лечил: ${s.nameOf(outcome.healedId)}'
                        : 'Доктор не лечил никого',
                    subtitle: outcome.healedId != null &&
                            (outcome.healedId == outcome.mafiaTargetId ||
                                outcome.healedId == outcome.maniacTargetId)
                        ? 'совпало с целью убийцы — спасение сработало'
                        : 'не совпало с целью',
                    onEdit: () => _pickTarget(
                      title: 'Кого лечил доктор',
                      current: outcome.healedId,
                      onPick: (id) => _recompute(healed: id),
                    ),
                  ),

                  if (outcome.checkedId != null)
                    _OutcomeRow(
                      emoji: '🔎',
                      title: 'Комиссар проверил: ${s.nameOf(outcome.checkedId)}',
                      subtitle: outcome.checkResultIsMafia == true
                          ? 'результат: МАФИЯ (видите только вы)'
                          : 'результат: мирный (видите только вы)',
                      warn: true,
                    ),

                  if (outcome.blockedId != null)
                    _OutcomeRow(
                      emoji: '💋',
                      title:
                          'Проститутка заблокировала: ${s.nameOf(outcome.blockedId)}',
                      subtitle: 'ход этого игрока пропущен',
                    ),

                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withAlpha(26),
                      border: Border.all(
                          color: AppColors.accent.withAlpha(89)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('ТЕКСТ ДЛЯ ОГЛАШЕНИЯ',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppColors.dim,
                                letterSpacing: 1)),
                        const SizedBox(height: 6),
                        Text(
                          GameEngine.announcement(s, outcome),
                          style: const TextStyle(fontSize: 15),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton.icon(
                icon: const Icon(Icons.campaign),
                label: const Text('Огласить и начать день'),
                onPressed: () {
                  Navigator.pop(context);
                  c.announceNight();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Пересчёт итога после ручной правки ведущим.
  void _recompute({String? mafia, String? maniac, String? healed}) {
    final s = c.state!;
    final o = s.pendingNight!;
    final newMafia = mafia ?? o.mafiaTargetId;
    final newManiac = maniac ?? o.maniacTargetId;
    final newHealed = healed ?? o.healedId;

    final killed = <String>[];
    if (newMafia != null && newMafia != newHealed) killed.add(newMafia);
    if (newManiac != null &&
        newManiac != newHealed &&
        !killed.contains(newManiac)) {
      killed.add(newManiac);
    }

    c.editNightOutcome(NightOutcome(
      killedIds: killed,
      mafiaTargetId: newMafia,
      maniacTargetId: newManiac,
      healedId: newHealed,
      blockedId: o.blockedId,
      checkedId: o.checkedId,
      checkResultIsMafia: o.checkResultIsMafia,
    ));
    setState(() {});
  }

  Future<void> _pickTarget({
    required String title,
    required String? current,
    required void Function(String?) onPick,
  }) async {
    final s = c.state!;
    final selected = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.panel,
        title: Text(title, style: const TextStyle(fontSize: 16)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__none__'),
            child: const Text('Никто',
                style: TextStyle(color: AppColors.dim)),
          ),
          for (final p in s.alive)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p.id),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 10,
                    backgroundColor: colorFromHex(p.colorHex),
                  ),
                  const SizedBox(width: 10),
                  Text(p.name),
                  if (p.id == current) ...[
                    const Spacer(),
                    const Icon(Icons.check, size: 16, color: AppColors.ok),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null) return;
    onPick(selected == '__none__' ? null : selected);
  }
}

class _OutcomeRow extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final bool danger;
  final bool warn;
  final VoidCallback? onEdit;

  const _OutcomeRow({
    required this.emoji,
    required this.title,
    required this.subtitle,
    this.danger = false,
    this.warn = false,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = danger
        ? AppColors.bad.withAlpha(115)
        : warn
            ? AppColors.warn.withAlpha(115)
            : AppColors.line;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panel2,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: warn ? AppColors.warn : AppColors.dim,
                  ),
                ),
              ],
            ),
          ),
          if (onEdit != null)
            TextButton(
              onPressed: onEdit,
              child: const Text('Изменить', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
