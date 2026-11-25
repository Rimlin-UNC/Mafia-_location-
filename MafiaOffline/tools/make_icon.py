#!/usr/bin/env python3
"""Иконка «Мафия Offline» 1.12.2: джентльмен с револьвером на алом диске.

Откуда картинка
---------------
Владелец прислал новую иконку: джентльмен в шляпе-федоре с револьвером,
алый диск на чёрном фоне, по углам — тонкие светлые диагональные линии.

Что сделано с исходником
-----------------------
1. **Диск вырезан из чёрного фона.** Раньше иконка была плиткой на
   прозрачном фоне; здесь содержимое — сам диск. Чёрный квадрат вокруг
   него на тёмном лончере сливается с фоном, а на светлом (iOS, PWA)
   торчит углами. Поэтому: всё, что вне диска и не линия, становится
   прозрачным, кромка диска сглаживается по альфе.
2. **Диагональные линии убраны.** Это декоративная сетка исходника; на
   48 px она превращается в грязь по углам, а на круглой маске Android
   вообще вылетает за пределы иконки. На их месте — прозрачность.
3. **Чёрный фон подложен только там, где платформа не принимает альфу**
   (iOS, Play Market, `ic_launcher.png` для старых лончеров).

Запасной вариант
----------------
Прежняя иконка (красная плитка с силуэтом в цилиндре) не удалена:
её генератор — `tools/make_icon_tile.py`, исходник —
`tools/icon_source/мафия-исходник.jpg`. Если новая не понравится в
деле, вернуться можно одной командой:

    python3 tools/make_icon_tile.py --all

Что на выходе (все форматы, которые читают платформы)
-----------------------------------------------------
* Android: `mipmap-*/ic_launcher.png` и `ic_launcher_round.png`
  (48…192 px), слои адаптивной иконки `ic_launcher_bg` / `ic_launcher_fg`
  (108 dp: 108…432 px) и `ic_launcher_mono` для themed icons Android 13+;
* iOS: 15 размеров в `AppIcon.appiconset`, без альфа-канала;
* PWA: `icon-192`, `icon-512`, `icon-512-maskable` (содержимое внутри
  безопасного круга);
* витрина для документации: `docs/иконки/`.

Запуск:
    python3 tools/make_icon.py            # витрина + превью
    python3 tools/make_icon.py --all      # + Android, iOS, PWA
"""
import argparse
import os
import sys

try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover
    print('Нужны Pillow и numpy: pip install pillow numpy')
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Исходник владельца лежит в репозитории: без него иконка невоспроизводима.
SOURCE = os.path.join(ROOT, 'tools', 'icon_source',
                      'джентльмен-с-револьвером.jpg')

# Цвет подложки для платформ без прозрачности: тот же чёрный, что у
# исходника и у фона приложения (AppColors.background ≈ #101014).
FLAT_BG = (16, 16, 20)

# Геометрия диска в координатах исходника (1080×1080).
CX, CY = 540.0, 540.0
DISC_R = 528.0        # внешний край диска вместе с ободком
EDGE_SOFT = 6.0       # ширина сглаживания кромки, px исходника
LINE_MARGIN = 512.0   # ближе к центру, чем это, линии не ищем: там фигура

SS = 2                # суперсэмплинг: считаем вдвое крупнее, уменьшаем в конце


# ---------------------------------------------------------------------------
# Вырезание диска
# ---------------------------------------------------------------------------

def disc_alpha():
    """Альфа-маска диска с учётом ободка.

    Граница диска не резкая: яркий красный кончается на r≈522, дальше
    идёт тёмный ободок и к r≈530 — чёрный фон. Порог по яркости режет
    ободок пополам. Поэтому альфа считается по двум признакам сразу:
    «не чёрный» (яркость) и «внутри радиуса». Мягкая кромка в 6 px
    даёт плавный переход вместо ступеньки на 192 px.
    """
    a = np.asarray(Image.open(SOURCE).convert('RGB')).astype(float)
    h, w, _ = a.shape
    lum = 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]

    yy, xx = np.mgrid[0:h, 0:w]
    # Учитываем, что снимок может быть не ровно 1080×1080.
    sx, sy = w / 1080.0, h / 1080.0
    d = np.sqrt(((xx / sx) - CX) ** 2 + ((yy / sy) - CY) ** 2)

    inside = np.clip((DISC_R - d) / EDGE_SOFT + 0.5, 0.0, 1.0)
    # Порог яркости 10…26: ниже — чёрный фон, выше — ободок и диск.
    opaque = np.clip((lum - 10.0) / 16.0, 0.0, 1.0)
    alpha = np.maximum(inside * opaque, inside * 0.0)
    # Внутри диска альфа обязана быть полной, даже если там чёрный цвет
    # (костюм, шляпа): иначе фигура станет дыркой в иконке.
    alpha = np.where(d < DISC_R - EDGE_SOFT, 1.0, alpha)
    return Image.fromarray((alpha * 255).astype('uint8'), 'L')


def line_mask():
    """Маска диагональных линий исходника — их надо стереть.

    Линия — это пиксель, который локально ярче окружения и при этом почти
    серый (R≈G≈B). Костюм и шляпа тоже серые, но они большие: размытие
    с радиусом 6 px «съедает» линию (толщина 1–2 px) и не трогает фигуру.
    Ищем только снаружи диска: внутри линий нет, а тёмные штрихи на
    диске трогать нельзя.
    """
    a = np.asarray(Image.open(SOURCE).convert('RGB')).astype(float)
    h, w, _ = a.shape
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    blur = np.asarray(
        Image.fromarray(lum.astype('uint8'), 'L').filter(
            ImageFilter.GaussianBlur(6))).astype(float)

    yy, xx = np.mgrid[0:h, 0:w]
    sx, sy = w / 1080.0, h / 1080.0
    d = np.sqrt(((xx / sx) - CX) ** 2 + ((yy / sy) - CY) ** 2)

    grayish = (np.abs(r - g) < 45) & (np.abs(g - b) < 45)
    lines = ((lum > 30) & ((lum - blur) > 8) & grayish &
             (d > LINE_MARGIN) & (d < DISC_R + 2))
    return Image.fromarray((lines * 255).astype('uint8'), 'L').filter(
        ImageFilter.MaxFilter(3))


# ---------------------------------------------------------------------------
# Сборка
# ---------------------------------------------------------------------------

def _square():
    """Исходник, обрезанный до квадрата 1080×1080."""
    im = Image.open(SOURCE).convert('RGB')
    if im.size != (1080, 1080):
        side = min(im.size)
        left = (im.width - side) // 2
        top = (im.height - side) // 2
        im = im.crop((left, top, left + side, top + side))
        im = im.resize((1080, 1080), Image.LANCZOS)
    return im


def render(size, flat_bg=None, scale=1.0):
    """Иконка целиком.

    scale — какую долю холста занимает диск. 1.0 — почти вплотную к краю
    (так иконка читается крупно в списке приложений); для maskable-иконки
    PWA нужен запас, потому что Android обрезает её по кругу.
    flat_bg — если задан, прозрачность заменяется этим цветом.
    """
    S = max(size, 8)
    base = _square()

    alpha = disc_alpha()
    # Стираем линии: сначала расширяем маску, потом гасим альфу.
    lines = line_mask()
    alpha = Image.composite(Image.new('L', alpha.size, 0), alpha, lines)

    rgba = base.convert('RGBA')
    rgba.putalpha(alpha)

    # Диск вписываем в холст с полем: он не должен касаться края, иначе
    # круглая маска лончера срежет ободок.
    target = int(S * scale * 2.0 * DISC_R / 1080.0)
    target = max(4, min(target, S))
    small = rgba.resize((target, target), Image.LANCZOS)
    small = clean_transparent(small)

    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    off = (S - target) // 2
    out.alpha_composite(small, (off, off))
    out = out.resize((size, size), Image.LANCZOS)
    out = clean_transparent(out)

    if flat_bg is not None:
        canvas = Image.new('RGB', (size, size), flat_bg)
        canvas.paste(out, (0, 0), out)
        return canvas
    return out


def clean_transparent(img, eps=4):
    """Обнуляет цвет там, где альфа практически ноль.

    Ланцош после пересчёта из RGBa оставляет у кромки пиксели с альфой 1 и
    цветом 255,255,255: вклад альфы почти нулевой, а цвет остался белым.
    На светлом фоне такой ряд читается как белая кайма по контуру диска.
    """
    a = np.asarray(img).copy()
    a[a[:, :, 3] < eps] = 0
    return Image.fromarray(a, 'RGBA')


def render_layer(kind, size):
    """Слои адаптивной иконки Android (108 dp).

    Android обрезает слой до центральных 66 из 108 dp (безопасная зона —
    72). Диск в переднем плане занимает 66%: целиком внутри безопасной
    зоны, но не мелкий.
    """
    if kind == 'bg':
        # Фон — почти чёрный с лёгким бордовым отсветом снизу: диск с
        # алыми краями не «висит» на плоском чёрном, но и не спорит с ним.
        img = Image.new('RGB', (size, size))
        d = ImageDraw.Draw(img)
        top, bot = (26, 12, 14), (74, 6, 10)
        for y in range(size):
            t = y / max(1, size - 1)
            d.line([(0, y), (size, y)],
                   fill=tuple(int(top[i] + (bot[i] - top[i]) * t)
                              for i in range(3)))
        return img

    # 0.70: диск целиком внутри круга, который рисует лончер (72/108 dp),
    # но занимает его почти целиком — на 0,66 иконка выглядела мелкой.
    small = max(8, int(size * 0.70))
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    layer.alpha_composite(render(small).resize((small, small), Image.LANCZOS),
                          ((size - small) // 2, (size - small) // 2))
    return layer


def render_mono(size):
    """Монохромный слой для themed icons Android 13+.

    Система сама рисует подложку своего цвета, поэтому нужен только
    силуэт. Берём всё, что темнее ободка внутри диска: шляпа, костюм,
    пистолет читаются, а красный фон — нет.
    """
    S = max(size * SS, 16)
    base = _square().resize((S, S), Image.LANCZOS)
    a = np.asarray(base).astype(float)
    lum = 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]

    yy, xx = np.mgrid[0:S, 0:S]
    d = np.sqrt((xx - S / 2.0) ** 2 + (yy - S / 2.0) ** 2)

    # «Тёмное» — это серое и чёрное, а НЕ красное. У алого диска
    # яркость тоже низкая (200,20,20 даёт ~74), поэтому по одной
    # яркости в маску попадал весь фон и монохром получался
    # вывернутым: белый круг с тёмной фигурой. Отсекаем красное по
    # разнице каналов: у костюма и шляпы R≈G≈B, у диска R≫G.
    r_ch, g_ch = a[:, :, 0], a[:, :, 1]
    grayish = (r_ch - g_ch) < 55
    # Нижние 20% обрезаем: там у исходника декоративные театральные
    # маски, и в монохроме они превращаются в бессмысленные дуги под
    # фигурой. Портрет с револьвером и так узнаётся.
    dark = (lum < 105) & grayish & (d < S * 0.5 * 0.92) & (yy < S * 0.80)
    mask = Image.fromarray((dark * 255).astype('uint8'), 'L').filter(
        ImageFilter.GaussianBlur(max(0.4, S * 0.002)))

    layer = Image.new('RGBA', (S, S), (255, 255, 255, 0))
    layer.putalpha(mask)
    return layer.resize((size, size), Image.LANCZOS)


def preview(path):
    """Витрина: прозрачный край на тёмном и светлом фоне + мелкие размеры."""
    sizes = (192, 128, 96, 72, 48, 32)
    gap = 16
    left_w = 2 * 240 + 3 * gap
    row_w = sum(sizes) + gap * (len(sizes) - 1)
    W = max(left_w, row_w) + 2 * gap
    row_h = max(sizes)
    H = 240 + row_h * 2 + 4 * gap

    sh = Image.new('RGB', (W, H), (24, 26, 33))
    d = ImageDraw.Draw(sh)
    d.rectangle([0, 0, W // 2 - 2, 240 + gap], fill=(28, 30, 38))
    d.rectangle([W // 2 + 2, 0, W, 240 + gap], fill=(236, 236, 240))

    sh.paste(render(240), (gap, gap), render(240))
    light = render(240)
    sh.paste(light, (W // 2 + gap, gap), light)

    for row, (bg, y0) in enumerate(((None, 240 + 2 * gap),
                                    ((236, 236, 240),
                                     240 + 3 * gap + row_h))):
        x = gap
        for px in sizes:
            img = render(px, flat_bg=bg)
            if img.mode == 'RGBA':
                sh.paste(img, (x, y0 + (row_h - px) // 2), img)
            else:
                sh.paste(img, (x, y0 + (row_h - px) // 2))
            x += px + gap
    sh.save(path)


# ---------------------------------------------------------------------------
# Запись по платформам
# ---------------------------------------------------------------------------

def ios_sizes():
    return {
        'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40,
        'Icon-App-20x20@3x.png': 60, 'Icon-App-29x29@1x.png': 29,
        'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
        'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80,
        'Icon-App-40x40@3x.png': 120, 'Icon-App-60x60@2x.png': 120,
        'Icon-App-60x60@3x.png': 180, 'Icon-App-76x76@1x.png': 76,
        'Icon-App-76x76@2x.png': 152, 'Icon-App-83.5x83.5@2x.png': 167,
        'Icon-App-1024x1024@1x.png': 1024,
    }


def write_adaptive_xml(res):
    d = os.path.join(res, 'mipmap-anydpi-v26')
    os.makedirs(d, exist_ok=True)
    body = ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android='
            '"http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@mipmap/ic_launcher_bg"/>\n'
            '    <foreground android:drawable="@drawable/ic_launcher_fg"/>\n'
            '    <monochrome android:drawable="@drawable/ic_launcher_mono"/>\n'
            '</adaptive-icon>\n')
    for name in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        with open(os.path.join(d, name), 'w', encoding='utf-8') as f:
            f.write(body)
    print('android: mipmap-anydpi-v26/ic_launcher.xml')


# ---------------------------------------------------------------------------
# Самопроверка
# ---------------------------------------------------------------------------

def verify():
    """Проверяет то, что видно только на телефоне.

    Каждая проверка — реальная поломка, которую уже ловили руками:

    * углы иконки прозрачные — иначе на светлой теме iOS и в PWA торчат
      чёрные углы квадрата;
    * по кромке холста нет пикселей — иначе диагональные линии исходника
      превращаются в грязные штрихи на 48 px;
    * центр непрозрачный — иначе фигура стала дыркой;
    * монохром не залит — иначе в маску попал красный диск и themed icons
      Android 13+ выглядят вывернутыми;
    * iOS без альфа-канала — App Store такую иконку отклоняет;
    * размеры слоёв адаптивной иконки ровно 108 dp по плотностям.
    """
    problems = []

    def png(path):
        im = Image.open(path)
        return im

    icon = png(os.path.join(ROOT, 'assets', 'images', 'icon-512.png')).convert('RGBA')
    s = icon.width
    a = np.asarray(icon)[:, :, 3]
    if a[s // 2, s // 2] < 240:
        problems.append('icon-512: центр прозрачный')
    for name, (x, y) in {'ЛВ': (4, 4), 'ПВ': (s - 5, 4),
                         'ЛН': (4, s - 5), 'ПН': (s - 5, s - 5)}.items():
        if a[y, x] >= 16:
            problems.append(f'icon-512: угол {name} не прозрачный')
    edge_max = max(int(a[0, :].max()), int(a[-1, :].max()),
                   int(a[:, 0].max()), int(a[:, -1].max()))
    if edge_max >= 16:
        problems.append(f'icon-512: непрозрачный пиксель на кромке ({edge_max})')

    mono_path = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res',
                             'drawable-xxxhdpi', 'ic_launcher_mono.png')
    mono = np.asarray(Image.open(mono_path).convert('RGBA'))[:, :, 3]
    share = (mono > 128).mean()
    if not 0.10 <= share <= 0.55:
        problems.append(f'монохром: залито {share:.0%} (ожидалось 10…55%)')
    if mono[mono.shape[0] // 2, 40] >= 32:
        problems.append('монохром: в слой попал край диска')

    for base, label in [
        ('ios/Runner/Assets.xcassets/AppIcon.appiconset', 'iOS'),
    ]:
        for name in sorted(os.listdir(os.path.join(ROOT, base))):
            if not name.endswith('.png'):
                continue
            im = png(os.path.join(ROOT, base, name))
            if im.mode in ('RGBA', 'LA') or 'transparency' in im.info:
                problems.append(f'{label}: {name} с альфа-каналом')
                break

    # Слои адаптивной иконки: 108 dp по плотностям.
    res = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
    for dens, px in [('mdpi', 108), ('hdpi', 162), ('xhdpi', 216),
                     ('xxhdpi', 324), ('xxxhdpi', 432)]:
        for rel in (f'mipmap-{dens}/ic_launcher_bg.png',
                    f'drawable-{dens}/ic_launcher_fg.png',
                    f'drawable-{dens}/ic_launcher_mono.png'):
            path = os.path.join(res, rel)
            if not os.path.exists(path):
                problems.append(f'нет слоя: {rel}')
                continue
            im = png(path)
            if (im.width, im.height) != (px, px):
                problems.append(f'{rel}: {im.size}, ожидалось {px}×{px}')

    if problems:
        for pr in problems:
            print('  ОШИБКА:', pr)
        print(f'иконка: {len(problems)} проблем')
        return 1
    print('иконка: всё на месте (диск, прозрачные углы, монохром, iOS без альфы)')
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--android', action='store_true')
    ap.add_argument('--ios', action='store_true')
    ap.add_argument('--web', action='store_true')
    ap.add_argument('--verify', action='store_true',
                    help='проверить уже собранные иконки, ничего не писать')
    args = ap.parse_args()

    if args.verify:
        return verify()

    if not os.path.exists(SOURCE):
        print('нет исходника:', SOURCE)
        return 2

    docs = os.path.join(ROOT, 'docs', 'иконки')
    os.makedirs(docs, exist_ok=True)

    # Витрина. 1024 — мастер для магазинов; 512 на тёмном показывает, как
    # выглядит прозрачный край там, где подложки нет.
    render(1024).save(os.path.join(docs, 'иконка-1024.png'))
    render(1024, flat_bg=FLAT_BG).save(
        os.path.join(docs, 'иконка-1024-на-тёмном.png'))
    preview(os.path.join(docs, 'иконка-превью.png'))
    print('мастер и превью:', docs)

    if args.all or args.android:
        res = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
        for dens, px in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96),
                         ('xxhdpi', 144), ('xxxhdpi', 192)]:
            p = os.path.join(res, f'mipmap-{dens}', 'ic_launcher.png')
            # Старые лончеры и «круглые» иконки: без альфы, с подложкой.
            render(px, flat_bg=FLAT_BG).save(p)
            render(px, flat_bg=FLAT_BG).save(
                os.path.join(res, f'mipmap-{dens}', 'ic_launcher_round.png'))
            print('android:', p)

        for dens, px in [('mdpi', 108), ('hdpi', 162), ('xhdpi', 216),
                         ('xxhdpi', 324), ('xxxhdpi', 432)]:
            for d2 in (f'mipmap-{dens}', f'drawable-{dens}'):
                os.makedirs(os.path.join(res, d2), exist_ok=True)
            render_layer('bg', px).save(
                os.path.join(res, f'mipmap-{dens}', 'ic_launcher_bg.png'))
            render_layer('fg', px).save(
                os.path.join(res, f'drawable-{dens}', 'ic_launcher_fg.png'))
            render_mono(px).save(
                os.path.join(res, f'drawable-{dens}', 'ic_launcher_mono.png'))
            print('adaptive:', dens)
        write_adaptive_xml(res)

    if args.all or args.ios:
        iconset = os.path.join(ROOT, 'ios', 'Runner', 'Assets.xcassets',
                               'AppIcon.appiconset')
        for name, px in ios_sizes().items():
            render(px, flat_bg=FLAT_BG).save(os.path.join(iconset, name))
        print('ios: собрано', len(ios_sizes()), 'файлов')

    if args.all or args.web:
        render(192).save(os.path.join(ROOT, 'assets', 'images', 'icon-192.png'))
        render(512).save(os.path.join(ROOT, 'assets', 'images', 'icon-512.png'))
        # maskable: содержимое должно влезть в круг радиусом 0,8 стороны,
        # поэтому диск занимает 74% холста, а не 100%.
        render(512, scale=0.74).save(
            os.path.join(ROOT, 'assets', 'images', 'icon-512-maskable.png'))
        print('web: icon-192, icon-512, icon-512-maskable')
    return 0


if __name__ == '__main__':
    sys.exit(main())
