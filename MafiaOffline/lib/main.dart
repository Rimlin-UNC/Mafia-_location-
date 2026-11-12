import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/audio_service.dart';
import 'services/host_background.dart';
import 'ui/menu_screen.dart';
import 'ui/offer_screen.dart';
import 'ui/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AudioService.instance.init();
  // Готовим службу переднего плана: она понадобится ведущему,
  // чтобы партия не рвалась при выключенном экране.
  HostBackground.init();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Принята ли оферта на этом устройстве — решаем ДО показа первого кадра,
  // иначе человек успеет увидеть меню и нажать «Создать игру», а условия
  // так и не примет. Чтение настроек быстрое, задержки не видно.
  final offerOk = await OfferGate.accepted();

  runApp(MafiaApp(offerAccepted: offerOk));
}

class MafiaApp extends StatefulWidget {
  /// Принята ли оферта.
  ///
  /// `true` — меню, `false` — экран условий, `null` (значение по умолчанию) —
  /// меню без проверки. Третий случай нужен для виджет-тестов и для вызова
  /// `MafiaApp()` из кода, который не читал настройки: сам гейт решается
  /// в `main()` до запуска приложения, поэтому в реальной работе значение
  /// всегда известно и `null` не встречается.
  final bool? offerAccepted;

  const MafiaApp({super.key, this.offerAccepted});

  @override
  State<MafiaApp> createState() => _MafiaAppState();
}

class _MafiaAppState extends State<MafiaApp> {
  bool? _accepted;

  @override
  void initState() {
    super.initState();
    _accepted = widget.offerAccepted;
  }

  @override
  Widget build(BuildContext context) {
    // Только явное `false` показывает гейт.
    final needsOffer = _accepted == false;

    return MaterialApp(
      title: 'Мафия Offline',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: needsOffer
          ? OfferGate(onAccepted: () => setState(() => _accepted = true))
          : const MenuScreen(),
    );
  }
}
