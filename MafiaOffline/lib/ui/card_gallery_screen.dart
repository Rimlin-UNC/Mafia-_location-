import 'package:flutter/material.dart';

import '../core/assets.dart';
import '../core/crime_deck.dart';
import '../core/story_deck.dart';
import '../models/role.dart';
import 'theme.dart';

/// Одна карточка в каталоге: картинка, название, короткая подпись, группа.
class CardEntry {
  final String? image;
  final String title;
  final String subtitle;
  final String group;

  const CardEntry({
    required this.image,
    required this.title,
    required this.subtitle,
    required this.group,
  });
}

/// Общий каталог всех карточек проекта: роли, фазы, злодеяния, суд, сюжет.
///
/// Зачем отдельным экраном, а не разделом в «Правилах»: карточек больше
/// тридцати, и списком они превращаются в тридцать экранов прокрутки.
/// Сетка показывает всё сразу и даёт открыть любую на весь экран.
///
/// Данные берутся из тех же источников, что и игра (RoleType, CrimeDeck,
/// StoryDeck), поэтому каталог не может разойтись с набором.
class CardGalleryScreen extends StatelessWidget {
  const CardGalleryScreen({super.key});

  /// Порядок групп: от «кто я» к «что происходит».
  static const List<String> groups = [
    'Роли',
    'Фазы',
    'Злодеяния',
    'Суд',
    'Сюжет',
  ];

  static List<CardEntry> entries() {
    final out = <CardEntry>[];

    for (final type in RoleType.values) {
      final role = Role.fromType(type);
      out.add(CardEntry(
        image: A.guideRole(type),
        title: '${role.emoji} ${role.name}',
        subtitle: role.side == Side.mafia
            ? 'мафия'
            : role.side == Side.solo
                ? 'одиночка'
                : 'город',
        group: 'Роли',
      ));
    }

    out.addAll(const [
      CardEntry(
        image: A.guideNight,
        title: '🌙 Ночь',
        subtitle: 'роли действуют',
        group: 'Фазы',
      ),
      CardEntry(
        image: A.guideDay,
        title: '☀ День',
        subtitle: 'обсуждение',
        group: 'Фазы',
      ),
      CardEntry(
        image: A.guideVote,
        title: '🗳 Голосование',
        subtitle: 'кого выгнать',
        group: 'Фазы',
      ),
      CardEntry(
        image: A.guideWin,
        title: '🏆 Финал',
        subtitle: 'итог партии',
        group: 'Фазы',
      ),
    ]);

    for (final c in Crime.all) {
      out.add(CardEntry(
        image: c.image,
        title: '☠ ${c.name}',
        subtitle: c.phrase,
        group: 'Злодеяния',
      ));
    }

    out.addAll(const [
      CardEntry(
        image: 'assets/court/01_trial.jpg',
        title: '⚖ Суд',
        subtitle: 'старт голосования',
        group: 'Суд',
      ),
      CardEntry(
        image: 'assets/court/02_verdict.jpg',
        title: '⚖ Приговор',
        subtitle: 'счёт закрыт',
        group: 'Суд',
      ),
      CardEntry(
        image: 'assets/court/03_exile.jpg',
        title: '⚖ Изгнание',
        subtitle: 'выбывший уходит',
        group: 'Суд',
      ),
      CardEntry(
        image: 'assets/court/04_deadlock.jpg',
        title: '⚖ Раскол',
        subtitle: 'второй тур',
        group: 'Суд',
      ),
    ]);

    for (final c in StoryDeck.all) {
      out.add(CardEntry(
        image: c.image,
        title: '🎬 ${c.title}',
        subtitle: c.caption,
        group: 'Сюжет',
      ));
    }

    return out;
  }

  @override
  Widget build(BuildContext context) {
    final all = entries();
    return Scaffold(
      appBar: AppBar(
        title: Text('Все карточки (${all.length})'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          for (final g in groups) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
              child: Row(
                children: [
                  Text(
                    g,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.dim,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${all.where((e) => e.group == g).length}',
                    style: const TextStyle(fontSize: 12, color: AppColors.dim),
                  ),
                ],
              ),
            ),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.58,
              children: [
                for (final e in all.where((e) => e.group == g))
                  _GalleryTile(entry: e),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _GalleryTile extends StatelessWidget {
  final CardEntry entry;

  const _GalleryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => _CardFullScreen(entry: entry)),
      ),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: entry.image == null
                  ? const ColoredBox(
                      color: AppColors.panel2,
                      child: Center(
                        child: Icon(Icons.movie_outlined,
                            color: AppColors.dim, size: 28),
                      ),
                    )
                  : Image.asset(
                      entry.image!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorBuilder: (_, __, ___) => const ColoredBox(
                        color: AppColors.panel2,
                        child: Center(
                          child: Icon(Icons.image_not_supported,
                              color: AppColors.dim, size: 26),
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 8, 9, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 10.5, color: AppColors.dim),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Просмотр одной карточки на весь экран: та же картинка, но крупно,
/// с полной подписью. Нужен, чтобы разглядеть детали за столом.
class _CardFullScreen extends StatelessWidget {
  final CardEntry entry;

  const _CardFullScreen({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(entry.title)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (entry.image != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset(
                    entry.image!,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              const SizedBox(height: 14),
              Text(
                entry.subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
