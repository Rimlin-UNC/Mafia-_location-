import 'package:flutter/material.dart';

import '../../host/host_controller.dart';
import '../theme.dart';

/// Итоги голосования: прогресс-бары, расшифровка, второй тур.
class VotingSheet extends StatefulWidget {
  final HostController controller;
  const VotingSheet({super.key, required this.controller});

  @override
  State<VotingSheet> createState() => _VotingSheetState();
}

class _VotingSheetState extends State<VotingSheet> {
  HostController get c => widget.controller;
  String? _expanded;

  @override
  Widget build(BuildContext context) {
    final s = c.state;
    if (s == null) return const SizedBox.shrink();

    final tally = s.voteTally;
    final leaders = s.voteLeaders;
    final isRunoff = s.runoffCandidates.isNotEmpty;
    final maxVotes =
        tally.isEmpty ? 0 : tally.values.reduce((a, b) => a > b ? a : b);
    final tie = leaders.length > 1;

    // Кандидаты: все живые, у кого есть голоса, плюс участники тура.
    final ids = <String>{...tally.keys, ...s.runoffCandidates}.toList()
      ..sort((a, b) => (tally[b] ?? 0).compareTo(tally[a] ?? 0));

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
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
                    isRunoff ? 'Второй тур' : 'Итоги голосования',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Проголосовало ${s.votes.length} из ${s.alive.length}. '
                    'Нажмите на кандидата, чтобы увидеть, кто за него голосовал.',
                    style:
                        const TextStyle(fontSize: 12.5, color: AppColors.dim),
                  ),
                  const SizedBox(height: 16),

                  if (ids.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Center(
                        child: Text('Никто не проголосовал',
                            style: TextStyle(color: AppColors.dim)),
                      ),
                    ),

                  for (final id in ids)
                    _VoteBar(
                      name: s.nameOf(id),
                      votes: tally[id] ?? 0,
                      maxVotes: maxVotes == 0 ? 1 : maxVotes,
                      isLeader: leaders.contains(id),
                      voters: _expanded == id ? s.votersFor(id) : null,
                      onTap: () => setState(
                          () => _expanded = _expanded == id ? null : id),
                    ),

                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: (tie ? AppColors.warn : AppColors.ok)
                          .withAlpha(26),
                      border: Border.all(
                        color: (tie ? AppColors.warn : AppColors.ok)
                            .withAlpha(102),
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _statusText(tie, isRunoff, leaders, s.nameOf),
                      style: const TextStyle(fontSize: 13.5),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (tie && !isRunoff)
                    ElevatedButton.icon(
                      icon: const Icon(Icons.how_to_vote),
                      label: const Text('Запустить второй тур'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.warn),
                      onPressed: () {
                        Navigator.pop(context);
                        c.startRunoff(leaders);
                      },
                    )
                  else if (leaders.length == 1)
                    ElevatedButton.icon(
                      icon: const Icon(Icons.check),
                      label: Text('Подтвердить: выбывает '
                          '${s.nameOf(leaders.first)}'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.bad),
                      onPressed: () {
                        Navigator.pop(context);
                        c.confirmElimination(leaders.first);
                      },
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      c.confirmElimination(null);
                    },
                    child: const Text('Никто не выбывает'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _statusText(bool tie, bool isRunoff, List<String> leaders,
      String Function(String) nameOf) {
    if (leaders.isEmpty) return 'Голосов нет — никто не выбывает.';
    if (tie) {
      final names = leaders.map(nameOf).join(', ');
      return isRunoff
          ? 'Повторная ничья ($names). По умолчанию никто не выбывает.'
          : 'Ничья между: $names. Требуется второй тур.';
    }
    return 'Лидер: ${nameOf(leaders.first)}. Ничьей нет.';
  }
}

class _VoteBar extends StatelessWidget {
  final String name;
  final int votes;
  final int maxVotes;
  final bool isLeader;
  final List<String>? voters;
  final VoidCallback onTap;

  const _VoteBar({
    required this.name,
    required this.votes,
    required this.maxVotes,
    required this.isLeader,
    required this.voters,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  isLeader ? '$name 👑' : name,
                  style: const TextStyle(fontSize: 14.5),
                ),
                const Spacer(),
                Text('$votes',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: votes / maxVotes,
                minHeight: 9,
                backgroundColor: AppColors.panel2,
                valueColor: const AlwaysStoppedAnimation(AppColors.accent),
              ),
            ),
            if (voters != null) ...[
              const SizedBox(height: 6),
              Text(
                voters!.isEmpty
                    ? 'Никто не голосовал'
                    : 'Голосовали: ${voters!.join(' · ')}',
                style: const TextStyle(fontSize: 11.5, color: AppColors.warn),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
