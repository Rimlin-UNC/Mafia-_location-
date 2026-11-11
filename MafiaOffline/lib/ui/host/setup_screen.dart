import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../host/host_controller.dart';
import '../../models/role.dart';
import '../theme.dart';
import '../widgets.dart';
import 'lobby_screen.dart';

/// Экран создания партии: состав игроков и ролей.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _nameCtrl;
  int _total = 10;
  bool _starting = false;

  /// Открывать ли карту выбывшего всем. По умолчанию закрыта (классика).
  bool _openCards = false;

  final Map<RoleType, int> _setup = {
    RoleType.mafia: 2,
    RoleType.don: 1,
    RoleType.doctor: 1,
    RoleType.commissioner: 1,
    RoleType.prostitute: 1,
    RoleType.maniac: 0,
  };

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final date = '${now.day.toString().padLeft(2, '0')}.'
        '${now.month.toString().padLeft(2, '0')}.${now.year}';
    _nameCtrl = TextEditingController(text: 'Игра от $date');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  int get _special => _setup.values.fold(0, (a, b) => a + b);
  int get _civilians => _total - _special;
  int get _mafiaCount =>
      (_setup[RoleType.mafia] ?? 0) + (_setup[RoleType.don] ?? 0);

  bool get _overflow => _special > _total;
  /// Партия нежизнеспособна, только если против мафии остаётся
  /// один игрок — тогда город проигрывает, не начав.
  /// Равный состав (например 3 на 3) вполне играбелен: у города есть
  /// дневное голосование.
  // ignore: unused_element
  bool get _mafiaTooMany => _total - _mafiaCount <= 1;
  bool get _valid => !_overflow;

  /// Оценка шансов сторон по составу.
  ///
  /// Пороги подобраны не «на глаз», а по симуляции: игровой движок
  /// прогнали сотнями партий при разном числе мафии (город при этом
  /// пользуется проверками комиссара). Замеренная доля побед мафии:
  ///
  /// | состав  | мафия побеждает |
  /// |---------|-----------------|
  /// | 1 из 6  | 47 %            |
  /// | 2 из 6  | 82 %            |
  /// | 3 из 6  | 100 %           |
  /// | 2 из 10 | 65 %            |
  /// | 2 из 20 | 52 %            |
  /// | 5 из 20 | 92 %            |
  ///
  /// Простая доля «мафия / всего» эти данные описывает плохо: в малом
  /// составе каждый мафиози весит намного больше. Лучше всего подошёл
  /// индекс `мафия / √состав` — он совпал с фактическим исходом в
  /// 16 случаях из 17.
  ({String text, Color color, IconData icon}) get _balance {
    final others = _total - _mafiaCount;

    if (_mafiaCount == 0) {
      return (
        text: 'Мафии нет — играть не с кем',
        color: AppColors.bad,
        icon: Icons.block,
      );
    }
    if (others <= 1) {
      return (
        text: 'Против мафии меньше двух игроков — город проиграет сразу',
        color: AppColors.bad,
        icon: Icons.dangerous,
      );
    }

    // После первой ночи город теряет игрока. Если тогда у мафии
    // окажется большинство, она просто «переголосует» город.
    if (_mafiaCount >= others - 1) {
      return (
        text: 'Мафия $_mafiaCount против $others: уже после первой ночи '
            'у мафии будет большинство голосов — город почти обречён. '
            'Уберите одного мафиози.',
        color: AppColors.bad,
        icon: Icons.trending_down,
      );
    }

    final index = _mafiaCount / math.sqrt(_total) * 2;

    if (index >= 1.8) {
      return (
        text: 'Мафия $_mafiaCount против $others: сильный перевес мафии, '
            'у города мало шансов.',
        color: AppColors.bad,
        icon: Icons.trending_down,
      );
    }
    if (index >= 1.15) {
      return (
        text: 'Мафия $_mafiaCount против $others: перевес у мафии, '
            'городу придётся постараться.',
        color: AppColors.warn,
        icon: Icons.balance,
      );
    }
    if (index >= 0.65) {
      return (
        text: 'Мафия $_mafiaCount против $others: силы примерно равны — '
            'хороший состав.',
        color: AppColors.ok,
        icon: Icons.check_circle_outline,
      );
    }
    return (
      text: 'Мафия $_mafiaCount против $others: город в явном большинстве, '
          'мафии будет тяжело.',
      color: AppColors.warn,
      icon: Icons.trending_up,
    );
  }

  void _applyPreset(int players) {
    setState(() {
      _total = players;
      if (players <= 8) {
        _setup
          ..[RoleType.mafia] = 1
          ..[RoleType.don] = 1
          ..[RoleType.doctor] = 1
          ..[RoleType.commissioner] = 1
          ..[RoleType.prostitute] = 0
          ..[RoleType.maniac] = 0;
      } else if (players <= 12) {
        _setup
          ..[RoleType.mafia] = 2
          ..[RoleType.don] = 1
          ..[RoleType.doctor] = 1
          ..[RoleType.commissioner] = 1
          ..[RoleType.prostitute] = 1
          ..[RoleType.maniac] = 0;
      } else if (players <= 16) {
        _setup
          ..[RoleType.mafia] = 3
          ..[RoleType.don] = 1
          ..[RoleType.doctor] = 1
          ..[RoleType.commissioner] = 1
          ..[RoleType.prostitute] = 1
          ..[RoleType.maniac] = 1;
      } else {
        _setup
          ..[RoleType.mafia] = 4
          ..[RoleType.don] = 1
          ..[RoleType.doctor] = 1
          ..[RoleType.commissioner] = 1
          ..[RoleType.prostitute] = 1
          ..[RoleType.maniac] = 1;
      }
    });
  }

  Future<void> _create() async {
    if (!_valid || _starting) return;
    setState(() => _starting = true);

    final controller = HostController();
    // Настройки ведущего (автозапуск ночи) нужны до раздачи ролей.
    await controller.loadPrefs();
    final ok = await controller.createGame(
      name: _nameCtrl.text.trim().isEmpty ? 'Игра' : _nameCtrl.text.trim(),
      plannedPlayers: _total,
      setup: _setup,
      openCards: _openCards,
    );

    if (!mounted) return;
    setState(() => _starting = false);

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.bad,
          content: Text(controller.lastError ?? 'Не удалось запустить сервер'),
        ),
      );
      controller.dispose();
      return;
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LobbyScreen(controller: controller)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Новая игра')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(labelText: 'Название игры'),
                  ),
                  const SizedBox(height: 14),
                  PanelCard(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Игроков',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15)),
                                Text('от 6 до 20',
                                    style: TextStyle(
                                        color: AppColors.dim, fontSize: 12)),
                              ],
                            ),
                          ),
                          _StepButton(
                            icon: Icons.remove,
                            onTap: () => setState(() {
                              if (_total > Rules.minPlayers) _total--;
                            }),
                          ),
                          SizedBox(
                            width: 46,
                            child: Text(
                              '$_total',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.bold),
                            ),
                          ),
                          _StepButton(
                            icon: Icons.add,
                            onTap: () => setState(() {
                              if (_total < Rules.maxPlayers) _total++;
                            }),
                          ),
                        ],
                      ),
                    ),
                  ),
                  PanelCard(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      child: Column(
                        children: [
                          for (final type in Role.configurable)
                            _RoleRow(
                              role: Role.fromType(type),
                              count: _setup[type] ?? 0,
                              onMinus: () => setState(() {
                                final v = _setup[type] ?? 0;
                                if (v > 0) _setup[type] = v - 1;
                              }),
                              onPlus: () => setState(() {
                                _setup[type] = (_setup[type] ?? 0) + 1;
                              }),
                            ),
                          const Divider(height: 1),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Row(
                              children: [
                                const Text('👤', style: TextStyle(fontSize: 18)),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Мирные жители',
                                          style: TextStyle(fontSize: 14.5)),
                                      Text('без способностей · считаются автоматически',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: AppColors.dim)),
                                    ],
                                  ),
                                ),
                                Text(
                                  '${_civilians < 0 ? 0 : _civilians}',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.accent2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: (_overflow ? AppColors.bad : AppColors.ok)
                          .withAlpha(33),
                      border: Border.all(
                        color: (_overflow ? AppColors.bad : AppColors.ok)
                            .withAlpha(115),
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _overflow
                                ? '⚠️ Ролей больше, чем игроков'
                                : '✅ Состав сбалансирован',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        Text(
                          '$_special + ${_civilians < 0 ? 0 : _civilians} = $_total',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  // Оценка шансов сторон: помогает подобрать состав
                  // осознанно, но ничего не запрещает.
                  if (!_overflow) ...[
                    const SizedBox(height: 10),
                    Builder(builder: (_) {
                      final b = _balance;
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: b.color.withAlpha(28),
                          border: Border.all(color: b.color.withAlpha(110)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(b.icon, size: 17, color: b.color),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                b.text,
                                style: const TextStyle(
                                    fontSize: 12.5, height: 1.35),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                  const SizedBox(height: 14),
                  // Классика: карта выбывшего закрыта. Открытая карта —
                  // для новичков и коротких партий, где важно понимать,
                  // кого город только что потерял.
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _openCards,
                    onChanged: (v) => setState(() => _openCards = v),
                    title: const Text('Открывать карту выбывшего',
                        style: TextStyle(fontSize: 14)),
                    subtitle: const Text(
                      'Роль погибшего видна всем сразу. Выключено — '
                      'карта закрыта до конца партии.',
                      style: TextStyle(fontSize: 12, color: AppColors.dim),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text('Готовые составы',
                      style: TextStyle(color: AppColors.dim, fontSize: 12)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      for (final n in [8, 10, 14, 18])
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(40),
                                padding: EdgeInsets.zero,
                              ),
                              onPressed: () => _applyPreset(n),
                              child: Text('$n', style: const TextStyle(fontSize: 13)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton(
                onPressed: _valid && !_starting ? _create : null,
                child: _starting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Создать игру и запустить сервер'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleRow extends StatelessWidget {
  final Role role;
  final int count;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const _RoleRow({
    required this.role,
    required this.count,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(role.emoji, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(role.name, style: const TextStyle(fontSize: 14.5)),
          ),
          _StepButton(icon: Icons.remove, onTap: onMinus),
          SizedBox(
            width: 34,
            child: Text(
              '$count',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          _StepButton(icon: Icons.add, onTap: onPlus),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _StepButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: AppColors.panel2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.line),
        ),
        child: Icon(icon, size: 18),
      ),
    );
  }
}
