import 'package:flutter/material.dart';

import '../../core/assets.dart';
import '../../core/game_engine.dart';
import '../../core/story_deck.dart';
import '../../models/game_phase.dart';
import '../../net/client_connection.dart';
import '../../player/player_controller.dart';
import '../role_card_view.dart';
import 'role_reveal_screen.dart';
import '../rules_screen.dart';
import '../theme.dart';
import '../widgets.dart';

/// Единственный экран игрока. Содержимое меняется в зависимости от фазы,
/// роли и статуса «жив / выбыл».
class PlayerGameScreen extends StatefulWidget {
  final PlayerController controller;
  const PlayerGameScreen({super.key, required this.controller});

  @override
  State<PlayerGameScreen> createState() => _PlayerGameScreenState();
}

class _PlayerGameScreenState extends State<PlayerGameScreen> {
  PlayerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_update);
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_update);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Обрыв связи — отдельный экран поверх всего.
    if (c.status == ConnStatus.reconnecting ||
        c.status == ConnStatus.failed) {
      return _DisconnectedView(controller: c);
    }

    if (c.phase == GamePhase.ended) {
      return _GameOverView(controller: c);
    }

    // Роль получена, но игрок ещё не готов её увидеть.
    if (c.awaitingRoleReveal) {
      return Scaffold(body: RoleRevealScreen(controller: c));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(c.gameName.isEmpty ? 'Мафия' : c.gameName,
            overflow: TextOverflow.ellipsis),
        actions: [
          // Правила — у всех и всегда: по этой кнопке нельзя понять роль.
          IconButton(
            tooltip: 'Правила',
            icon: const Icon(Icons.menu_book_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RulesScreen(
                  tableRules: TableRules.describeWire(c.tableRules),
                ),
              ),
            ),
          ),
          if (c.roleName != null)
            IconButton(
              tooltip: 'Моя роль',
              icon: const Icon(Icons.badge_outlined),
              onPressed: _showRole,
            ),
        ],
      ),
      body: PhaseBackground(
        asset: switch (c.phase) {
          GamePhase.night => A.bgNight,
          GamePhase.voting => A.bgVote,
          _ => A.bgDay,
        },
        child: SafeArea(
          child: c.phase == GamePhase.waiting ||
                  c.phase == GamePhase.rolesCheck
              ? _buildWaiting()
              : (!c.isAlive ? _buildSpectator() : _buildActive()),
        ),
      ),
      bottomNavigationBar: _buildConnectionBar(),
    );
  }

  // ---------- ожидание старта ----------
  Widget _buildWaiting() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 24),
        const Center(child: Text('⏳', style: TextStyle(fontSize: 42))),
        const SizedBox(height: 10),
        const Center(
          child: Text('Ожидание начала игры…',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text('Подключено: ${c.lobby.length}',
              style: const TextStyle(color: AppColors.dim, fontSize: 13)),
        ),
        const SizedBox(height: 14),
        if (c.banner != null)
          InfoCard(
            icon: Icons.info_outline,
            text: c.banner!,
            color: AppColors.accent,
          ),

        // Фаза раздачи ролей: партия уже идёт, но ночь ждёт, пока все
        // прочитают роль. Игроку важно понимать, чего именно ждут.
        if (c.phase == GamePhase.rolesCheck) ...[
          const SizedBox(height: 4),
          const Center(child: Text('🎴', style: TextStyle(fontSize: 34))),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Ведущий раздал роли',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 6),
          const Center(
            child: Text(
              'Ночь начнётся, когда все прочитают свою роль.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.dim, fontSize: 12.5),
            ),
          ),
          if (c.roleName != null) ...[
            const SizedBox(height: 14),
            Center(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.badge_outlined, size: 18),
                label: const Text('Открыть мою роль'),
                onPressed: _showRole,
              ),
            ),
          ],
          const SizedBox(height: 14),
        ],

        // Имя видно игроку, но менять его может только ведущий —
        // иначе в списке возникнет путаница посреди партии.
        Container(
          padding: const EdgeInsets.all(13),
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(
            color: AppColors.panel.withAlpha(220),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            children: [
              const Icon(Icons.badge_outlined,
                  size: 18, color: AppColors.accent2),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Вы: ${c.playerName}',
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w600)),
                    const Text(
                      'Изменить имя может только ведущий',
                      style: TextStyle(fontSize: 11.5, color: AppColors.dim),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.lock_outline, size: 15, color: AppColors.dim),
            ],
          ),
        ),
        for (final p in c.lobby)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: PlayerTile(
              name: p.name,
              colorHex: p.color,
              subtitle: p.name == c.playerName
                  ? 'это вы'
                  : p.bot
                      ? 'бот'
                      : (p.online ? 'подключён' : 'нет связи'),
              // У бота нет сокета: красная точка «нет связи» на нём
              // читалась бы как проблема, которой нет.
              trailing:
                  StatusDot(p.bot || p.online ? AppColors.ok : AppColors.bad),
            ),
          ),
      ],
    );
  }

  // ---------- активная игра ----------
  Widget _buildActive() {
    final isNight = c.phase == GamePhase.night;
    final showTargets = c.canAct && c.targets.isNotEmpty && !c.actionSent;
    // Повторное голосование: вопрос один — выгнать или оставить.
    final isVerdict = c.phase == GamePhase.voting && c.verdictName != null;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              PhaseBanner(
                title: _phaseTitle(),
                right: formatTime(c.timeLeft),
                isNight: isNight,
              ),
              ..._tableStatus(),
              const SizedBox(height: 12),

              if (c.banner != null)
                InfoCard(
                  icon: Icons.campaign,
                  text: c.banner!,
                  color: AppColors.bad,
                ),

              if (c.roleName != null && isNight) ...[
                RoleCardView(
                  asset: c.shownCard.asset,
                  name: c.shownCard.name,
                  emoji: c.shownCard.emoji,
                  revealed: c.cardRevealed,
                  disguised: c.disguised,
                  onTap: c.toggleCard,
                  subtitle: c.disguised || c.teammates.isEmpty
                      ? null
                      : 'Союзники: ${c.teammates.map((t) => t.isDon ? '${t.name} 🎩' : t.name).join(', ')}',
                ),
                const SizedBox(height: 10),
                DisguiseToggle(active: c.disguised, onTap: c.toggleDisguise),
              ],

              const SizedBox(height: 14),

              if (showTargets && isVerdict)
                _buildVerdictQuestion()
              else if (showTargets) ...[
                Text(
                  c.prompt,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                for (final t in c.targets)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: PlayerTile(
                      name: t.name,
                      colorHex: t.color,
                      selected: c.selectedTargetId == t.id,
                      onTap: () => c.select(t.id),
                    ),
                  ),
              ] else
                _buildPassive(),
            ],
          ),
        ),
        if (showTargets && isVerdict)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                ElevatedButton(
                  style:
                      ElevatedButton.styleFrom(backgroundColor: AppColors.bad),
                  onPressed: () => c.submitVerdict(exile: true),
                  child: Text('Выгнать: ${c.verdictName}'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => c.submitVerdict(exile: false),
                  child: const Text('Оставить в игре'),
                ),
              ],
            ),
          )
        else if (showTargets)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                ElevatedButton(
                  onPressed:
                      c.selectedTargetId == null ? null : () => c.submit(),
                  child: Text(c.phase == GamePhase.voting
                      ? 'Проголосовать'
                      : 'Отправить выбор'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => c.submit(skip: true),
                  child: Text(c.phase == GamePhase.voting
                      ? 'Воздержаться'
                      : 'Пропустить ход'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Вопрос повторного голосования. Кнопки — внизу экрана, как у обычного
  /// голосования: палец уже знает, где они.
  Widget _buildVerdictQuestion() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const Text('⚖️', style: TextStyle(fontSize: 54)),
          const SizedBox(height: 10),
          Text(
            c.prompt,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Вы слышали последнее слово. Игрок выбывает, только если '
              'за изгнание проголосует больше, чем против. '
              'Поровну — остаётся.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.dim),
            ),
          ),
        ],
      ),
    );
  }

  /// Ответ комиссару на проверку этой ночи. Виден только до рассвета:
  /// днём телефон лежит на столе, и ответ остаётся лишь в «Моя роль».
  Widget _buildNightCheck(CheckInfo check) {
    final color = check.blocked
        ? AppColors.dim
        : (check.isMafia ? AppColors.bad : AppColors.ok);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        border: Border.all(color: color.withAlpha(102)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(check.blocked ? Icons.block : Icons.search,
              color: color, size: 34),
          const SizedBox(height: 8),
          Text(
            check.blocked
                ? 'Проверка не состоялась'
                : '${check.name} — ${check.isMafia ? 'МАФИЯ' : 'не мафия'}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            check.blocked
                ? 'Этой ночью вас заблокировали. Следующая проверка — '
                    'следующей ночью.'
                : 'Одна проверка за ночь. Утром ответ останется '
                    'только в «Моя роль».',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: AppColors.dim),
          ),
        ],
      ),
    );
  }

  /// Наблюдение свидетеля: один факт, без ролей и без чужих имён.
  Widget _buildWatchResult(WatchInfo watch) {
    final color = watch.acted ? AppColors.warn : AppColors.ok;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        border: Border.all(color: color.withAlpha(102)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(watch.acted ? Icons.directions_walk : Icons.bedtime,
              color: color, size: 34),
          const SizedBox(height: 8),
          Text(
            watch.acted
                ? '${watch.name} выходил из дома'
                : '${watch.name} не выходил из дома',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Ночью выходят не только убийцы: доктор лечит, комиссар '
            'проверяет, проститутка блокирует. Факт сужает круг, '
            'но никого не обвиняет.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: AppColors.dim),
          ),
        ],
      ),
    );
  }

  /// Заголовок фазы с учётом ночи знакомства и последнего слова.
  String _phaseTitle() {
    if (c.lastWordName != null) return 'Последнее слово';
    if (c.phase == GamePhase.voting && c.verdictName != null) {
      return 'Повторное голосование';
    }
    if (c.introNight) return 'Ночь знакомства';
    return '${c.phase.title}${c.round > 0 ? ' ${c.round}' : ''}';
  }

  /// Строка «живых N из M» и карточка момента от ведущего.
  /// Одинаковы у всех игроков — по ним нельзя понять роль.
  List<Widget> _tableStatus() {
    final story = StoryDeck.byId(c.storyId);
    return [
      if (c.totalCount > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Живых: ${c.aliveCount} из ${c.totalCount}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: AppColors.dim),
          ),
        ),
      if (story != null) ...[
        const SizedBox(height: 10),
        InfoCard(
          icon: Icons.movie_filter_outlined,
          text: '${story.title}. ${story.line}',
          color: AppColors.accent2,
        ),
      ],
    ];
  }

  /// Экран, когда игрок в этой фазе не действует.
  Widget _buildPassive() {
    final mark = c.hunterMark;
    // Охотнику метка нужна на экране в любой фазе: она решает, кого он
    // заберёт, и вспоминать её по памяти — плохая идея.
    if (mark != null && mark.isNotEmpty) {
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.accent2.withAlpha(26),
              border: Border.all(color: AppColors.accent2.withAlpha(102)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                const Icon(Icons.gps_fixed,
                    color: AppColors.accent2, size: 34),
                const SizedBox(height: 8),
                Text('Ваша метка: $mark',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  'Если вас убьют или выгонят голосованием, $mark погибнет '
                  'вместе с вами. Метку можно сменить каждой ночью.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.dim),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _passiveCore(),
        ],
      );
    }
    return _passiveCore();
  }

  Widget _passiveCore() {
    final check = c.nightCheck;
    if (check != null) return _buildNightCheck(check);
    // Запуганный шантажистом: без объяснения он решит, что сломался телефон.
    // Проверяем ДО наблюдения: во время голосования важнее объяснить, почему
    // нет кнопок, чем показать вчерашний факт.
    if (c.silenced && c.phase == GamePhase.voting) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.warn.withAlpha(26),
          border: Border.all(color: AppColors.warn.withAlpha(102)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Column(
          children: [
            Icon(Icons.volume_off, color: AppColors.warn, size: 34),
            SizedBox(height: 8),
            Text('Сегодня вы не голосуете',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            SizedBox(height: 4),
            Text(
              'Вас запугал шантажист: на этот день у вас отнят голос. '
              'Скажите об этом вслух — стол вправе это учесть, '
              'а вы вправе напомнить, что молчите не по своей воле.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: AppColors.dim),
            ),
          ],
        ),
      );
    }
    // Свидетель: факт «выходил / не выходил» важнее анимации «выбор принят».
    // Показываем его сразу, как только он пришёл: и ночью, и днём — это
    // ровно то, что человек уже знает, и держать это до рассвета незачем.
    if (c.watch != null) {
      return _buildWatchResult(c.watch!);
    }
    if (c.actionSent) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.ok.withAlpha(26),
          border: Border.all(color: AppColors.ok.withAlpha(102)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Column(
          children: [
            Icon(Icons.check_circle_outline, color: AppColors.ok, size: 34),
            SizedBox(height: 8),
            Text('Ваш выбор принят',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            SizedBox(height: 4),
            Text('Ожидайте следующей фазы',
                style: TextStyle(fontSize: 12.5, color: AppColors.dim)),
          ],
        ),
      );
    }

    final isNight = c.phase == GamePhase.night;
    final lastWord = c.lastWordName != null;
    final verdict = c.phase == GamePhase.voting && c.verdictName != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Text(
              lastWord
                  ? '🎤'
                  : verdict
                      ? '⚖️'
                      : (isNight ? '😴' : '💬'),
              style: const TextStyle(fontSize: 60)),
          const SizedBox(height: 10),
          Text(
            c.prompt,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Text(
              lastWord
                  ? (c.lastWordIsMe
                      ? 'Вы ещё в игре. Убедите стол: после вашего слова '
                          'все голосуют ещё раз — выгнать или оставить.'
                      : 'Слушайте. После слова — повторное голосование: '
                          'выгнать или оставить.')
                  : verdict
                      ? (c.verdictIsMe
                          ? 'Вы не голосуете. Поровну или больше «оставить» — '
                              'вы остаётесь в игре.'
                          : 'Ждём остальных.')
                      : isNight
                      ? (c.introNight
                          ? 'Ночь знакомства: сегодня никто не погибает.'
                          : 'Город засыпает. Ваша роль сейчас не действует.')
                      : 'Обсуждайте вслух. Скоро голосование.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.dim),
            ),
          ),
          if (c.roleName != null) ...[
            const SizedBox(height: 18),
            Chip(
              backgroundColor: AppColors.panel2,
              side: const BorderSide(color: AppColors.line),
              label: Text('${c.roleEmoji ?? ''} ${c.roleName}'),
            ),
          ],
        ],
      ),
    );
  }

  // ---------- режим зрителя ----------
  Widget _buildSpectator() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.bad.withAlpha(23),
            border: Border.all(color: AppColors.bad.withAlpha(102)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              const Text('☠️', style: TextStyle(fontSize: 42)),
              const SizedBox(height: 6),
              const Text('Вы выбыли из игры',
                  style:
                      TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                'Ваша роль: ${c.roleEmoji ?? ''} ${c.roleName ?? '—'}',
                style: const TextStyle(fontSize: 13, color: AppColors.dim),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PhaseBanner(
          title: _phaseTitle(),
          right: formatTime(c.timeLeft),
          isNight: c.phase == GamePhase.night,
        ),
        ..._tableStatus(),
        const SizedBox(height: 16),
        const Text('Лог событий',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF101219),
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (c.eventLog.isEmpty)
                const Text('Пока пусто',
                    style: TextStyle(color: AppColors.dim, fontSize: 12))
              else
                for (final e in c.eventLog)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(e,
                        style: const TextStyle(
                            fontSize: 12.5, color: Color(0xFFAAB0C6))),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: () async {
            await c.leave();
            if (mounted) Navigator.popUntil(context, (r) => r.isFirst);
          },
          child: const Text('Выйти из игры'),
        ),
      ],
    );
  }

  // ---------- нижняя панель связи ----------
  Widget _buildConnectionBar() {
    final online = c.status == ConnStatus.connected;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          color: AppColors.panel,
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        child: Row(
          children: [
            StatusDot(online ? AppColors.ok : AppColors.bad),
            const SizedBox(width: 8),
            Text(
              online ? 'Подключено' : 'Нет связи',
              style: const TextStyle(fontSize: 12, color: AppColors.dim),
            ),
            const Spacer(),
            if (c.roleName != null)
              TextButton(
                onPressed: _showRole,
                child: const Text('Моя роль', style: TextStyle(fontSize: 12.5)),
              ),
          ],
        ),
      ),
    );
  }

  void _showRole() => showRoleSheet(context, c);

}

/// Экран обрыва связи с автоматическим переподключением.
class _DisconnectedView extends StatelessWidget {
  final PlayerController controller;
  const _DisconnectedView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final failed = controller.status == ConnStatus.failed;
    return Scaffold(
      appBar: AppBar(title: const Text('Соединение потеряно')),
      body: SafeArea(
        // Экран обрыва связи показывается именно в тот момент, когда
        // человек нервничает и читает всё подряд. Если содержимое выше
        // экрана (крупный шрифт, маленький телефон), оно должно
        // прокручиваться, а не обрезаться: иначе теряется кнопка «Выйти
        // из игры», и игрок застревает на этом экране.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('📡', style: TextStyle(fontSize: 58)),
              const SizedBox(height: 12),
              Text(
                failed
                    ? 'Не удалось переподключиться'
                    : 'Связь с ведущим потеряна',
                style:
                    const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                failed
                    ? 'Проверьте, что вы подключены к сети ведущего.'
                    : 'Переподключаемся автоматически. '
                        'Попытка ${controller.reconnectAttempt} — '
                        'сдаваться не будем, пока вы не выйдете сами.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: AppColors.dim),
              ),
              const SizedBox(height: 20),
              if (!failed)
                const SizedBox(
                  width: 180,
                  child: LinearProgressIndicator(),
                ),
              const SizedBox(height: 20),
              const Text(
                'Партия продолжается без вас: ходы за это время пропускаются. '
                'Когда связь вернётся, вы получите текущее состояние.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.dim),
              ),
              const SizedBox(height: 24),
              // Кнопка полезна и во время бесконечных попыток: она сбрасывает
              // накопленную паузу (до 8 с) и пробует прямо сейчас.
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Подключиться сейчас'),
                onPressed: controller.retry,
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () async {
                  await controller.leave();
                  if (context.mounted) {
                    Navigator.popUntil(context, (r) => r.isFirst);
                  }
                },
                child: const Text('Выйти из игры',
                    style: TextStyle(color: AppColors.dim)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Итоги партии на стороне игрока.
class _GameOverView extends StatelessWidget {
  final PlayerController controller;
  const _GameOverView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Игра окончена')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SizedBox(height: 16),
            const Center(child: Text('🎉', style: TextStyle(fontSize: 54))),
            const SizedBox(height: 10),
            Center(
              child: Text(
                controller.gameOverTitle ?? 'Партия завершена',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 22),
            const Text('Расклад ролей',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 10),
            for (final r in controller.reveal)
              PanelCard(
                child: ListTile(
                  leading: Text(r.emoji, style: const TextStyle(fontSize: 22)),
                  title: Text(r.name),
                  subtitle: Text(r.role,
                      style: const TextStyle(color: AppColors.dim)),
                  trailing: Text(
                    r.alive ? 'выжил' : 'выбыл',
                    style:
                        const TextStyle(fontSize: 12, color: AppColors.dim),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                await controller.leave();
                if (context.mounted) {
                  Navigator.popUntil(context, (r) => r.isFirst);
                }
              },
              child: const Text('В главное меню'),
            ),
          ],
        ),
      ),
    );
  }
}
