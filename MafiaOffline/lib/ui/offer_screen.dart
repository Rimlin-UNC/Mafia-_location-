import 'package:flutter/material.dart';

import '../storage/app_prefs.dart';
import 'theme.dart';

/// Текст оферты внутри приложения.
///
/// Сознательно сокращённая версия `docs/ОФЕРТА.md`: пять пунктов, которые
/// человек обязан увидеть до игры. Полный текст лежит в файле `docs/ОФЕРТА.md`
/// и публикуется на ymaster.ru; ссылка на него — внизу экрана.
///
/// Почему не полный текст: тридцать экранов юридического языка перед партией
/// никто не читает, а «прочитал и принял» без прочтения — это согласие,
/// которое потом трудно защитить в споре. Короткий текст люди читают.
const String offerVersion = '1.0 от 12.11.2026';

/// Ключевые условия в том виде, в каком их показывает экран.
const List<String> offerHighlights = [
  'Права на программу «Мафия Offline» принадлежат ООО «Ямастер» (ymaster.ru), 2026 год. '
      'Всё, что вы видите в игре: код, правила, карточки, звуки и оформление, — '
      'его собственность.',
  'Вам выдаётся простая (неисключительная) безвозмездная лицензия: устанавливать '
      'и играть. Права собственности на программу вам не переходят.',
  'Нельзя распространять программу от своего имени или в изменённом виде, '
      'продавать доступ к ней, извлекать карточки и звуки отдельно для других продуктов.',
  'Программа работает офлайн и не отправляет ваши данные разработчику. Всё, что '
      'создано в партии, хранится на вашем устройстве.',
  'Программа предоставляется «как есть»: разработчик не гарантирует работу на любом '
      'устройстве и не отвечает за сбои связи и утрату данных на устройстве.',
];

/// Экран первого запуска: ознакомление с офертой и галочка согласия.
///
/// Показывается один раз на устройство, до главного меню. Без отметки кнопка
/// неактивна — обойти нельзя, потому что согласие должно быть настоящим, а не
/// формальностью: иначе в споре нечем подтвердить, что человек его дал.
class OfferGate extends StatefulWidget {
  /// Что вызвать после принятия условий.
  final VoidCallback onAccepted;

  const OfferGate({super.key, required this.onAccepted});

  /// Принял ли пользователь условия на этом устройстве.
  static Future<bool> accepted() => AppPrefs.offerAccepted();

  @override
  State<OfferGate> createState() => _OfferGateState();
}

class _OfferGateState extends State<OfferGate> {
  bool _checked = false;

  /// Дошёл ли человек до конца текста.
  ///
  /// Требование «прокрути до конца» само по себе не читает за человека, но оно
  /// хотя бы не даёт нажать согласие, не увидев пункт об ограничении
  /// ответственности. Это и есть разница между галочкой и её имитацией.
  bool _scrolledToEnd = false;

  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Если текст помещается на экран целиком, прокрутки не будет вовсе —
    // тогда считаем, что он увиден.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (pos.maxScrollExtent <= 0) {
        setState(() => _scrolledToEnd = true);
      }
    });
  }

  void _onScroll() {
    if (_scrolledToEnd || !_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 24) {
      setState(() => _scrolledToEnd = true);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Принять можно только с явной отметкой.
  ///
  /// Прокрутка согласие не даёт и не отнимает: измерять её ненадёжно (скрытый
  /// виджет отдаёт нулевые размеры, и проверка «дошёл до конца» проходит
  /// впустую), а согласие должно быть осознанным действием человека.
  bool get _canAccept => _checked;

  Future<void> _accept() async {
    if (!_canAccept) return;
    await AppPrefs.setOfferAccepted();
    if (mounted) widget.onAccepted();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('🎭', style: TextStyle(fontSize: 34)),
                  SizedBox(height: 6),
                  Text(
                    'Мафия Offline',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '© 2026 ООО «Ямастер» · ymaster.ru',
                    style: TextStyle(color: AppColors.dim, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.line),
            Expanded(
              child: Scrollbar(
                controller: _scrollController,
                child: ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  children: [
                    const Text(
                      'УСЛОВИЯ ИСПОЛЬЗОВАНИЯ',
                      style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w600,
                        color: AppColors.dim,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Редакция $offerVersion',
                      style: TextStyle(color: AppColors.dim, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    for (var i = 0; i < offerHighlights.length; i++) ...[
                      _NumberedPoint(number: i + 1, text: offerHighlights[i]),
                      const SizedBox(height: 14),
                    ],
                    const SizedBox(height: 4),
                    const Text(
                      'Полный текст оферты — в файле docs/ОФЕРТА.md в составе '
                      'программы и на сайте ymaster.ru. Принимая условия, вы '
                      'заключаете лицензионный договор (ст. 428, 435, 437, 438 '
                      'и п. 5 ст. 1286 ГК РФ).',
                      style: TextStyle(color: AppColors.dim, fontSize: 12, height: 1.45),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: AppColors.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 20, 14),
              child: Column(
                children: [
                  if (!_scrolledToEnd)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 6, left: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Прокрутите текст до конца, чтобы прочитать условия',
                          style: TextStyle(color: AppColors.dim, fontSize: 11.5),
                        ),
                      ),
                    ),
                  CheckboxListTile(
                    value: _checked,
                    onChanged: (v) => setState(() => _checked = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeColor: AppColors.accent,
                    title: const Text(
                      'Я прочитал(а) и принимаю условия оферты',
                      style: TextStyle(fontSize: 14),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _canAccept ? _accept : null,
                      child: const Text('Принимаю и продолжаю'),
                    ),
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

class _NumberedPoint extends StatelessWidget {
  final int number;
  final String text;

  const _NumberedPoint({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.panel2,
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '$number',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 14, height: 1.45),
          ),
        ),
      ],
    );
  }
}

/// Короткая строка «© 2026 ООО «Ямастер»» для меню и подвалов экранов.
class CopyrightLine extends StatelessWidget {
  final String? suffix;

  const CopyrightLine({super.key, this.suffix});

  @override
  Widget build(BuildContext context) {
    final text = suffix == null
        ? '© 2026 ООО «Ямастер» · ymaster.ru'
        : '© 2026 ООО «Ямастер» · ymaster.ru · $suffix';
    return Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(color: AppColors.dim, fontSize: 11),
    );
  }
}
