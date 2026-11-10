# Сборка для iPhone

IPA-файл **невозможно** собрать здесь: Apple разрешает компиляцию под iOS только на macOS с Xcode. Это ограничение Apple, а не проекта.

iOS-проект уже полностью подготовлен: `ios/Runner.xcodeproj` создан, в `Info.plist` прописаны разрешение на локальную сеть, Bonjour и фоновое аудио — без них игра на iPhone не найдёт ведущего.

## Вариант 1 — на Mac (15 минут)

```bash
# (вы уже в папке MafiaOffline — корне проекта)
flutter pub get
open ios/Runner.xcworkspace
```

В Xcode: выберите Runner → Signing & Capabilities → поставьте свой Apple ID в Team. Подключите iPhone кабелем, нажмите ▶.

Бесплатный Apple ID работает: приложение живёт 7 дней, потом нужно переустановить. Платный аккаунт разработчика ($99/год) снимает ограничение.

## Вариант 2 — без Mac, через облачную сборку

**Codemagic** (500 бесплатных минут в месяц) — залейте проект в GitHub и подключите репозиторий. Готовый конфиг:

```yaml
# codemagic.yaml — положите в корень проекта
workflows:
  ios:
    name: iOS build
    instance_type: mac_mini_m2
    environment:
      flutter: 3.24.5
      xcode: latest
    scripts:
      - flutter pub get
      - flutter build ios --release --no-codesign
    artifacts:
      - build/ios/iphoneos/*.app
```

Для установки на устройство всё равно понадобится сертификат Apple — его можно сгенерировать в том же Codemagic, привязав Apple ID.

## Вариант 3 — только протестировать логику

Игра работает и когда **ведущий на Android, а игроки тоже на Android**. iPhone нужен, только если вы хотите играть с iOS-устройств. Для проверки всей механики достаточно нескольких Android-телефонов.
