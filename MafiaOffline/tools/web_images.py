#!/usr/bin/env python3
"""Уменьшенные картинки для веб-клиента.

Зачем: игроки тянут картинки через точку доступа телефона ведущего. Карточки
инструкций нарисованы в 1024x1536 (150-350 КБ каждая); в браузере они
занимают всю ширину экрана телефона, поэтому 560x840 хватает с запасом даже
для Retina, а вес падает примерно в четыре раза. На 20 игроков это разница
между 70 МБ и 18 МБ трафика через хотспот.

Что делает: читает assets/{cards,instructions,crimes} и кладёт уменьшенные
копии в .../web/ ровно с теми именами (для instructions сохраняется вложенность
roles/ phases/ guides/).

Запуск (нужен Pillow):
    pip install pillow
    python3 tools/web_images.py            # собрать всё
    python3 tools/web_images.py --check    # только проверить, что копии есть

Код возврата 1 — чего-то не хватает или копия устарела (источник новее).
"""
import argparse
import glob
import io
import os
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    print('Нужен Pillow: pip install pillow')
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = (560, 840)   # 2:3 — то же соотношение, что у исходников
QUALITY = 80

# Папки, для которых держим веб-версии. cards и crimes — плоские,
# instructions — с подпапками (roles/, phases/, guides/).
# cards/web уже лежит в репозитории (сделаны раньше и выверены глазами),
# поэтому по умолчанию собираем только новые группы. --all пересоберёт всё.
GROUPS = ['instructions', 'crimes']


def sources():
    """Все исходники, которым нужна веб-копия: [(src, dst), ...]."""
    out = []
    for group in GROUPS:
        base = os.path.join(ROOT, 'assets', group)
        for src in sorted(glob.glob(os.path.join(base, '**', '*.jpg'), recursive=True)):
            rel = os.path.relpath(src, base)
            if rel.split(os.sep)[0] == 'web':
                continue
            dst = os.path.join(base, 'web', rel)
            out.append((src, dst))
    return out


def check(pairs):
    bad = 0
    for src, dst in pairs:
        if not os.path.exists(dst):
            print(f'НЕТ   {os.path.relpath(dst, ROOT)}')
            bad += 1
            continue
        if os.path.getmtime(src) > os.path.getmtime(dst) + 1:
            print(f'СТАРО {os.path.relpath(dst, ROOT)}')
            bad += 1
        if os.path.getsize(dst) > 400 * 1024:
            print(f'ТЯЖЁЛ {os.path.relpath(dst, ROOT)}: {os.path.getsize(dst)} Б')
            bad += 1
    print(f'проверено {len(pairs)} картинок, проблем: {bad}')
    return 1 if bad else 0


def build(pairs):
    total_src = total_dst = 0
    for src, dst in pairs:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with Image.open(src) as im:
            im = im.convert('RGB')
            im.thumbnail(TARGET, Image.LANCZOS)
            buf = io.BytesIO()
            im.save(buf, 'JPEG', quality=QUALITY, optimize=True, progressive=True)
            data = buf.getvalue()
        with open(dst, 'wb') as f:
            f.write(data)
        total_src += os.path.getsize(src)
        total_dst += len(data)
        print(f'{os.path.relpath(dst, ROOT):58s} {len(data) // 1024:4d} КБ')
    print(f'итого: было {total_src // 1024} КБ, стало {total_dst // 1024} КБ')
    return 0


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--all', action='store_true',
                    help='пересобрать и уже готовые cards/web (обычно не нужно)')
    args = ap.parse_args()
    if args.all:
        GROUPS.insert(0, 'cards')
    pairs = sources()
    sys.exit(check(pairs) if args.check else build(pairs))
