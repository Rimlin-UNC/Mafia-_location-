import 'package:flutter/material.dart';
import '../../player/player_controller.dart';
import '../../storage/suspicion_store.dart';

class SuspicionScreen extends StatefulWidget {
  final PlayerController controller;
  const SuspicionScreen({super.key, required this.controller});
  @override
  State<SuspicionScreen> createState() => _SuspicionScreenState();
}

class _SuspicionScreenState extends State<SuspicionScreen> {
  late final SuspicionStore store;
  Map<String, SuspicionNote>? notes;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    store = SuspicionStore('${c.hostAddress}|${c.gameCode}|${c.playerId}');
    c.addListener(_refresh);
    _load();
  }

  Future<void> _load() async {
    final loaded = await store.load();
    if (mounted) setState(() => notes = loaded);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _edit(String id, String name) async {
    final old = notes![id] ?? const SuspicionNote();
    var text = old.text;
    var mark = old.mark;
    final result = await showDialog<SuspicionNote>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, update) {
        return AlertDialog(
          title: Text(name),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButton<String>(
                value: mark,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: '', child: Text('— Без отметки')),
                  DropdownMenuItem(value: 'suspect', child: Text('? Подозреваю')),
                  DropdownMenuItem(value: 'trust', child: Text('✓ Доверяю')),
                ],
                onChanged: (value) => update(() => mark = value ?? ''),
              ),
              TextFormField(
                initialValue: text,
                onChanged: (value) => text = value,
                maxLength: 500,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Мои наблюдения'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            TextButton(
              onPressed: () => Navigator.pop(context, SuspicionNote(text: text, mark: mark)),
              child: const Text('Сохранить'),
            ),
          ],
        );
      }),
    );
    if (result == null || !mounted) return;
    setState(() => notes![id] = result);
    final saved = await store.save(notes!);
    if (!saved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Не удалось сохранить: заметки останутся до закрытия экрана.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Мои подозрения')),
        body: notes == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(16), children: [
                const Text('Только на этом устройстве. Никому не отправляются. '
                    'Отметки — ваши предположения, а не результаты проверок.'),
                const SizedBox(height: 16),
                for (final p in widget.controller.lobby)
                  if (p.id.isNotEmpty && p.id != widget.controller.playerId)
                    ListTile(
                      leading: Text(p.alive ? '👤' : '☠'),
                      title: Text('${p.name}${p.alive ? '' : ' · выбыл'}'),
                      subtitle: Text([
                        switch (notes![p.id]?.mark) {
                          'suspect' => '? Подозреваю',
                          'trust' => '✓ Доверяю',
                          _ => '— Без отметки',
                        },
                        if ((notes![p.id]?.text ?? '').isNotEmpty) notes![p.id]!.text,
                      ].join('\n')),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () => _edit(p.id, p.name),
                    ),
              ]),
      );
}
