import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../storage/wifi_store.dart';
import '../theme.dart';
import '../widgets.dart';

/// Настройка Wi-Fi для QR-кода подключения.
///
/// Смысл экрана: ведущий один раз вводит имя сети и пароль, а дальше
/// каждый игрок просто наводит камеру и попадает в сеть — не нужно
/// диктовать пароль вслух двадцати людям и исправлять опечатки.
class WifiSetupScreen extends StatefulWidget {
  const WifiSetupScreen({super.key});

  @override
  State<WifiSetupScreen> createState() => _WifiSetupScreenState();
}

class _WifiSetupScreenState extends State<WifiSetupScreen> {
  final _store = WifiStore();
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  WifiSecurity _security = WifiSecurity.wpa;
  bool _hidden = false;
  bool _enabled = true;
  bool _showPass = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await _store.load();
    final on = await _store.isEnabled();
    if (!mounted) return;
    setState(() {
      _ssidCtrl.text = cfg.ssid;
      _passCtrl.text = cfg.password;
      _security = cfg.security;
      _hidden = cfg.hidden;
      _enabled = on;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  WifiConfig get _config => WifiConfig(
        ssid: _ssidCtrl.text.trim(),
        password: _passCtrl.text,
        security: _security,
        hidden: _hidden,
      );

  Future<void> _save() async {
    await _store.save(_config);
    await _store.setEnabled(_enabled);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _config;

    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi для игроков')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const InfoCard(
                    icon: Icons.qr_code_2,
                    text: 'Игрок наводит камеру на первый код и телефон сам '
                        'подключается к вашей сети. Пароль диктовать не нужно.',
                    color: AppColors.accent2,
                  ),

                  SwitchListTile(
                    value: _enabled,
                    onChanged: (v) => setState(() => _enabled = v),
                    title: const Text('Показывать код подключения к Wi-Fi'),
                    subtitle: const Text(
                      'Выключите, если все и так в одной сети',
                      style: TextStyle(fontSize: 12, color: AppColors.dim),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),

                  if (_enabled) ...[
                    const SizedBox(height: 8),
                    const Text('Имя сети (SSID)',
                        style: TextStyle(fontSize: 12.5, color: AppColors.dim)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _ssidCtrl,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'Например: Mafia-Host',
                        prefixIcon: Icon(Icons.wifi, size: 20),
                      ),
                      textCapitalization: TextCapitalization.none,
                      autocorrect: false,
                    ),

                    const SizedBox(height: 14),
                    const Text('Пароль',
                        style: TextStyle(fontSize: 12.5, color: AppColors.dim)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _passCtrl,
                      onChanged: (_) => setState(() {}),
                      obscureText: !_showPass,
                      enabled: _security != WifiSecurity.open,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        hintText: _security == WifiSecurity.open
                            ? 'Сеть без пароля'
                            : 'Пароль точки доступа',
                        prefixIcon: const Icon(Icons.key, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _showPass ? Icons.visibility_off : Icons.visibility,
                            size: 20,
                          ),
                          onPressed: () =>
                              setState(() => _showPass = !_showPass),
                        ),
                      ),
                    ),

                    const SizedBox(height: 14),
                    const Text('Защита',
                        style: TextStyle(fontSize: 12.5, color: AppColors.dim)),
                    const SizedBox(height: 6),
                    SegmentedButton<WifiSecurity>(
                      segments: const [
                        ButtonSegment(
                            value: WifiSecurity.wpa, label: Text('WPA')),
                        ButtonSegment(
                            value: WifiSecurity.wep, label: Text('WEP')),
                        ButtonSegment(
                            value: WifiSecurity.open, label: Text('Открытая')),
                      ],
                      selected: {_security},
                      onSelectionChanged: (v) =>
                          setState(() => _security = v.first),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Почти всегда подходит WPA — так работают все современные '
                      'точки доступа Android и iPhone.',
                      style: TextStyle(fontSize: 11.5, color: AppColors.dim),
                    ),

                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: _hidden,
                      onChanged: (v) => setState(() => _hidden = v ?? false),
                      title: const Text('Сеть скрытая',
                          style: TextStyle(fontSize: 14)),
                      subtitle: const Text(
                        'Отметьте, только если сеть не видна в списке',
                        style: TextStyle(fontSize: 11.5, color: AppColors.dim),
                      ),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                    ),

                    const SizedBox(height: 10),

                    // Предпросмотр: ведущий сразу видит, что получится,
                    // и может проверить код своим вторым телефоном.
                    if (cfg.isUsable)
                      PanelCard(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Column(
                            children: [
                              const Text('Проверьте код',
                                  style: TextStyle(
                                      fontSize: 12.5, color: AppColors.dim)),
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: QrImageView(
                                  data: cfg.toQrPayload(),
                                  size: 150,
                                  backgroundColor: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                cfg.ssid,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      const InfoCard(
                        icon: Icons.info_outline,
                        text: 'Заполните имя сети и пароль — появится '
                            'предпросмотр кода.',
                        color: AppColors.dim,
                      ),

                    const SizedBox(height: 10),
                    const InfoCard(
                      icon: Icons.lightbulb_outline,
                      text: 'Где взять данные: Настройки → Точка доступа. '
                          'Там же можно задать простое имя и пароль — '
                          'их проще ввести вручную, если камера подведёт.',
                      color: AppColors.warn,
                    ),
                  ],

                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Сохранить'),
                    onPressed: _save,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Скопировать пароль'),
                    onPressed: _passCtrl.text.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(
                                ClipboardData(text: _passCtrl.text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Пароль скопирован'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }
}
