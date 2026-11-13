import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// Раздача веб-клиента по HTTP.
///
/// Файлы лежат в assets приложения и грузятся из бандла в память при первом
/// обращении. Отдельный веб-сервер (Flask, node) не нужен: HTTP-сервер уже
/// поднят внутри приложения на `dart:io`, мы лишь добавляем ему статику.
///
/// Благодаря этому в игру можно зайти с любого устройства — iPhone, планшета,
/// ноутбука — просто открыв ссылку в браузере. Установка не требуется.
///
/// ## Почему это устроено именно так
///
/// Телефон ведущего одновременно раздаёт Wi-Fi, держит 20 WebSocket-соединений
/// и отдаёт статику. Самое узкое место — оперативная память и канал точки
/// доступа. Отсюда три решения:
///
/// 1. **Кеш с потолком.** Держим в памяти только то, что просят часто, и не
///    больше [_maxCacheBytes]. Фоновый луп ночи весит 1,3 МБ — три таких лупа
///    плюс восемь карт ролей уже 4,5 МБ постоянно занятой памяти на телефоне,
///    который и так на грани.
/// 2. **Сжатие текста.** HTML+CSS+JS весят 42 КБ, в gzip — 12 КБ. При 20
///    игроках это разница между 840 КБ и 240 КБ на раздачу страницы. Жмём один
///    раз и держим сжатый результат — он маленький.
/// 3. **ETag и 304.** Игрок, который свернул браузер и вернулся, не тянет
///    заново мегабайты звука: сервер отвечает «не изменилось». Это же спасает
///    при перезагрузке страницы, которую люди делают инстинктивно при любом
///    сбое.
class WebAssets {
  WebAssets._();

  /// Кеш распакованных файлов: путь в бандле → байты.
  static final Map<String, Uint8List> _cache = {};

  /// Кеш gzip-версий для текстовых файлов.
  static final Map<String, Uint8List> _gzipCache = {};

  /// Порядок обращений — для вытеснения самого давнего при переполнении.
  static final List<String> _lru = [];

  static int _cacheBytes = 0;

  /// Потолок кеша. 6 МБ подобраны так, чтобы поместились все карты ролей,
  /// фоны и мелкие звуки, но не все три фоновых лупа разом.
  static const int _maxCacheBytes = 6 * 1024 * 1024;

  /// Соответствие URL → файл в бандле.
  static const Map<String, String> _routes = {
    '/': 'assets/web/index.html',
    '/index.html': 'assets/web/index.html',
    '/style.css': 'assets/web/style.css',
    '/app.js': 'assets/web/app.js',
    '/manifest.webmanifest': 'assets/web/manifest.webmanifest',
    '/sw.js': 'assets/web/sw.js',
  };

  /// Каталоги, которые отдаём целиком (карты ролей и звуки).
  static const Map<String, String> _dirs = {
    '/cards/': 'assets/cards/',
    '/sounds/': 'assets/sounds/',
    '/images/': 'assets/images/',
    // Сюжетные карточки и кадры суда: игроки видят их в браузере,
    // поэтому папки обязаны отдаваться тем же путём, что в приложении.
    '/crimes/': 'assets/crimes/',
    '/court/': 'assets/court/',
    '/story/': 'assets/story/',
    // Карточки-инструкции: с 1.8.0 браузер показывает ту же книгу правил,
    // что приложение на экране «Правила» — роли, фазы, ведущий.
    '/instructions/': 'assets/instructions/',
  };

  /// Каталоги, отдаваемые из облегчённой копии (`assets/<dir>/web/`).
  /// Для картинок это версии 560×840: на экране телефона разницы нет,
  /// а трафик через точку доступа ведущего меньше вчетверо.
  static const Map<String, String> _webDirs = {
    '/cards/': 'assets/cards/web/',
    '/instructions/': 'assets/instructions/web/',
    '/crimes/': 'assets/crimes/web/',
  };

  /// Версия набора ассетов. Входит в ETag: подняли версию приложения —
  /// у всех игроков автоматически обновится кеш браузера.
  static const String assetVersion = 'v14';

  static String contentTypeFor(String path) {
    if (path.endsWith('.html') || path == '/') return 'text/html; charset=utf-8';
    if (path.endsWith('.css')) return 'text/css; charset=utf-8';
    if (path.endsWith('.js')) return 'application/javascript; charset=utf-8';
    if (path.endsWith('.webmanifest')) return 'application/manifest+json';
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.svg')) return 'image/svg+xml';
    if (path.endsWith('.ogg')) return 'audio/ogg';
    if (path.endsWith('.wav')) return 'audio/wav';
    if (path.endsWith('.ico')) return 'image/x-icon';
    return 'application/octet-stream';
  }

  /// Стоит ли сжимать этот тип. Картинки и звуки уже сжаты — повторный
  /// gzip только сожжёт процессор и даст пару процентов.
  static bool isCompressible(String path) =>
      path == '/' ||
      path.endsWith('.html') ||
      path.endsWith('.css') ||
      path.endsWith('.js') ||
      path.endsWith('.webmanifest');

  /// Фоновые лупы, для которых есть облегчённая версия под браузер.
  ///
  /// Оригиналы (22 кГц, 20-30 с) весят 3,3 МБ на троих. При 20 игроках это
  /// 66 МБ, которые телефон ведущего должен прокачать через свою точку
  /// доступа — на слабом Wi-Fi фон догружается к середине партии.
  /// Версии из `sounds/web/` весят 1,1 МБ: 16 кГц и 12 секунд с кроссфейдом
  /// на стыке петли. На телефонном динамике разница не слышна, а трафик
  /// втрое меньше. Нативное приложение продолжает играть оригиналы —
  /// там файлы лежат локально и их размер не имеет значения.
  static const Set<String> _lightweightAmbients = {
    'night_ambient.wav',
    'day_ambient.wav',
    'vote_ambient.wav',
  };

  /// Путь в бандле для запрошенного URL или null, если такого нет.
  static String? resolve(String path) {
    final normalized = path.isEmpty ? '/' : path;

    // Защита от выхода за пределы каталога ассетов.
    if (normalized.contains('..')) return null;

    final direct = _routes[normalized];
    if (direct != null) return direct;

    for (final entry in _dirs.entries) {
      if (normalized.startsWith(entry.key)) {
        final name = normalized.substring(entry.key.length);
        if (name.isEmpty) return null;

        if (entry.key == '/sounds/' && _lightweightAmbients.contains(name)) {
          return 'assets/sounds/web/$name';
        }
        // Облегчённые копии: карты ролей, карточки инструкций, злодеяния.
        // Для них допустима вложенность (instructions/roles/01_mafia.jpg),
        // но выход за пределы каталога по-прежнему запрещён.
        final light = _webDirs[entry.key];
        if (light != null && name.endsWith('.jpg')) {
          if (name.contains('..')) return null;
          return '$light$name';
        }
        if (name.contains('/')) return null;
        return '${entry.value}$name';
      }
    }
    return null;
  }

  /// Содержимое файла для запрошенного пути или null, если такого нет.
  ///
  /// [gameCode] подставляется в index.html, чтобы игроку не пришлось
  /// вводить код вручную — он уже перешёл по правильной ссылке.
  static Future<Uint8List?> load(String path, {String? gameCode}) async {
    final asset = resolve(path);
    if (asset == null) return null;
    if (asset.endsWith('.html')) return _html(asset, gameCode);
    return _fromCacheOrBundle(asset);
  }

  /// gzip-версия текстового файла. Возвращает null, если сжимать нечего
  /// или результат оказался не меньше оригинала.
  static Future<Uint8List?> loadGzipped(String path, {String? gameCode}) async {
    if (!isCompressible(path)) return null;

    final asset = resolve(path);
    if (asset == null) return null;

    // HTML содержит код партии, поэтому кешируется отдельно по коду:
    // иначе игрок второй партии получил бы чужой код из кеша.
    final key = asset.endsWith('.html') ? '$asset#${gameCode ?? ''}' : asset;
    final cached = _gzipCache[key];
    if (cached != null) return cached;

    final raw = await load(path, gameCode: gameCode);
    if (raw == null) return null;

    final packed = Uint8List.fromList(gzip.encode(raw));
    if (packed.length >= raw.length) return null;

    // Сжатых текстов немного (5 файлов), место они занимают копеечное —
    // держим без вытеснения, но подчищаем при смене партии.
    if (_gzipCache.length > 24) _gzipCache.clear();
    _gzipCache[key] = packed;
    return packed;
  }

  /// Метка версии файла для ETag. Пока ассеты неизменны внутри сборки,
  /// достаточно версии набора и размера — этого хватает, чтобы браузер
  /// отличил обновление от «того же самого».
  static String etagFor(String path, int length) =>
      '"$assetVersion-${length.toRadixString(16)}"';

  /// HTML отдаём с внедрённым кодом партии.
  static Future<Uint8List?> _html(String asset, String? code) async {
    try {
      var text = await rootBundle.loadString(asset);
      final boot = jsonEncode({
        'code': code ?? '',
        'v': assetVersion,
      });
      text = text.replaceFirst(
        '<script src="/app.js"></script>',
        '<script>window.__MAFIA__=$boot;</script>\n'
        '<script src="/app.js?$assetVersion"></script>',
      );
      return Uint8List.fromList(utf8.encode(text));
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _fromCacheOrBundle(String asset) async {
    final cached = _cache[asset];
    if (cached != null) {
      _touch(asset);
      return cached;
    }
    try {
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      _put(asset, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static void _touch(String asset) {
    _lru.remove(asset);
    _lru.add(asset);
  }

  /// Кладём в кеш, вытесняя давние записи, пока не влезем в потолок.
  static void _put(String asset, Uint8List bytes) {
    // Файл крупнее половины потолка кешировать бессмысленно: он вытеснит
    // всё остальное и сам же будет вытеснен следующим таким.
    if (bytes.length > _maxCacheBytes ~/ 2) return;

    while (_cacheBytes + bytes.length > _maxCacheBytes && _lru.isNotEmpty) {
      final victim = _lru.removeAt(0);
      final removed = _cache.remove(victim);
      if (removed != null) _cacheBytes -= removed.length;
    }
    _cache[asset] = bytes;
    _cacheBytes += bytes.length;
    _lru.add(asset);
  }

  /// Сброс кеша (например, при нехватке памяти или смене партии).
  static void clearCache() {
    _cache.clear();
    _gzipCache.clear();
    _lru.clear();
    _cacheBytes = 0;
  }

  /// Сброс только HTML-кеша — при старте новой партии код меняется.
  static void invalidateHtml() {
    _gzipCache.removeWhere((k, _) => k.contains('.html'));
  }

  /// Сколько памяти занято кешем — для диагностики на экране ведущего.
  static int get cacheBytes => _cacheBytes;
}
