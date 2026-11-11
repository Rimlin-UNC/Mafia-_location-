import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/assets.dart';
import 'theme.dart';

/// Карточка роли с защитой от подглядывания.
///
/// Три состояния:
///  * **закрыта** — видна только рубашка колоды;
///  * **открыта** — настоящая роль игрока;
///  * **маскировка** — показывается «мирный житель», даже если роль другая.
///
/// Маскировка нужна ровно для описанного случая: если сосед случайно
/// заглянёт в экран, он увидит безобидного мирного жителя.
class RoleCardView extends StatelessWidget {
  final String asset;
  final String name;
  final String emoji;
  final String? subtitle;

  /// Карта раскрыта. Если false — показываем рубашку.
  final bool revealed;

  /// Включена маскировка (карта показывает мирного жителя).
  final bool disguised;

  final VoidCallback? onTap;
  final double height;

  const RoleCardView({
    super.key,
    required this.asset,
    required this.name,
    required this.emoji,
    this.subtitle,
    this.revealed = false,
    this.disguised = false,
    this.onTap,
    this.height = 340,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        transitionBuilder: (child, animation) {
          // Переворот карты вокруг вертикальной оси.
          final rotate = Tween(begin: 3.14159, end: 0.0).animate(animation);
          return AnimatedBuilder(
            animation: rotate,
            child: child,
            builder: (context, ch) {
              final isUnder = (ValueKey(revealed) != child.key);
              var tilt = (animation.value - 0.5).abs() - 0.5;
              tilt *= isUnder ? -0.003 : 0.003;
              return Transform(
                transform: Matrix4.rotationY(rotate.value)..setEntry(3, 0, tilt),
                alignment: Alignment.center,
                child: ch,
              );
            },
          );
        },
        child: revealed ? _face(context) : _back(context),
      ),
    );
  }

  Widget _back(BuildContext context) {
    return Container(
      key: const ValueKey(false),
      height: height,
      decoration: _decoration(const Color(0xFF6B5CA5)),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(A.cardBack, fit: BoxFit.cover),
          Container(color: Colors.black.withAlpha(60)),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(120),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFD4A84E), width: 2),
                  ),
                  child: const Icon(Icons.visibility_off,
                      size: 30, color: Color(0xFFF7D684)),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Нажмите, чтобы\nпосмотреть роль',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: Color(0xFFE8DCC0),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _face(BuildContext context) {
    return Container(
      key: const ValueKey(true),
      height: height,
      decoration: _decoration(
          disguised ? const Color(0xFF7A8B5A) : const Color(0xFFD4A84E)),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(asset, fit: BoxFit.cover),
          // Затемнение снизу, чтобы название читалось поверх картинки.
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.center,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withAlpha(210),
                ],
              ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(emoji, style: const TextStyle(fontSize: 26)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(blurRadius: 8, color: Colors.black)
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFFD8D2E4),
                      shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Явная пометка, что роль сейчас подменена — видит только владелец.
          if (disguised)
            Positioned(
              top: 10,
              left: 10,
              right: 10,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: const Color(0xFF2F3A22).withAlpha(235),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: const Color(0xFF8FA86A)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.shield_moon, size: 15, color: Color(0xFFBFD79A)),
                    SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'Маскировка включена — показан мирный',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFFBFD79A)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  BoxDecoration _decoration(Color border) => BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(140),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      );
}

/// Кнопка-переключатель маскировки.
class DisguiseToggle extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;

  const DisguiseToggle({super.key, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active
          ? const Color(0xFF2F3A22)
          : AppColors.panel2,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? const Color(0xFF8FA86A) : AppColors.line,
            ),
          ),
          child: Row(
            children: [
              Image.asset(
                A.shield,
                width: 22,
                height: 22,
                color: active ? const Color(0xFFBFD79A) : AppColors.dim,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      active ? 'Маскировка включена' : 'Скрыть настоящую роль',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: active
                            ? const Color(0xFFBFD79A)
                            : Colors.white,
                      ),
                    ),
                    Text(
                      active
                          ? 'Подсмотревший увидит мирного жителя'
                          : 'На случай, если кто-то заглянёт в экран',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.dim),
                    ),
                  ],
                ),
              ),
              Switch(
                value: active,
                onChanged: (_) => onTap(),
                activeColor: const Color(0xFFBFD79A),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Фон экрана, зависящий от фазы.
class PhaseBackground extends StatelessWidget {
  final String asset;
  final Widget child;

  const PhaseBackground({super.key, required this.asset, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(asset, fit: BoxFit.cover),
        // Затемняем, чтобы интерфейс поверх оставался читаемым.
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
          child: Container(color: AppColors.bg.withAlpha(190)),
        ),
        child,
      ],
    );
  }
}
