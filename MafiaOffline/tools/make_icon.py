#!/usr/bin/env python3
"""Иконка «Мафия Offline»: плитка с джентльменом, без фона.

Откуда взялась картинка
-----------------------
Владелец прислал сгенерированное изображение: скруглённая красная плитка с
силуэтом джентльмена в цилиндре и надписью «МАФИЯ». Плитка лежала на красном
фоне, справа от неё шла диагональная тень, в правом нижнем углу — водяной
знак «Шедеврум».

Что требовалось
---------------
Оставить саму плитку с эффектом выпуклости, убрать фон, тень и водяной знак,
и поставить её вместо прежней иконки (федора) на всех платформах.

Почему плитка пересобирается, а не вырезается
--------------------------------------------
Вырезка по контуру тянет за собой диагональную тень: её цвет близок к
красному краю плитки (R 110...135 против 190...205), порогом их не
разделить чисто. Плюс кромка получается рваной. Поэтому:

  * геометрия снята с исходника: x 227..794, y 225..758, радиус 92 px;
  * заливка — вертикальный градиент, снятый с исходника;
  * фаска — светлый кант по верхней и левой кромке, тёмный по нижней и
    правой. Она и создаёт «выпуклость» — без неё плитка плоская;
  * силуэт и надпись — маски по цвету, очищенные от красного свечения
    по краям. Иначе на прозрачном фоне остаётся розовая кайма.

Что на выходе
-------------
Иконка **без фона**: прозрачный PNG с плиткой и мягкой тенью по контуру.
Для платформ, которые альфу не принимают (iOS, Play Market), прозрачный
край подкладывается тёмным цветом темы — см. render(..., flat_bg=...).

Запуск:
    python3 tools/make_icon.py            # мастер + превью в docs/иконки
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
SOURCE = os.path.join(ROOT, 'tools', 'icon_source', 'мафия-исходник.jpg')

BLACK = (16, 16, 20)
CREAM = (246, 241, 228)
# Подложка для платформ без прозрачности: почти чёрный, как фон приложения.
FLAT_BG = (22, 23, 29)

# Геометрия плитки в координатах исходника (1024x1024), измерена по канту.
CARD_X0, CARD_Y0, CARD_X1, CARD_Y1 = 227, 225, 794, 758
CARD_R = 92
# Контент (силуэт + надпись) внутри исходника.
CONTENT = (305, 268, 718, 753)

SS = 2  # суперсэмплинг: считаем вдвое крупнее, уменьшаем в конце


# ---------------------------------------------------------------------------
# Снятие масок с исходника
# ---------------------------------------------------------------------------

def load_masks():
    """Маски силуэта и надписи, снятые по цвету.

    Чёрный силуэт: яркость < 78 и красный канал < 95. Диагональная тень
    имеет красный канал 110...135, поэтому в маску не попадает — именно
    это разделение и позволило обойтись без вырезки по контуру.

    Кремовая надпись: единственное светлое пятно внутри плитки.

    Границы ограничены внутренней областью плитки (с отступом 6 px от
    канта): иначе светлый кант попадал бы в маску надписи.
    """
    im = Image.open(SOURCE).convert('RGB')
    if im.size != (1024, 1024):
        im = im.resize((1024, 1024), Image.LANCZOS)
    a = np.asarray(im).astype(float)
    lum = 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]
    red, green = a[:, :, 0], a[:, :, 1]

    yy, xx = np.mgrid[0:1024, 0:1024]
    inside = ((xx >= CARD_X0 + 6) & (xx <= CARD_X1 - 6) &
              (yy >= CARD_Y0 + 6) & (yy <= CARD_Y1 - 6))

    black = (lum < 78) & (red < 95) & inside
    cream = (red > 165) & (green > 140) & inside

    def soften(mask):
        """Порог даёт «лестницу»; 0,8 px размытия возвращает полутона."""
        return Image.fromarray((mask * 255).astype('uint8'), 'L').filter(
            ImageFilter.GaussianBlur(0.8))

    return soften(black), soften(cream)


# ---------------------------------------------------------------------------
# Детали плитки
# ---------------------------------------------------------------------------

def fill_gradient(w, h):
    """Заливка плитки. Верх (222, 86, 76) → низ (198, 38, 31).

    Не ровный красный: перепад вместе с фаской и даёт объём.
    """
    img = Image.new('RGB', (w, h))
    d = ImageDraw.Draw(img)
    top, bot = (222, 86, 76), (198, 38, 31)
    for y in range(h):
        t = (y / max(1, h - 1)) ** 1.15
        d.line([(0, y), (w, y)],
               fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    return img


def rounded_mask(w, h, radius, scale=4):
    """Маска скруглённого прямоугольника, сглаженная суперсэмплингом."""
    big = Image.new('L', (w * scale, h * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        [0, 0, w * scale - 1, h * scale - 1],
        radius=int(radius * scale), fill=255)
    return big.resize((w, h), Image.LANCZOS)


def bevel_ring(w, h, radius, width):
    """Кольцо фаски: внешний контур минус тот же контур, сжатый внутрь."""
    outer = np.asarray(rounded_mask(w, h, radius)) > 127
    inner_mask = np.asarray(
        rounded_mask(w - 2 * width, h - 2 * width, radius - width)) > 127
    inner = np.zeros_like(outer)
    inner[width:width + inner_mask.shape[0],
          width:width + inner_mask.shape[1]] = inner_mask
    ring = Image.fromarray(((outer & ~inner) * 255).astype('uint8'), 'L')
    # Размытие смягчает обе границы кольца: кант не должен быть ступенькой.
    return ring.filter(ImageFilter.GaussianBlur(max(0.6, width * 0.22)))


def bevel_layer(w, h, radius, width):
    """Слой фаски: свет сверху и слева, тень снизу и справа.

    Градиент по вертикали вместо резкой границы половин: на плитке 92 px
    скругления резкая граница читается как шов.
    """
    layer = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for y in range(h):
        t = y / max(1, h - 1)
        if t < 0.5:
            k = 1.0 - t / 0.5                       # ярко у верха, гаснет к середине
            d.line([(0, y), (w, y)], fill=(255, 220, 212, int(150 * k)))
        else:
            k = (t - 0.5) / 0.5                     # нарастает к низу
            d.line([(0, y), (w, y)], fill=(120, 14, 16, int(96 * k)))
    layer.putalpha(Image.composite(
        layer.getchannel('A'), Image.new('L', (w, h), 0),
        bevel_ring(w, h, radius, width)))
    return layer


# ---------------------------------------------------------------------------
# Сборка
# ---------------------------------------------------------------------------

# Доли, снятые с исходника. Рисунок занимает 0,729 ширины и 0,910 высоты
# плитки: он большой и стоит не по центру — сверху воздуха мало, снизу
# почти нет (надпись упирается в нижнюю кромку, так у автора картинки).
# Если поставить рисунок «по центру и помельче», композиция рассыпается:
# подбородок уходит вверх, надпись отрывается от края.
CONTENT_W = (718 - 305 + 1) / (794 - 227 + 1)
CONTENT_H = (753 - 268 + 1) / (758 - 225 + 1)
CONTENT_DX = (305 - 227) / (794 - 227 + 1)
CONTENT_DY = (268 - 225) / (758 - 225 + 1)


def render(size, flat_bg=None, content_scale=0.94, card_ratio=0.86):
    """Иконка целиком.

    flat_bg — если задан, прозрачность заменяется этим цветом: iOS и Play
    Market альфу не принимают.
    content_scale — множитель размера рисунка относительно исходника.
    0,94 — рисунок на 6% меньше авторского: ровно столько, чтобы нижние
    засечки «МАФИЯ» не касались скругления. 0,78 — для maskable-иконки
    PWA: Android обрезает её по кругу и требует запас по краям.
    card_ratio — какую долю холста занимает плитка.
    """
    S = size * SS
    # Пропорции плитки из исходника: 568 x 534.
    card_w = int(S * card_ratio)
    card_h = int(card_w * 534 / 568)
    radius = card_w * (CARD_R / 568.0)

    # 1) Плитка: заливка под маской скругления.
    plate = Image.new('RGBA', (card_w, card_h), (0, 0, 0, 0))
    plate.paste(fill_gradient(card_w, card_h),
                (0, 0), rounded_mask(card_w, card_h, radius))

    # 2) Фаска — поверх кромки.
    plate.alpha_composite(bevel_layer(card_w, card_h, radius,
                                      max(2, int(card_w * 0.026))))

    # 3) Силуэт и надпись — в тех же долях плитки, что у автора картинки.
    black_m, cream_m = load_masks()
    cx0, cy0, cx1, cy1 = CONTENT
    content_w = int(card_w * CONTENT_W * content_scale)
    content_h = int(card_h * CONTENT_H * content_scale)
    # Сдвиг сохраняет верхний воздух исходника (0,08 карточки), а излишек
    # высоты отдаётся низу: у автора картинки надпись стояла вплотную к
    # кромке, и на иконке её нижние засечки резались скруглением.
    free_x = card_w - int(card_w * CONTENT_W)
    free_y = card_h - int(card_h * CONTENT_H)
    px = int(card_w * CONTENT_DX + (free_x * (1 - content_scale)) / 2)
    py = int(card_h * CONTENT_DY + (free_y * (1 - content_scale)) * 0.75)
    box = (cx0, cy0, cx1 + 1, cy1 + 1)
    for mask, colour in ((black_m, BLACK), (cream_m, CREAM)):
        part = mask.crop(box).resize((content_w, content_h), Image.LANCZOS)
        layer = Image.new('RGBA', part.size, colour + (0,))
        layer.putalpha(part)
        plate.alpha_composite(layer, (px, py))

    # 4) Холст: мягкая тень по контуру + плитка.
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ox, oy = (S - card_w) // 2, (S - card_h) // 2

    shadow_alpha = rounded_mask(card_w, card_h, radius).filter(
        ImageFilter.GaussianBlur(S * 0.018))
    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 255), (ox, oy + int(S * 0.012)),
                 shadow_alpha.point(lambda v: int(v * 0.38)))
    out = Image.alpha_composite(out, shadow)
    out.alpha_composite(plate, (ox, oy))

    out = out.resize((size, size), Image.LANCZOS)
    if flat_bg is not None:
        canvas = Image.new('RGB', (size, size), flat_bg)
        canvas.paste(out, (0, 0), out)
        return canvas
    return out


def render_layer(kind, size):
    """Слои адаптивной иконки Android (108dp).

    Android обрезает слой до центральных 66 из 108 dp (безопасная зона —
    72). Поэтому плитка в переднем плане занимает 74%: целиком внутри
    безопасной зоны, но не мелкая.
    """
    if kind == 'bg':
        # Фон — глубокий бордовый: не спорит с плиткой и даёт контур на
        # любом лончере, включая светлый.
        img = Image.new('RGB', (size, size))
        d = ImageDraw.Draw(img)
        top, bot = (122, 16, 22), (74, 8, 12)
        for y in range(size):
            t = y / max(1, size - 1)
            d.line([(0, y), (size, y)],
                   fill=tuple(int(top[i] + (bot[i] - top[i]) * t)
                              for i in range(3)))
        return img

    # 0,74 — предел безопасной зоны: плитка целиком внутри круга, который
    # рисует лончер (72 из 108 dp), и при этом не выглядит мелкой. На 0,615
    # плитка занимала меньше половины иконки.
    small = int(size * 0.74)
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    layer.alpha_composite(render(small).resize((small, small), Image.LANCZOS),
                          ((size - small) // 2, (size - small) // 2))
    return layer


def render_mono(size):
    """Монохромный слой для themed icons Android 13+.

    Плитка не нужна: система рисует свою подложку. Отдаём белым силуэт и
    надпись — их форма и есть узнаваемость.
    """
    black_m, cream_m = load_masks()
    cx0, cy0, cx1, cy1 = CONTENT
    S = size * SS
    w = int(S * 0.74 * 0.86)
    h = int(w * (cy1 - cy0) / (cx1 - cx0))
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    for mask in (black_m, cream_m):
        part = mask.crop((cx0, cy0, cx1 + 1, cy1 + 1)).resize((w, h),
                                                               Image.LANCZOS)
        white = Image.new('RGBA', part.size, (255, 255, 255, 255))
        white.putalpha(part)
        layer.alpha_composite(white, ((S - w) // 2, (S - h) // 2))
    return layer.resize((size, size), Image.LANCZOS)


def preview(path):
    """Превью: прозрачный край на тёмном и светлом фоне + мелкие размеры.

    Раскладка считается от реальных размеров: первая версия превью
    ставила иконки с шагом 98 px и накладывала их друг на друга —
    по такой картинке ничего не проверить.
    """
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

    # Крупно: прозрачный край на тёмном и на светлом фоне.
    sh.paste(render(240), (gap, gap), render(240))
    light = render(240)
    sh.paste(light, (W // 2 + gap, gap), light)

    # Мелкие размеры в два ряда: тёмный стол и светлый.
    for row, (bg, y0) in enumerate(((None, 240 + 2 * gap),
                                    ((236, 236, 240), 240 + 3 * gap + row_h))):
        x = gap
        for px in sizes:
            img = render(px, flat_bg=bg)
            # flat_bg возвращает RGB — маску передавать нельзя, только для RGBA.
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
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@mipmap/ic_launcher_bg"/>\n'
            '    <foreground android:drawable="@drawable/ic_launcher_fg"/>\n'
            '    <monochrome android:drawable="@drawable/ic_launcher_mono"/>\n'
            '</adaptive-icon>\n')
    for name in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        with open(os.path.join(d, name), 'w', encoding='utf-8') as f:
            f.write(body)
    print('android: mipmap-anydpi-v26/ic_launcher.xml')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--android', action='store_true')
    ap.add_argument('--ios', action='store_true')
    ap.add_argument('--web', action='store_true')
    args = ap.parse_args()

    if not os.path.exists(SOURCE):
        print('нет исходника:', SOURCE)
        return 2

    docs = os.path.join(ROOT, 'docs', 'иконки')
    os.makedirs(docs, exist_ok=True)
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
        render(512, content_scale=0.78).save(
            os.path.join(ROOT, 'assets', 'images', 'icon-512-maskable.png'))
        print('web: icon-192, icon-512, icon-512-maskable')
    return 0


if __name__ == '__main__':
    sys.exit(main())
