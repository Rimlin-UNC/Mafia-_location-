import 'package:flutter/material.dart';

import '../../core/assets.dart';
import '../../core/role_guide.dart';
import '../../models/role.dart';
import '../../player/player_controller.dart';
import '../role_card_view.dart';
import '../theme.dart';

/// Экран получения роли.
///
/// Показывается один раз, сразу после раздачи. Сначала предупреждение —
/// чтобы игрок успел отвернуть экран от соседей, — и только после
/// подтверждения открывается карточка с подробной памяткой.
class RoleRevealScreen extends StatelessWidget {
  final PlayerController controller;
  const RoleRevealScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return PhaseBackground(
      asset: A.bgNight,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Spacer(),
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: AppColors.panel.withAlpha(240),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.warn.withAlpha(140)),
                ),
                child: Column(
                  children: [
                    const Text('🤫', style: TextStyle(fontSize: 54)),
                    const SizedBox(height: 12),
                    const Text(
                      'Сейчас вы увидите свою роль',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Убедитесь, что никто не смотрит в ваш экран. '
                      'Роль знаете только вы и ведущий.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13.5, color: AppColors.dim),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.bg.withAlpha(160),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.shield_moon,
                              size: 17, color: Color(0xFFBFD79A)),
                          SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              'Если боитесь, что подсмотрят, — включите '
                              'маскировку на следующем экране: карта будет '
                              'показывать мирного жителя.',
                              style: TextStyle(
                                  fontSize: 11.5, color: AppColors.dim),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              ElevatedButton.icon(
                icon: const Icon(Icons.visibility),
                label: const Text('Я один — показать роль'),
                onPressed: () {
                  controller.confirmRoleReveal();
                  showRoleSheet(context, controller, firstTime: true);
                },
              ),
              const SizedBox(height: 10),
              const Text(
                'Ведущий видит, что вы получили роль',
                style: TextStyle(fontSize: 11.5, color: AppColors.dim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Шторка с картой роли и полной памяткой.
/// Используется и при первом показе, и по кнопке «Моя роль».
Future<void> showRoleSheet(
  BuildContext context,
  PlayerController c, {
  bool firstTime = false,
}) {
  final type = _typeByName(c.roleName);
  final guide = RoleGuide.of(type);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: !firstTime,
    enableDrag: !firstTime,
    backgroundColor: AppColors.panel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, setSheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        maxChildSize: 0.95,
        builder: (_, scroll) => Column(
          children: [
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.all(18),
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
                  RoleCardView(
                    asset: c.shownCard.asset,
                    name: c.shownCard.name,
                    emoji: c.shownCard.emoji,
                    revealed: true,
                    disguised: c.disguised,
                    height: 300,
                  ),
                  const SizedBox(height: 12),
                  DisguiseToggle(
                    active: c.disguised,
                    onTap: () {
                      c.toggleDisguise();
                      setSheet(() {});
                    },
                  ),
                  const SizedBox(height: 16),

                  if (!c.disguised) ...[
                    _Block(
                      icon: Icons.flag,
                      title: 'Ваша задача',
                      text: guide.goal,
                      color: AppColors.accent2,
                    ),
                    _Block(
                      icon: Icons.nightlight_round,
                      title: 'Ночью',
                      text: guide.atNight,
                      color: const Color(0xFF7C9BD4),
                    ),
                    _Block(
                      icon: Icons.wb_sunny,
                      title: 'Днём',
                      text: guide.atDay,
                      color: AppColors.warn,
                    ),
                    _Block(
                      icon: Icons.emoji_events,
                      title: 'Когда вы побеждаете',
                      text: guide.winCondition,
                      color: AppColors.ok,
                    ),
                    if (guide.tips.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      const Text('Советы',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 8),
                      for (final tip in guide.tips)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 7),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('• ',
                                  style: TextStyle(color: AppColors.dim)),
                              Expanded(
                                child: Text(tip,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: Color(0xFFC7CBDB))),
                              ),
                            ],
                          ),
                        ),
                    ],
                    if (c.teammates.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.bad.withAlpha(28),
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: AppColors.bad.withAlpha(110)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('ВАША КОМАНДА',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.dim,
                                    letterSpacing: 1)),
                            const SizedBox(height: 6),
                            Text(
                              c.teammates
                                  .map((t) =>
                                      t.isDon ? '${t.name} 🎩 (дон)' : t.name)
                                  .join('\n'),
                              style: const TextStyle(
                                  fontSize: 15, height: 1.5),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ] else
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2F3A22).withAlpha(200),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'Маскировка включена: памятка и состав команды '
                        'скрыты, чтобы их не увидели через плечо. '
                        'Выключите маскировку, когда будете один.',
                        style:
                            TextStyle(fontSize: 12.5, color: Color(0xFFBFD79A)),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(firstTime ? 'Понятно, я готов' : 'Закрыть'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

RoleType _typeByName(String? name) {
  for (final t in RoleType.values) {
    if (Role.fromType(t).name == name) return t;
  }
  return RoleType.civilian;
}

class _Block extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final Color color;

  const _Block({
    required this.icon,
    required this.title,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.panel2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text(title,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: color)),
            ],
          ),
          const SizedBox(height: 6),
          Text(text,
              style: const TextStyle(fontSize: 13.5, height: 1.42)),
        ],
      ),
    );
  }
}
