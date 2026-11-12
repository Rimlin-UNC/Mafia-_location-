import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/core/assets.dart';
import 'package:mafia_offline/core/crime_deck.dart';
import 'package:mafia_offline/core/role_guide.dart';
import 'package:mafia_offline/models/role.dart';
import 'package:mafia_offline/net/web_assets.dart';

// ---------------------------------------------------------------------------
// Что браузер игрока получает по HTTP.
//
// С 1.8.0 игрок в браузере читает ту же книгу правил, что ведущий в
// приложении: роли с карточками, фазы, способы убийства. Значит сервер
// обязан отдавать и сами карточки — иначе раздел «Роли» окажется текстом
// без картинок, и никто этого не заметит до живой партии.
//
// Здесь проверяется разбор путей (WebAssets.resolve) и полнота данных, из
// которых собирается книга правил. Раздача по HTTP — в tools/serve_test.py,
// вид шторки в браузере — в tools/web_smoke.js.
// ---------------------------------------------------------------------------

/// Путь в бандле → URL, по которому его просит браузер.
String urlOf(String asset) => asset.replaceFirst('assets/', '/');

void main() {
  group('Раздача карточек правил для браузера', () {
    test('карточка роли отдаётся облегчённой копией 560x840', () {
      expect(WebAssets.resolve('/instructions/roles/01_mafia.jpg'),
          'assets/instructions/web/roles/01_mafia.jpg');
      expect(WebAssets.resolve('/instructions/phases/02_day.jpg'),
          'assets/instructions/web/phases/02_day.jpg');
      expect(WebAssets.resolve('/instructions/guides/01_host.jpg'),
          'assets/instructions/web/guides/01_host.jpg');
    });

    test('способ убийства тоже из облегчённой копии', () {
      expect(WebAssets.resolve('/crimes/07_knife.jpg'),
          'assets/crimes/web/07_knife.jpg');
    });

    test('карты ролей в самой игре не сломались', () {
      expect(WebAssets.resolve('/cards/mafia.jpg'), 'assets/cards/web/mafia.jpg');
    });

    test('выход за пределы каталога закрыт', () {
      expect(WebAssets.resolve('/instructions/../lib/main.dart'), isNull);
      expect(WebAssets.resolve('/instructions/web/../01_host.jpg'), isNull);
      expect(WebAssets.resolve('/crimes/..%2f..%2fpubspec.yaml'), isNull);
    });

    test('папка без имени файла не открывается', () {
      expect(WebAssets.resolve('/instructions/'), isNull);
      expect(WebAssets.resolve('/instructions/roles/'), isNull);
    });

    test('версия набора ассетов поднята — иначе браузер отдаст старый кеш',
        () {
      // Версия входит в ETag и в адрес app.js. Если она не изменилась,
      // сервис-воркер покажет игроку прошлую (короткую) книгу правил.
      expect(WebAssets.assetVersion, 'v13');
    });
  });

  group('Данные книги правил полны', () {
    test('у каждой роли есть памятка: ночью, днём, победа, советы', () {
      for (final type in RoleType.values) {
        final g = RoleGuide.of(type);
        expect(g.atNight.trim(), isNotEmpty, reason: '${type.name}: ночью');
        expect(g.atDay.trim(), isNotEmpty, reason: '${type.name}: днём');
        expect(g.winCondition.trim(), isNotEmpty, reason: '${type.name}: победа');
        expect(g.tips, isNotEmpty, reason: '${type.name}: советы');
      }
    });

    test('карточка каждой роли отдаётся браузеру', () {
      for (final type in RoleType.values) {
        final url = urlOf(A.guideRole(type));
        expect(WebAssets.resolve(url), isNotNull, reason: url);
      }
    });

    test('карточка каждой фазы отдаётся браузеру', () {
      for (final asset in [
        A.guideHost,
        A.guideNight,
        A.guideDay,
        A.guideVote,
        A.guideWin,
      ]) {
        final url = urlOf(asset);
        expect(WebAssets.resolve(url), isNotNull, reason: url);
      }
    });

    // -----------------------------------------------------------------
    // Ошибка 1.8.0: файлы лежали в подпапках assets/instructions/web/, а в
    // pubspec.yaml был объявлен только сам .../web/. Flutter включает каталог
    // с завершающим слэшем БЕЗ подпапок, поэтому в APK картинок не было:
    // сервер отдавал редирект на главную вместо JPEG, и игрок в браузере
    // видел пустые прямоугольники. Эти тесты проверяют именно упаковку.
    // -----------------------------------------------------------------
    test('каждая картинка правил объявлена в pubspec.yaml', () {
      // flutter test запускает тесты из корня пакета (там, где pubspec.yaml).
      final root = Directory.current;
      final pubspec =
          File('${root.path}/pubspec.yaml').readAsStringSync();
      final declared = RegExp(r'^\s*-\s*(assets/[^\s#]+)', multiLine: true)
          .allMatches(pubspec)
          .map((m) => m.group(1)!)
          .toList();

      // Каталог с завершающим слэшем содержит только файлы внутри него.
      bool covered(String file) => declared.any((d) {
            if (!d.endsWith('/')) return d == file;
            return file.startsWith(d) && !file.substring(d.length).contains('/');
          });

      final urls = <String>[
        for (final t in RoleType.values) urlOf(A.guideRole(t)),
        urlOf(A.guideHost),
        urlOf(A.guideNight),
        urlOf(A.guideDay),
        urlOf(A.guideVote),
        urlOf(A.guideWin),
        for (final c in Crime.all) urlOf(c.image!),
      ];
      expect(urls.length, greaterThanOrEqualTo(20));

      for (final url in urls) {
        final bundle = WebAssets.resolve(url);
        expect(bundle, isNotNull, reason: url);
        expect(File('${root.path}/$bundle').existsSync(), isTrue,
            reason: 'нет файла на диске: $bundle');
        expect(covered(bundle!), isTrue,
            reason: 'файл не попадёт в APK — каталог не объявлен: $bundle');
      }
    });

    test('объявлены все подпапки веб-копий инструкций', () {
      final pubspec = File('${Directory.current.path}/pubspec.yaml').readAsStringSync();
      for (final dir in [
        'assets/instructions/web/roles/',
        'assets/instructions/web/phases/',
        'assets/instructions/web/guides/',
      ]) {
        expect(pubspec.contains('- $dir'), isTrue, reason: dir);
      }
    });

    // Самый прямой тест на ошибку 1.8.0: файл лежит на диске, объявление
    // в pubspec.yaml есть — но подпапка не объявлена, и rootBundle (то, из
    // чего реально читает сервер) файла не находит. В 1.8.0 этот тест
    // падал на 12 карточках из 22.
    testWidgets('сервер может прочитать каждую картинку из бандла',
        (tester) async {
      final urls = <String>[
        for (final t in RoleType.values) urlOf(A.guideRole(t)),
        urlOf(A.guideHost),
        urlOf(A.guideNight),
        for (final c in Crime.all) urlOf(c.image!),
      ];
      final broken = <String>[];
      for (final url in urls) {
        final bundle = WebAssets.resolve(url);
        expect(bundle, isNotNull, reason: url);
        try {
          final data = await rootBundle.load(bundle!);
          if (data.lengthInBytes < 1000) broken.add('$bundle — пустой файл');
        } catch (e) {
          broken.add('$bundle — не в бандле');
        }
      }
      expect(broken, isEmpty,
          reason: 'эти картинки не попадут в APK (не объявлен каталог '
              'в pubspec.yaml): ${broken.join(', ')}');
    });

    test('у каждого способа убийства есть название, фраза и картинка', () {
      expect(Crime.all.length, 10);
      for (final c in Crime.all) {
        expect(c.name.trim(), isNotEmpty);
        expect(c.phrase.trim(), isNotEmpty);
        expect(c.image, isNotNull, reason: c.name);
        final url = urlOf(c.image!);
        expect(WebAssets.resolve(url), isNotNull, reason: url);
      }
    });
  });
}
