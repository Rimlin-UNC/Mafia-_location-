import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/audio_service.dart';
import 'services/host_background.dart';
import 'ui/menu_screen.dart';
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
  runApp(const MafiaApp());
}

class MafiaApp extends StatelessWidget {
  const MafiaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Мафия Offline',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const MenuScreen(),
    );
  }
}
