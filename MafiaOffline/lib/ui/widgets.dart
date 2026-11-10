import 'package:flutter/material.dart';

import 'theme.dart';

/// Карточка-панель. Своя, а не Material Card: тема Card меняла имя класса
/// между версиями Flutter (CardTheme → CardThemeData), из-за чего проект
/// переставал собираться. Здесь поведение одинаково на всех версиях.
class PanelCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry margin;

  const PanelCard({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.only(bottom: 10),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// Строка игрока в списке.
class PlayerTile extends StatelessWidget {
  final String name;
  final String colorHex;
  final String? subtitle;
  final bool alive;
  final bool selected;
  final bool highlighted;
  final Widget? trailing;
  final VoidCallback? onTap;

  const PlayerTile({
    super.key,
    required this.name,
    required this.colorHex,
    this.subtitle,
    this.alive = true,
    this.selected = false,
    this.highlighted = false,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(colorHex);
    return Opacity(
      opacity: alive ? 1 : 0.45,
      child: Material(
        color: selected
            ? AppColors.accent.withAlpha(46)
            : AppColors.panel,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? AppColors.accent
                    : highlighted
                        ? AppColors.bad
                        : AppColors.line,
                width: selected || highlighted ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: color,
                  child: Text(
                    name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.black87,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          decoration:
                              alive ? null : TextDecoration.lineThrough,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.dim,
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Цветная полоса текущей фазы.
class PhaseBanner extends StatelessWidget {
  final String title;
  final String right;
  final bool isNight;

  const PhaseBanner({
    super.key,
    required this.title,
    required this.right,
    required this.isNight,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          colors: isNight
              ? const [Color(0xFF1B2547), AppColors.night]
              : const [Color(0xFF5A4A12), AppColors.day],
        ),
      ),
      child: Row(
        children: [
          Text(isNight ? '🌙' : '☀️', style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 16)),
          const Spacer(),
          Text(right,
              style: const TextStyle(fontSize: 13, color: Color(0xFFCDD3EA))),
        ],
      ),
    );
  }
}

/// Индикатор состояния соединения.
class StatusDot extends StatelessWidget {
  final Color color;
  const StatusDot(this.color, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// Информационная плашка.
class InfoCard extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;

  const InfoCard({
    super.key,
    required this.text,
    this.color = AppColors.accent,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withAlpha(31),
        border: Border.all(color: color.withAlpha(115)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 13.5)),
          ),
        ],
      ),
    );
  }
}

/// Крупная карточка роли на экране игрока.
class RoleCard extends StatelessWidget {
  final String emoji;
  final String name;
  final String? subtitle;

  const RoleCard({
    super.key,
    required this.emoji,
    required this.name,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3B1D33), Color(0xFF241426)],
        ),
        border: Border.all(color: const Color(0xFF6B2C4E)),
      ),
      child: Column(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 42)),
          const SizedBox(height: 4),
          Text(name,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFFE0C3D4)),
            ),
          ],
        ],
      ),
    );
  }
}
