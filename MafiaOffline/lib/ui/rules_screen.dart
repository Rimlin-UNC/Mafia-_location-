import 'package:flutter/material.dart';

import '../core/assets.dart';
import '../core/crime_deck.dart';
import '../core/role_guide.dart';
import '../models/role.dart';
import 'card_gallery_screen.dart';
import 'theme.dart';

/// Экран «Правила»: короткая версия `docs/ИГРОКАМ.md` внутри приложения.
///
/// Зачем нужен: бумажную инструкцию теряют, а до партии никто не читает
/// документ в репозитории. Здесь тот же текст и те же карточки, что
/// нарисованы для инструкции — человек листает их в телефоне до начала.
///
/// Содержание осознанно короткое: одна карточка — одна мысль. Полные
/// формулировки живут в `docs/ИГРОКАМ.md`, чтобы не расходились в двух
/// местах (текст берётся из тех же источников: RoleGuide и Rules).
class RulesScreen extends StatelessWidget {
  /// Правила конкретного стола (строки из `TableRules.describeWire`).
  /// Пусто — экран открыт из главного меню, вне партии: раздела нет.
  final List<String> tableRules;

  const RulesScreen({super.key, this.tableRules = const []});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Правила'),
        actions: [
          IconButton(
            tooltip: 'Все карточки',
            icon: const Icon(Icons.grid_view_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CardGalleryScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          // С 1.8.0 это полная книга правил, и она же — в браузере у
          // игроков после согласия с офертой (assets/web/app.js, rulesBook).
          // Пояснение нужно, чтобы человек не искал «более полную» версию
          // в репозитории и не решил, что видит сокращённую выжимку.
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'Полная инструкция: как устроена игра, все роли, фазы и спорные '
              'правила. По ней нельзя понять вашу роль — читать можно при всех.',
              style: TextStyle(fontSize: 12.5, color: AppColors.dim, height: 1.4),
            ),
          ),
          // Первым — то, о чём спорят посреди партии: «а карту открываем?»,
          // «а слово ему дают?». Общие правила ниже, их читают до игры.
          if (tableRules.isNotEmpty)
            _Section(
              title: 'Правила этого стола',
              cards: [
                _Card(
                  title: 'Так играем сегодня',
                  body: tableRules.map((l) => '• $l').join('\n'),
                ),
              ],
            ),
          const _Section(
            title: 'Как это устроено',
            cards: [
              _Card(
                image: A.guideHost,
                title: 'Ведущий и его телефон',
                body: 'Один человек за столом не играет: он держит телефон, '
                    'на котором запущен сервер. Игроки заходят с телефонов '
                    'по QR-коду — приложение им не нужно. Интернет тоже '
                    'не нужен: телефон ведущего создаёт свою сеть.',
              ),
            ],
          ),
          const _Section(
            title: 'Фазы партии',
            cards: [
              _Card(
                image: A.guideNight,
                title: 'Ночь',
                body: 'Город спит, просыпаются только роли. Если у вас нет '
                    'ночного дела, экран останется пустым — это не поломка. '
                    'Порядок: проститутка блокирует, шантажист лишает голоса '
                    'на завтра, доктор лечит, телохранитель прикрывает '
                    'собой, мафия стреляет, маньяк стреляет отдельно, '
                    'свидетель смотрит, охотник ставит метку, комиссар '
                    'проверяет. Комиссар видит ответ сразу, как выберет '
                    'игрока, — одна проверка за ночь.',
              ),
              _Card(
                image: A.guideDay,
                title: 'День',
                body: 'Ведущий объявляет, кто погиб. Дальше — обсуждение. '
                    'Это главная часть игры: ночные роли слабее умения '
                    'слушать и замечать противоречия.',
              ),
              _Card(
                image: A.guideVote,
                title: 'Голосование',
                body: 'Все живые выбирают, кого выгнать. При равенстве — '
                    'второй тур между лидерами. Если и там равенство, '
                    'никто не выбывает и наступает ночь.',
              ),
              _Card(
                title: 'Последнее слово и повторное голосование',
                body: 'Тот, кого выбрал стол, ещё не выбыл. У него '
                    'время по настройке стола (по умолчанию 30 секунд), '
                    'а потом все, кроме него, голосуют ещё раз: выгнать '
                    'или оставить. Выбывает, только если «выгнать» больше, '
                    'чем «оставить»; поровну — остаётся. Убедил стол — '
                    'играет дальше, и наступает ночь. Если за столом играют '
                    'без последнего слова, выбывает сразу тот, кого выбрало '
                    'первое голосование.',
              ),
              _Card(
                image: A.guideWin,
                title: 'Конец партии',
                body: 'Город побеждает, когда не осталось ни мафии, '
                    'ни маньяка. Мафия — когда её столько же, сколько '
                    'горожан, или больше. Маньяк — если остался один. '
                    'Ничья — если не выжил никто.',
              ),
            ],
          ),
          _Section(
            title: 'Роли',
            cards: [
              for (final type in RoleType.values) _RoleCard(type: type),
            ],
          ),
          _Section(
            title: 'Как мафия убирает игрока',
            cards: [
              const _Card(
                title: 'Способ смерти — атмосфера, а не улика',
                body: 'Ведущий может объявить не только кто погиб, но и как. '
                    'Способ не подсказывает, мафия это была или маньяк: '
                    'не ищите в нём информацию.',
              ),
              for (final c in Crime.all)
                _Card(
                  image: c.image,
                  title: c.name,
                  body: 'Вслух: «${c.phrase}».',
                ),
            ],
          ),
          const _Section(
            title: 'Правила, о которых спорят',
            cards: [
              _Card(
                title: 'Слова не доказывают роль',
                body: '«Я же мирный» — не аргумент. Доказательство только '
                    'одно: проверка комиссара. И даже она врёт про дона — '
                    'он выглядит мирным.',
              ),
              _Card(
                title: 'Выбывшие не подсказывают',
                body: 'Ни словами, ни жестами. Это единственное правило, '
                    'за нарушение которого стоит удалять из-за стола: '
                    'мёртвым нечего терять, и они ломают партию быстрее '
                    'любого читерства.',
              ),
              _Card(
                title: 'Не раскрывайте роль без нужды',
                body: 'Чем меньше город знает о вашей роли, тем дольше '
                    'вы живёте. Раскрываться стоит один раз и в правильный '
                    'момент — с фактом, а не с просьбой поверить.',
              ),
              _Card(
                title: 'Воздержаться можно',
                body: 'Но это подарок мафии: ваш голос не достанется городу. '
                    'Воздерживайтесь, только если действительно не можете '
                    'выбрать между двумя подозреваемыми.',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> cards;

  const _Section({required this.title, required this.cards});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.dim,
              letterSpacing: 0.4,
            ),
          ),
        ),
        for (final c in cards) ...[c, const SizedBox(height: 12)],
      ],
    );
  }
}

/// Карточка с картинкой (если есть) и текстом.
class _Card extends StatelessWidget {
  final String? image;
  final String title;
  final String body;

  const _Card({this.image, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (image != null)
            AspectRatio(
              // Карточки нарисованы 2:3. Держим то же соотношение, чтобы
              // рамка на изображении не обрезалась.
              aspectRatio: 2 / 3,
              child: Image.asset(
                image!,
                fit: BoxFit.cover,
                // Битое или отсутствующее изображение не должно ломать
                // экран: остаётся текст, а карточка просто без картинки.
                errorBuilder: (_, __, ___) => const ColoredBox(
                  color: AppColors.panel2,
                  child: Center(
                    child: Icon(Icons.image_not_supported,
                        color: AppColors.dim, size: 32),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(
                      fontSize: 13.5, height: 1.45, color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Карточка роли: картинка + памятка из [RoleGuide].
class _RoleCard extends StatelessWidget {
  final RoleType type;

  const _RoleCard({required this.type});

  @override
  Widget build(BuildContext context) {
    final role = Role.fromType(type);
    final guide = RoleGuide.of(type);
    return _Card(
      image: A.guideRole(type),
      title: '${role.emoji} ${role.name}',
      body: 'Ночью: ${guide.atNight}\n\n'
          'Днём: ${guide.atDay}\n\n'
          'Победа: ${guide.winCondition}',
    );
  }
}
