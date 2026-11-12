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
      expect(WebAssets.assetVersion, 'v9');
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
