import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Иконка приложения (1.10.0): красная плитка с джентльменом.
//
// Зачем тест: иконка — единственный файл, который не проверяется ни одним
// другим способом. `flutter analyze` про PNG ничего не знает, APK соберётся
// с любой картинкой, а битая иконка видна только на телефоне. Здесь
// проверяется то, на чём ломаются чаще всего:
//
//   * адаптивная иконка Android: слои 108dp и XML, который на них ссылается.
//     Если drawable/mipmap названы иначе, сборка упадёт «ресурс не найден».
//   * альфа-канал: iOS и Play Store отклоняют иконку с прозрачностью.
//   * размеры: 48...1024 px, ровно квадрат.
//   * PWA: maskable-иконка отдельным файлом (флаг на обычной не работает).
//
// Разбор PNG сделан вручную по заголовку IHDR: пакет image не тянем, а
// формат в первых 30 байтах простой.
// ---------------------------------------------------------------------------

/// Ширина, высота и наличие альфа-канала из заголовка PNG.
({int width, int height, bool hasAlpha}) pngInfo(String path) {
  final bytes = File(path).readAsBytesSync();
  expect(bytes.length, greaterThan(33), reason: 'файл слишком короткий: $path');
  // 8 байт сигнатуры, дальше IHDR: длина(4) тип(4) data(13)
  expect(String.fromCharCodes(bytes.sublist(12, 16)), 'IHDR',
      reason: 'не PNG: $path');
  int u32(int o) =>
      (bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3];
  final w = u32(16);
  final h = u32(20);
  final colorType = bytes[25]; // 0 grayscale, 2 RGB, 3 palette, 4 GA, 6 RGBA
  return (width: w, height: h, hasAlpha: colorType == 4 || colorType == 6);
}

void main() {
  final root = Directory.current.path;

  group('Иконка Android', () {
    test('все плотности на месте и ровно квадратные', () {
      const sizes = {
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      };
      sizes.forEach((dens, px) {
        for (final name in ['ic_launcher.png', 'ic_launcher_round.png']) {
          final path = '$root/android/app/src/main/res/mipmap-$dens/$name';
          expect(File(path).existsSync(), isTrue, reason: path);
          final info = pngInfo(path);
          expect(info.width, px, reason: '$path: ширина');
          expect(info.height, px, reason: '$path: высота');
        }
      });
    });

    test('слои адаптивной иконки — 108dp по плотностям', () {
      const layers = {
        'mdpi': 108,
        'hdpi': 162,
        'xhdpi': 216,
        'xxhdpi': 324,
        'xxxhdpi': 432,
      };
      layers.forEach((dens, px) {
        final bg = '$root/android/app/src/main/res/mipmap-$dens/ic_launcher_bg.png';
        final fg = '$root/android/app/src/main/res/drawable-$dens/ic_launcher_fg.png';
        final mono = '$root/android/app/src/main/res/drawable-$dens/ic_launcher_mono.png';
        for (final path in [bg, fg, mono]) {
          expect(File(path).existsSync(), isTrue, reason: path);
          final info = pngInfo(path);
          expect(info.width, px, reason: '$path: ширина');
          expect(info.height, px, reason: '$path: высота');
        }
        // Фон обязан быть непрозрачным, передний план и монохром — с альфой.
        expect(pngInfo(bg).hasAlpha, isFalse, reason: 'фон не должен иметь альфу');
        expect(pngInfo(fg).hasAlpha, isTrue, reason: 'передний план без альфы');
        expect(pngInfo(mono).hasAlpha, isTrue, reason: 'монохром без альфы');
      });
    });

    test('XML адаптивной иконки ссылается на существующие слои', () {
      final dir = '$root/android/app/src/main/res/mipmap-anydpi-v26';
      for (final name in ['ic_launcher.xml', 'ic_launcher_round.xml']) {
        final path = '$dir/$name';
        expect(File(path).existsSync(), isTrue, reason: path);
        final xml = File(path).readAsStringSync();
        expect(xml.contains('@mipmap/ic_launcher_bg'), isTrue, reason: name);
        expect(xml.contains('@drawable/ic_launcher_fg'), isTrue, reason: name);
        expect(xml.contains('<monochrome'), isTrue,
            reason: '$name: нужен слой для themed icons Android 13+');
      }
    });

    test('манифест объявляет круглую иконку', () {
      final manifest = File(
              '$root/android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest.contains('android:icon="@mipmap/ic_launcher"'), isTrue);
      expect(manifest.contains('android:roundIcon="@mipmap/ic_launcher_round"'),
          isTrue);
    });
  });

  group('Иконка iOS', () {
    test('все размеры набором, без альфа-канала', () {
      const sizes = {
        'Icon-App-20x20@1x.png': 20,
        'Icon-App-20x20@2x.png': 40,
        'Icon-App-20x20@3x.png': 60,
        'Icon-App-29x29@1x.png': 29,
        'Icon-App-29x29@2x.png': 58,
        'Icon-App-29x29@3x.png': 87,
        'Icon-App-40x40@1x.png': 40,
        'Icon-App-40x40@2x.png': 80,
        'Icon-App-40x40@3x.png': 120,
        'Icon-App-60x60@2x.png': 120,
        'Icon-App-60x60@3x.png': 180,
        'Icon-App-76x76@1x.png': 76,
        'Icon-App-76x76@2x.png': 152,
        'Icon-App-83.5x83.5@2x.png': 167,
        'Icon-App-1024x1024@1x.png': 1024,
      };
      final base = '$root/ios/Runner/Assets.xcassets/AppIcon.appiconset';
      sizes.forEach((name, px) {
        final path = '$base/$name';
        expect(File(path).existsSync(), isTrue, reason: path);
        final info = pngInfo(path);
        expect(info.width, px, reason: '$name: ширина');
        expect(info.height, px, reason: '$name: высота');
        // App Store отклоняет иконку с прозрачностью.
        expect(info.hasAlpha, isFalse, reason: '$name: альфа-канал запрещён');
      });
    });
  });

  group('Иконки для браузера (PWA)', () {
    test('192 и 512 на месте', () {
      for (final (name, px) in [('icon-192.png', 192), ('icon-512.png', 512)]) {
        final path = '$root/assets/images/$name';
        expect(File(path).existsSync(), isTrue, reason: path);
        final info = pngInfo(path);
        expect(info.width, px, reason: name);
        expect(info.height, px, reason: name);
      }
    });

    test('maskable — отдельный файл, а не флаг на обычной иконке', () {
      final path = '$root/assets/images/icon-512-maskable.png';
      expect(File(path).existsSync(), isTrue, reason: path);
      final info = pngInfo(path);
      expect(info.width, 512);
      expect(info.height, 512);

      final manifest = File('$root/assets/web/manifest.webmanifest')
          .readAsStringSync();
      expect(manifest.contains('"src": "/images/icon-512-maskable.png"'), isTrue);
      expect(manifest.contains('"purpose": "maskable"'), isTrue);
      // Иконка "any" не должна нести флаг maskable: Android обрежет её сама.
      expect(manifest.contains('"purpose": "any maskable"'), isFalse);
    });

    test('генератор иконки лежит в проекте и воспроизводим', () {
      // Иконка собрана скриптом, а не нарисована руками в редакторе: так
      // все платформы получают один и тот же рисунок и его можно
      // пересобрать после правки.
      final tool = File('$root/tools/make_icon.py');
      expect(tool.existsSync(), isTrue);
      final src = tool.readAsStringSync();
      for (final key in ['render_layer', 'render_mono', 'write_adaptive_xml']) {
        expect(src.contains(key), isTrue, reason: 'в генераторе нет $key');
      }
      // Исходник обязан лежать в репозитории: по нему иконка пересобирается.
      // Без него скрипт воспроизводит что угодно, кроме нужной картинки.
      expect(File('$root/tools/icon_source/мафия-исходник.jpg').existsSync(),
          isTrue, reason: 'нет исходника иконки');
    });
  });
}
