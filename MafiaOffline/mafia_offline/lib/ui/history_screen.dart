import 'package:flutter/material.dart';

import '../models/game_event.dart';
import '../storage/history_repository.dart';
import 'theme.dart';
import 'widgets.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _repo = HistoryRepository();
  List<GameSummary> _games = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final games = await _repo.listGames();
    if (!mounted) return;
    setState(() {
      _games = games;
      _loading = false;
    });
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.'
      '${d.month.toString().padLeft(2, '0')}.${d.year}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('История игр')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _games.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(30),
                      child: Text(
                        'Сыгранных партий пока нет.\n'
                        'Проведите игру — она сохранится здесь.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.dim),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _games.length,
                    itemBuilder: (_, i) {
                      final g = _games[i];
                      return PanelCard(
                        child: ListTile(
                          leading: const Text('🎭',
                              style: TextStyle(fontSize: 22)),
                          title: Text(g.name),
                          subtitle: Text(
                            '${_fmtDate(g.createdAt)} · '
                            '${g.players.length} игроков · ${g.winnerTitle}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openDetails(g),
                        ),
                      );
                    },
                  ),
      ),
    );
  }

  Future<void> _openDetails(GameSummary g) async {
    final log = await _repo.logOf(g.id);
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            Text(g.name,
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.bold)),
            Text(
              '${_fmtDate(g.createdAt)} · ${g.rounds} раундов · ${g.winnerTitle}',
              style: const TextStyle(fontSize: 12.5, color: AppColors.dim),
            ),
            const SizedBox(height: 18),
            const Text('Расклад ролей',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (final p in g.players)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(child: Text(p['name']?.toString() ?? '—')),
                    Text(
                      p['role']?.toString() ?? '—',
                      style: const TextStyle(
                          fontSize: 12.5, color: AppColors.dim),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 18),
            const Text('Хронология',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (log.isEmpty)
              const Text('Лог пуст',
                  style: TextStyle(color: AppColors.dim, fontSize: 12.5))
            else
              for (final GameEvent e in log)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('• ${e.text}',
                      style: const TextStyle(fontSize: 12.5)),
                ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline, color: AppColors.bad),
              label: const Text('Удалить партию',
                  style: TextStyle(color: AppColors.bad)),
              onPressed: () async {
                await _repo.deleteGame(g.id);
                if (context.mounted) Navigator.pop(context);
                _load();
              },
            ),
          ],
        ),
      ),
    );
  }
}
