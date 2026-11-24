import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/protocol_export.dart';
import '../models/game_event.dart';
import '../models/role.dart';
import '../storage/history_repository.dart';
import 'app_sheet.dart';
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
                            '${playersRu(g.players.length)} · ${g.winnerTitle}',
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

  /// Протокол партии в буфер обмена.
  ///
  /// Специально без share_plus: лишняя зависимость ради одного действия,
  /// а на Android «Поделиться» из буфера доступно в любом мессенджере.
  /// Если понадобится прямая отправка в Telegram/WhatsApp — это отдельный PR.

  /// «20 игроков» — верный падеж для счётчика в списке партий.
  static String playersRu(int n) {
    final mod100 = n % 100;
    final mod10 = n % 10;
    if (mod100 >= 11 && mod100 <= 14) return '$n игроков';
    if (mod10 == 1) return '$n игрок';
    if (mod10 >= 2 && mod10 <= 4) return '$n игрока';
    return '$n игроков';
  }

  /// «7 раундов» — неверный падеж; склоняем по-русски.
  static String roundsRu(int n) {
    final mod100 = n % 100;
    final mod10 = n % 10;
    if (mod100 >= 11 && mod100 <= 14) return '$n раундов';
    if (mod10 == 1) return '$n раунд';
    if (mod10 >= 2 && mod10 <= 4) return '$n раунда';
    return '$n раундов';
  }

  Future<void> _copyProtocol(GameSummary g, List<GameEvent> log) async {
    final text = ProtocolExport.build(
      name: g.name,
      createdAt: g.createdAt,
      rounds: g.rounds,
      winnerTitle: g.winnerTitle,
      players: g.players,
      log: log,
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.panel2,
        content: Text(
          'Протокол скопирован (${text.length} символов). '
          'Вставьте его в чат или заметки.',
        ),
      ),
    );
  }

  Future<void> _openDetails(GameSummary g) async {
    final log = await _repo.logOf(g.id);
    if (!mounted) return;

    showAppSheet<void>(
      context,
      // Высоту задаёт сам DraggableScrollableSheet (доля экрана) —
      // внешний потолок не нужен, иначе ему не хватит места под прокрутку.
      maxHeightFactor: 1.0,
      showHandle: false,
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
              '${_fmtDate(g.createdAt)} · ${roundsRu(g.rounds)} · '
              '${g.winnerTitle}',
              style: const TextStyle(fontSize: 12.5, color: AppColors.dim),
            ),
            const SizedBox(height: 18),
            const Text('Расклад ролей',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (final p in g.players) HistoryPlayerRow(player: p),
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
            // FR-7.7: выгрузка протокола текстом.
            OutlinedButton.icon(
              icon: const Icon(Icons.copy_all),
              label: const Text('Поделиться протоколом'),
              onPressed: () => _copyProtocol(g, log),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline, color: AppColors.bad),
              label: const Text('Удалить партию',
                  style: TextStyle(color: AppColors.bad)),
              onPressed: () async {
                // Навигатор берём ДО await: после удаления виджет может
                // быть уже не в дереве, и context.mounted — не та проверка,
                // которую ждёт анализатор (нужен mounted самого State).
                final nav = Navigator.of(context);
                await _repo.deleteGame(g.id);
                if (!mounted) return;
                nav.pop();
                _load();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка «игрок — роль» в раскладе партии.
///
/// Роль в истории хранится служебным именем (`RoleType.name`), поэтому
/// подпись берётся из единого словаря `Role.nameRuFor`. Раньше здесь
/// печаталось сырое значение, и после партии игроки видели «civilian».
///
/// Длинные названия новых ролей («Телохранитель», «Шантажист») на узком
/// экране не должны выталкивать имя игрока: роль ограничена по ширине,
/// и её можно прочитать в протоколе, скопировав его целиком.
class HistoryPlayerRow extends StatelessWidget {
  final Map<String, dynamic> player;

  const HistoryPlayerRow({super.key, required this.player});

  static String roleLabel(Map<String, dynamic> p) {
    final name = Role.nameRuFor(p['role']?.toString());
    return name.isEmpty ? '—' : name;
  }

  /// Имя плюс честные пометки.
  ///
  /// Ведущий, который «тоже играет», в истории выглядит обычным игроком —
  /// без пометки непонятно, почему его роль ничего не значит.
  static String playerLabel(Map<String, dynamic> p) {
    final name = p['name']?.toString() ?? '—';
    final marks = <String>[
      if (p['isLocal'] == true) 'ведущий',
      if (p['isBot'] == true) 'бот',
    ];
    return marks.isEmpty ? name : '$name (${marks.join(', ')})';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(playerLabel(player))),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              roleLabel(player),
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: AppColors.dim),
            ),
          ),
        ],
      ),
    );
  }
}
