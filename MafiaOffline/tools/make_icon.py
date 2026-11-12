#!/usr/bin/env python3
"""Иконка «Мафия Offline»: чёрная федора на алом поле.

Концепция
---------
Один образ — шляпа гангстера. Никаких букв, рамок и второго символа.

Почему так (по рекомендациям из профильных источников):
  * одна метафора на иконку — «иконка должна читаться в 48 px, всё шумное
    безжалостно удаляется» (kokoc.com/blog/kak-sozdat-ikonku);
  * силуэт прежде цвета — шляпа остаётся узнаваемой чёрным пятном
    (blog.appfyl.com, silhouette-first);
  * никакого текста — буквы в мелком размере превращаются в кашу
    (habr.com/ru/post/492218);
  * 2-3 цвета: алый, чёрный, кремовый — максимальный контраст.

Фон
---
Подложка A из трёх проверенных: алый #DE2234 сверху, уходящий в глубокий
бордовый #960C1C книзу. Причина: шляпа чёрная, и на ровном алом её нижние
поля сливались с фоном. Затемнение снизу отделяет поля от подложки, а
круглая маска Android не съедает контраст по краям.

Запуск:
    python3 tools/make_icon.py            # мастер 1024 + превью
    python3 tools/make_icon.py --all      # + Android, iOS, PWA
"""
import argparse
import math
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover
    print('Нужен Pillow: pip install pillow')
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RED_TOP = (222, 34, 52)
RED_BOT = (150, 12, 28)
BLACK = (18, 18, 22)
CREAM = (246, 241, 228)

S = 1024
SS = 2          # суперсэмплинг


def _bg(w):
    """Фон: вертикальный градиент. Ровный, без пятен и виньеток."""
    img = Image.new('RGB', (w, w), RED_TOP)
    d = ImageDraw.Draw(img)
    for y in range(w):
        t = (y / max(1, w - 1)) ** 1.1
        col = tuple(int(RED_TOP[i] + (RED_BOT[i] - RED_TOP[i]) * t) for i in range(3))
        d.line([(0, y), (w, y)], fill=col)
    return img


def hat_polygon(W, top_y, height):
    """Силуэт федоры: тулья с вмятиной сверху + широкие поля с подъёмом.

    Одна замкнутая форма — так её можно и залить, и превратить в монохромный
    слой для themed icons Android.
    """
    cx = W / 2.0
    h = height
    bw = W * 0.84           # размах полей
    cw = W * 0.30           # ширина тульи сверху
    cy = top_y + h * 0.60   # линия перехода тульи в поля

    def P(x, y):
        return (cx + x, top_y + y)

    # Обход по часовой: левое поле -> тулья -> правый край -> правое поле.
    pts = [
        P(-bw * 0.50, h * 0.655),                    # левый кончик полей
        P(-bw * 0.36, h * 0.585),                    # подъём левого поля
        P(-cw * 0.62, h * 0.375),                    # спад в тулью
        P(-cw * 0.56, h * 0.145),                    # левая стенка тульи
        P(-cw * 0.44, h * 0.055),                    # скругление к вмятине
        P(-cw * 0.26, h * 0.075),                    # вмятина: спуск
        P(-cw * 0.10, h * 0.128),                    # низ вмятины слева
        P(0.0, h * 0.140),                           # дно вмятины
        P(cw * 0.10, h * 0.128),                     # низ вмятины справа
        P(cw * 0.26, h * 0.075),                     # вмятина: подъём
        P(cw * 0.44, h * 0.055),                     # скругление
        P(cw * 0.56, h * 0.145),                     # правая стенка
        P(cw * 0.62, h * 0.375),                     # спад в поля
        P(bw * 0.36, h * 0.585),                     # подъём правого поля
        P(bw * 0.50, h * 0.66),                      # правый кончик полей
    ]
    # Низ полей — дуга от правого кончика к левому через низ.
    arc = []
    steps = 48
    rx = bw * 0.50
    ry = h * 0.285
    for i in range(steps + 1):
        a = math.pi * i / steps        # 0..pi
        arc.append(P(rx * math.cos(a), h * 0.66 + ry * math.sin(a)))
    pts += arc
    return pts


def hat_band(W, top_y, height):
    """Лента на тулье: полоса, повторяющая сужение тульи к полям.

    Ширина ленты задаётся стенками тульи на её высоте, а не константой —
    иначе на скруглённой тулье лента вылезает за силуэт.
    """
    cx = W / 2.0
    h = height
    cw = W * 0.30
    y0, y1 = h * 0.335, h * 0.445

    def wall(y):
        """Позиция стенки тульи по вертикали (линейно между опорными точками)."""
        # опорные точки стенки из hat_polygon: (0.145, 0.56cw) и (0.375, 0.62cw)
        t = (y - 0.145) / (0.375 - 0.145)
        t = max(0.0, min(1.0, t))
        return cw * (0.56 + 0.06 * t)

    return [
        (cx - wall(y0), top_y + y0), (cx + wall(y0), top_y + y0),
        (cx + wall(y1), top_y + y1), (cx - wall(y1), top_y + y1),
    ]


def render(size, mask=None, scale=1.0, offset_y=0.0):
    """Иконка целиком. mask: None | 'circle' | 'rounded'."""
    W = size * SS
    img = _bg(W)
    d = ImageDraw.Draw(img)

    h = W * 0.60 * scale
    top_y = (W - h) / 2.0 + W * offset_y

    shadow = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.polygon([(x, y + W * 0.012) for x, y in hat_polygon(W, top_y, h)],
               fill=(60, 0, 8, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(W * 0.012))
    img = Image.alpha_composite(img.convert('RGBA'), shadow).convert('RGB')
    d = ImageDraw.Draw(img)

    d.polygon(hat_polygon(W, top_y, h), fill=BLACK)
    d.polygon(hat_band(W, top_y, h), fill=CREAM)

    img = img.resize((size, size), Image.LANCZOS)

    if mask == 'circle':
        m = Image.new('L', (size, size), 0)
        ImageDraw.Draw(m).ellipse([0, 0, size - 1, size - 1], fill=255)
        out = Image.new('RGB', (size, size), (14, 15, 20))
        out.paste(img, (0, 0), m)
        img = out
    elif mask == 'rounded':
        m = Image.new('L', (size, size), 0)
        ImageDraw.Draw(m).rounded_rectangle(
            [0, 0, size - 1, size - 1], radius=int(size * 0.225), fill=255)
        out = Image.new('RGB', (size, size), (14, 15, 20))
        out.paste(img, (0, 0), m)
        img = out
    return img


def render_layer(kind, size):
    """Слои адаптивной иконки Android (108dp).

    Android обрезает слой до центральных 66 из 108 dp, поэтому знак в
    переднем плане уменьшен до ~61% — иначе маска срежет поля шляпы.
    """
    W = size * SS
    if kind == 'bg':
        return _bg(W).resize((size, size), Image.LANCZOS)

    img = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    h = W * 0.60 * 0.615
    top_y = (W - h) / 2.0
    d.polygon(hat_polygon(W, top_y, h), fill=BLACK + (255,))
    d.polygon(hat_band(W, top_y, h), fill=CREAM + (255,))
    return img.resize((size, size), Image.LANCZOS)


def render_mono(size):
    """Монохромный слой для themed icons Android 13+: только силуэт, альфа."""
    W = size * SS
    img = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    h = W * 0.60 * 0.615
    top_y = (W - h) / 2.0
    d.polygon(hat_polygon(W, top_y, h), fill=(255, 255, 255, 255))
    # лента вырезается, иначе в монохроме шляпа сливается в пятно
    band = hat_band(W, top_y, h)
    d.polygon(band, fill=(0, 0, 0, 0))
    return img.resize((size, size), Image.LANCZOS)


def preview(path):
    W, H = 1280, 520
    sh = Image.new('RGB', (W, H), (14, 15, 20))
    d = ImageDraw.Draw(sh)
    sh.paste(render(230, 'rounded'), (50, 60))
    sh.paste(render(230, 'circle'), (310, 60))
    sh.paste(render(144, 'rounded'), (570, 103))
    sh.paste(render(96, 'rounded'), (750, 127))
    sh.paste(render(48, 'rounded'), (880, 151))
    for i, col in enumerate([(40, 44, 58), (30, 34, 46)]):
        d.rounded_rectangle([980 + i * 104, 127, 980 + i * 104 + 92, 219],
                            radius=20, fill=col)
    sh.paste(render(92, 'rounded'), (980, 127))
    # на светлом фоне и в монохроме
    d.rectangle([50, 330, 190, 470], fill=(236, 236, 240))
    sh.paste(render(140, 'rounded'), (50, 330))
    mono = Image.new('RGB', (140, 140), (210, 214, 224))
    mono.paste(render_mono(140), (0, 0), render_mono(140))
    sh.paste(mono, (230, 330))
    sh.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--android', action='store_true')
    ap.add_argument('--ios', action='store_true')
    ap.add_argument('--web', action='store_true')
    args = ap.parse_args()

    docs = os.path.join(ROOT, 'docs', 'иконки')
    os.makedirs(docs, exist_ok=True)
    render(1024).save(os.path.join(docs, 'иконка-1024.png'))
    preview(os.path.join(docs, 'иконка-превью.png'))
    print('мастер и превью:', docs)

    if args.all or args.android:
        res = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
        for dens, px in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96),
                         ('xxhdpi', 144), ('xxxhdpi', 192)]:
            p = os.path.join(res, f'mipmap-{dens}', 'ic_launcher.png')
            render(px).save(p)
            # Закруглённая версия для лончеров, которые её запрашивают
            # (android:roundIcon). Начиная с API 26 берётся фигура из
            # mipmap-anydpi-v26, поэтому старым устройствам нужен плотный PNG.
            render(px, mask='circle').save(
                os.path.join(res, f'mipmap-{dens}', 'ic_launcher_round.png'))
            print('android:', p)

        # адаптивная иконка: слои 108dp по плотностям
        for dens, px in [('mdpi', 108), ('hdpi', 162), ('xhdpi', 216),
                         ('xxhdpi', 324), ('xxxhdpi', 432)]:
            bg = render_layer('bg', px)
            for d2 in (f'mipmap-{dens}', f'drawable-{dens}'):
                os.makedirs(os.path.join(res, d2), exist_ok=True)
            bg.save(os.path.join(res, f'mipmap-{dens}', 'ic_launcher_bg.png'))
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
            render(px).save(os.path.join(iconset, name))
        print('ios: собрано', len(ios_sizes()), 'файлов')

    if args.all or args.web:
        render(192).save(os.path.join(ROOT, 'assets', 'images', 'icon-192.png'))
        render(512).save(os.path.join(ROOT, 'assets', 'images', 'icon-512.png'))
        render(512, scale=0.78).save(
            os.path.join(ROOT, 'assets', 'images', 'icon-512-maskable.png'))
        print('web: icon-192, icon-512, icon-512-maskable')
    return 0


def ios_sizes():
    base = {
        'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40,
        'Icon-App-20x20@3x.png': 60, 'Icon-App-29x29@1x.png': 29,
        'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
        'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80,
        'Icon-App-40x40@3x.png': 120, 'Icon-App-60x60@2x.png': 120,
        'Icon-App-60x60@3x.png': 180, 'Icon-App-76x76@1x.png': 76,
        'Icon-App-76x76@2x.png': 152, 'Icon-App-83.5x83.5@2x.png': 167,
        'Icon-App-1024x1024@1x.png': 1024,
    }
    return base


def write_adaptive_xml(res):
    """ic_launcher.xml для API 26+: фон + передний план + монохром."""
    d = os.path.join(res, 'mipmap-anydpi-v26')
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'ic_launcher.xml'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@mipmap/ic_launcher_bg"/>\n'
                '    <foreground android:drawable="@drawable/ic_launcher_fg"/>\n'
                '    <monochrome android:drawable="@drawable/ic_launcher_mono"/>\n'
                '</adaptive-icon>\n')
    with open(os.path.join(d, 'ic_launcher_round.xml'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@mipmap/ic_launcher_bg"/>\n'
                '    <foreground android:drawable="@drawable/ic_launcher_fg"/>\n'
                '    <monochrome android:drawable="@drawable/ic_launcher_mono"/>\n'
                '</adaptive-icon>\n')
    print('android: mipmap-anydpi-v26/ic_launcher.xml')


if __name__ == '__main__':
    sys.exit(main())
