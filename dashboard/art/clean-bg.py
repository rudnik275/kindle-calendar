#!/usr/bin/env python3
"""Стирає запечений текст із референсу texture-bomb-клонуванням і зберігає
чистий фон art/bg.png (800x600, grayscale) для template.html.
Координати — під source-ref.png 1448x1086.
Двоетапно: 1) годинник чиститься серпанком; 2) очищена зона годинника стає
великим чистим джерелом для решти зон."""
import random
from PIL import Image, ImageDraw, ImageFilter, ImageOps
import os

random.seed(42)
HERE = os.path.dirname(os.path.abspath(__file__))
im = Image.open(os.path.join(HERE, 'source-ref.png')).convert('L')


def feather_mask(size, edge=8):
    """Маска з непрозорим ядром і мʼяким краєм (без розмиття ядра)."""
    m = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([edge, edge, size - edge, size - edge],
                        radius=size // 4, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(edge // 2 + 2))
    return m.point(lambda v: min(255, int(v * 1.6)))


def bomb(region, sources, patch=64, step_ratio=0.38, edge=8, passes=3):
    x0, y0, x1, y1 = region
    mask = feather_mask(patch, edge)
    step = max(8, int(patch * step_ratio))
    for _ in range(passes):
        for y in range(y0 - patch // 3, y1 - patch // 3, step):
            for x in range(x0 - patch // 3, x1 - patch // 3, step):
                sx0, sy0, sx1, sy1 = random.choice(sources)
                px = random.randint(sx0, max(sx0, sx1 - patch))
                py = random.randint(sy0, max(sy0, sy1 - patch))
                tile = im.crop((px, py, px + patch, py + patch))
                if random.random() < .5:
                    tile = ImageOps.mirror(tile)
                if random.random() < .5:
                    tile = ImageOps.flip(tile)
                im.paste(tile, (x + random.randint(-5, 5), y + random.randint(-5, 5)), mask)


# ЕТАП 1: годинник + дата + орнамент — чистимо серпанком (без зон із птахами)
MIST = (596, 128, 748, 298)
bomb((795, 65, 1210, 298), [MIST], patch=72)

# ЕТАП 2: очищена зона годинника — велике чисте джерело пергаменту
SRC_CLK = (810, 85, 1190, 285)
P_UNDER_EV = (598, 800, 782, 838)          # чиста смуга під подіями

# колонка подій (часи, ромби, назви, лінійки)
bomb((560, 308, 1100, 798), [SRC_CLK, SRC_CLK, P_UNDER_EV], patch=68)
# «18» на вежі — текстурою вежі
TOWER_L = (150, 335, 218, 610)
TOWER_T = (250, 298, 430, 345)
TOWER_B = (205, 612, 395, 705)
bomb((210, 340, 440, 615), [TOWER_L, TOWER_T, TOWER_B], patch=48, edge=7, passes=4)
# чорнильний квадрат ПТ-24 з бризками
bomb((775, 823, 1035, 1062), [SRC_CLK, P_UNDER_EV], patch=64, passes=4)
# текст тижня — по колонках (крім ПТ — він у квадраті)
for c in (135, 325, 530, 715, 1095, 1290):
    bomb((c - 85, 860, c + 85, 1008),
         [(c - 85, 1010, c + 85, 1082), SRC_CLK], patch=56, passes=4)

def tone_match(region, pad=45, feather=28):
    """Вирівнює середню яскравість зони до кільця навколо неї."""
    x0, y0, x1, y1 = region
    from PIL import ImageStat
    px0, py0 = max(0, x0 - pad), max(0, y0 - pad)
    px1, py1 = min(im.width, x1 + pad), min(im.height, y1 + pad)
    reg = im.crop((x0, y0, x1, y1))
    area_r = (x1 - x0) * (y1 - y0)
    area_p = (px1 - px0) * (py1 - py0)
    mean_r = ImageStat.Stat(reg).mean[0]
    mean_p = ImageStat.Stat(im.crop((px0, py0, px1, py1))).mean[0]
    ring_mean = (mean_p * area_p - mean_r * area_r) / max(1, area_p - area_r)
    delta = int(round(ring_mean - mean_r))
    adj = reg.point(lambda v: max(0, min(255, v + delta)))
    m = Image.new('L', (x1 - x0, y1 - y0), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [feather // 2, feather // 2, x1 - x0 - feather // 2, y1 - y0 - feather // 2],
        radius=feather, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(feather // 2))
    im.paste(adj, (x0, y0), m)


tone_match((560, 308, 1100, 798))
tone_match((795, 65, 1210, 298))
tone_match((775, 823, 1035, 1062))
for c in (135, 325, 530, 715, 1095, 1290):
    tone_match((c - 85, 860, c + 85, 1008), pad=35, feather=24)

out = im.resize((800, 600), Image.LANCZOS)
out.save(os.path.join(HERE, 'bg.png'))
print('bg.png saved', out.size)
