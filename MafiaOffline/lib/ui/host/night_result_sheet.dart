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
    final intro = s.isIntroNight;

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
                  Text(
                      intro
                          ? 'Ночь знакомства'
                          : 'Итоги ночи ${s.round}',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    intro
                        ? 'Сегодня никто не погибает. Мафия узнала своих, '
                            'комиссар сделал первую проверку.'
                        : 'Проверьте результат. Любую строку можно изменить '
                            'до оглашения.',
                    style:
                        const TextStyle(fontSize: 12.5, color: AppColors.dim),
                  ),
                  const SizedBox(height: 16),

                  // В ночь знакомства убийцы и доктор не ходят: строк
                  // «мафия не сделала выбор» быть не должно — это не пропуск
                  // хода, а правило.
                  if (intro)
                    const _OutcomeRow(
                      emoji: '🤝',
                      title: 'Мафия познакомилась',
                      subtitle: 'убийств этой ночью нет',
                    ),

                  if (outcome.piercingUsed)
                    const Text('Выстрел навылет: общий заряд мафии будет потрачен при оглашении. Лечение пробито, щит работает.'),
                  if (!intro) ...[
                  if (outcome.mafiaTargetId != null)
                    _OutcomeRow(
                      emoji: '🔫',
                      title: 'Мафия выбрала: ${s.nameOf(outcome.mafiaTargetId)}',
                      subtitle: outcome.killedIds.contains(outcome.mafiaTargetId)
                          ? 'убийство состоялось'
                          : 'жертва спасена',
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
                  ],

                  if (outcome.checkedId != null)
                    _OutcomeRow(
                      emoji: '🔎',
                      title: 'Комиссар проверил: ${s.nameOf(outcome.checkedId)}',
                      subtitle: 'результат: '
                          '${outcome.checkResultIsMafia == true ? 'МАФИЯ' : 'не мафия'}'
                          ' · '
                          '${s.privateCheck ? 'комиссар увидит это у себя после оглашения' : 'сообщите комиссару сами, незаметно'}',
                      warn: true,
                    )
                  else if (intro && s.commissioner != null)
                    const _OutcomeRow(
                      emoji: '🔎',
                      title: 'Комиссар никого не проверил',
                      subtitle: 'ход пропущен',
                    ),

                  if (outcome.blockedId != null)
                    _OutcomeRow(
                      emoji: '💋',
                      title:
                          'Проститутка заблокировала: ${s.nameOf(outcome.blockedId)}',
                      subtitle: 'ход этого игрока пропущен',
                    ),

                  // 1.12.0. Четыре новые роли показываются отдельными
                  // строками: ведущий должен видеть не только «сколько
                  // трупов», но и кто кого прикрыл, запугал и за кем следил.
                  if (outcome.guardedId != null)
                    _OutcomeRow(
                      emoji: '🛡',
                      title:
                          'Телохранитель прикрыл: ${s.nameOf(outcome.guardedId)}',
                      subtitle: outcome.guardDiedId != null
                          ? 'принял удар на себя — погиб '
                              '${s.nameOf(outcome.guardDiedId)}'
                          : 'покушения в него не было',
                      danger: outcome.guardDiedId != null,
                    ),

                  if (outcome.silencedId != null)
                    _OutcomeRow(
                      emoji: '🕶',
                      title:
                          'Шантажист запугал: ${s.nameOf(outcome.silencedId)}',
                      subtitle: 'весь следующий день не голосует',
                      warn: true,
                    ),

                  if (outcome.watchedId != null)
                    _OutcomeRow(
                      emoji: '👁',
                      title: 'Свидетель смотрел за: '
                          '${s.nameOf(outcome.watchedId)}',
                      subtitle: outcome.watchedActed == true
                          ? 'выходил из дома — результат уже у свидетеля'
                          : 'не выходил из дома — результат у свидетеля',
                      warn: true,
                    ),

                  if (outcome.hunterMarkId != null)
                    _OutcomeRow(
                      emoji: '🎯',
                      title:
                          'Охотник отметил: ${s.nameOf(outcome.hunterMarkId)}',
                      subtitle: 'метка действует со следующей ночи; '
                          'вчерашняя — ${s.hunterMarkId == null ? 'не стояла' : 'стоит до сих пор'}',
                    ),

                  if (outcome.revengeIds.isNotEmpty)
                    for (final id in outcome.revengeIds)
                      _OutcomeRow(
                        emoji: '☠',
                        title: 'Охотник забрал с собой: ${s.nameOf(id)}',
                        subtitle: 'сработала метка прошлой ночи',
                        danger: true,
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
            // Кнопка вынесена из прокрутки и поднята над системной
            // навигацией: при жестовой навигации её нижний край срезался.
            SafeArea(
              top: false,
              child: Padding(
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
            ),
          ],
        ),
      ),
    );
  }

  /// Метка «этот параметр не трогали» для [_recompute].
  static const Object _keep = Object();

  /// Пересчёт итога после ручной правки ведущим.
  ///
  /// Параметр не передан — строка не менялась; передан `null` — ведущий
  /// выбрал «Никто». До 1.2.0 эти два случая не различались (`??`), и
  /// «Никто» молча оставлял прежнюю цель.
  void _recompute({
    Object? mafia = _keep,
    Object? maniac = _keep,
    Object? healed = _keep,
  }) {
    final s = c.state!;
    final o = s.pendingNight!;
    // В ночь знакомства править нечего: убийств нет по правилу.
    if (s.isIntroNight) return;
    final newMafia =
        identical(mafia, _keep) ? o.mafiaTargetId : mafia as String?;
    final newManiac =
        identical(maniac, _keep) ? o.maniacTargetId : maniac as String?;
    final newHealed =
        identical(healed, _keep) ? o.healedId : healed as String?;

    // Усиление сохраняется при ручной правке, отменяется при снятии цели.
    final piercing = o.piercingUsed && newMafia != null;
    final deaths = GameEngine.resolveAttacks(s, mafiaTarget: newMafia,
      maniacTarget: newManiac, healedId: newHealed,
      guardedId: o.guardedId, piercing: piercing);

    c.editNightOutcome(NightOutcome(
      piercingUsed: piercing,
      killedIds: deaths.killed,
      mafiaTargetId: newMafia,
      maniacTargetId: newManiac,
      healedId: newHealed,
      blockedId: o.blockedId,
      checkedId: o.checkedId,
      checkResultIsMafia: o.checkResultIsMafia,
      guardedId: o.guardedId,
      guardDiedId: deaths.guardDied,
      silencedId: o.silencedId,
      watchedId: o.watchedId,
      watchedActed: o.watchedActed,
      hunterMarkId: o.hunterMarkId,
      revengeIds: deaths.revenge,
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
