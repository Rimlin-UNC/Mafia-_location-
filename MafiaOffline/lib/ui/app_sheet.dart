import 'package:flutter/material.dart';

import 'theme.dart';

/// Нижняя шторка, которая всегда помещается на экран.
///
/// Почему отдельный виджет. `showModalBottomSheet` по умолчанию отдаёт
/// ребёнку высоту «по содержимому», но не больше 9/16 экрана, и **не даёт
/// прокрутки**. Длинная шторка обрезается снизу: на скриншоте с телефона
/// 2026 г. так пропала последняя настройка — её не было видно и до неё
/// нельзя было доскроллить.
///
/// Здесь три вещи, которых не хватает «голому» showModalBottomSheet:
///
///  * `isScrollControlled` — шторка может занять почти весь экран, а не
///    9/16 (на 720 px это было ~405 px из 700 доступных);
///  * прокрутка содержимого, когда оно выше экрана;
///  * `useSafeArea` — шторка не уходит под верхнюю строку статуса и
///    вырез камеры.
///
/// Низ шторки useSafeArea НЕ закрывает (в Flutter 3.24 это
/// `SafeArea(bottom: false, ...)`) — системная полоска снизу остаётся
/// на совести содержимого: см. `SafeArea` вокруг нижней кнопки.
///
/// Вызов заменяет `showModalBottomSheet(...)` один в один:
///
/// ```dart
/// await showAppSheet(context, builder: (ctx) => ...);
/// ```
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isDismissible = true,
  bool enableDrag = true,
  // true — рисовать ручку сверху. Для DraggableScrollableSheet передавайте
  // false: он рисует свою ручку внутри содержимого.
  bool showHandle = true,
  Color? backgroundColor,
  // 1.0 — для DraggableScrollableSheet: он сам задаёт размер в долях
  // экрана (0.7–0.95) и ждёт свободной высоты, чтобы прокрутка работала.
  // 0.92 — обычная шторка: остаётся полоска меню сверху как ориентир.
  double? maxHeightFactor = 0.92,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    backgroundColor: backgroundColor ?? AppColors.panel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheetContext) {
      final media = MediaQuery.of(sheetContext);
      final content = builder(sheetContext);
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: media.size.height * (maxHeightFactor ?? 0.92),
        ),
        child: showHandle
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(top: 10, bottom: 2),
                    decoration: BoxDecoration(
                      color: AppColors.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Flexible(child: content),
                ],
              )
            : content,
      );
    },
  );
}

/// Содержимое шторки: заголовок, прокручиваемая середина, нижняя кнопка.
///
/// Нижняя кнопка вынесена из прокрутки намеренно: «Закрыть» должно быть
/// видно сразу, а не после прокрутки до конца.
class SheetBody extends StatelessWidget {
  final String? title;
  final Widget? subtitle;
  final List<Widget> children;
  final Widget? bottom;

  /// Поля прокручиваемой середины. По умолчанию те же, что были в шторке
  /// настроек, — чтобы содержимое не сдвинулось.
  final EdgeInsetsGeometry padding;

  const SheetBody({
    super.key,
    this.title,
    this.subtitle,
    required this.children,
    this.bottom,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 12),
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 6),
        if (title != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              title!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: subtitle,
          ),
        const SizedBox(height: 6),
        Flexible(
          child: SingleChildScrollView(
            padding: padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
        if (bottom != null)
          // useSafeArea у шторки закрывает верх, левый и правый край, но НЕ
          // низ: там система рисует жестовую полоску (проверено по исходникам
          // Flutter 3.24: `SafeArea(bottom: false, child: content)`).
          // Поэтому кнопка «Закрыть» получает свой SafeArea — иначе на
          // телефоне с жестовой навигацией её нижний край срезается.
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: SizedBox(width: double.infinity, child: bottom),
            ),
          )
        else
          const SizedBox(height: 8),
      ],
    );
  }
}
