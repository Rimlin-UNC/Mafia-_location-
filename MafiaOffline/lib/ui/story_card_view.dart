import 'package:flutter/material.dart';

import '../core/story_deck.dart';
import 'theme.dart';

/// Полноэкранный показ сюжетной карточки.
///
/// Показывается и ведущему, и игрокам (в вебе — своя разметка, но с тем же
/// содержимым). Закрывается одной кнопкой; на стороне игрока — после того,
/// как ведущий уберёт карточку, либо сам по себе, чтобы не запирать экран.
///
/// Почему полноэкранно, а не тостом: карточка — это пауза в партии,
/// ведущий читает фразу вслух. Тост прочитают вполглаза и забудут.
class StoryCardView extends StatelessWidget {
  final StoryCard card;

  /// null — только просмотр (игроку нельзя закрыть чужим действием).
  final VoidCallback? onClose;

  const StoryCardView({super.key, required this.card, this.onClose});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withAlpha(235),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 460),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: AppColors.panel,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.accent.withAlpha(90)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (card.image != null)
                    AspectRatio(
                      aspectRatio: 2 / 3,
                      child: Image.asset(
                        card.image!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          card.title,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: AppColors.accent2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          card.line,
                          style: const TextStyle(
                              fontSize: 15, height: 1.45),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          card.caption,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.dim),
                        ),
                      ],
                    ),
                  ),
                  if (onClose != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: onClose,
                          child: const Text('Дальше'),
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
