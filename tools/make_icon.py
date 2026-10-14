"""用代码精确绘制 iOS App 图标候选方案。

为什么不用 AI 生图：生成结果带水印，且边界不精确；App 图标需要干净的
1024x1024、无透明、几何精确的图像，代码绘制更合适。
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

OUT = r'c:/Users/wxw/Desktop/wxw-kf/icons'
SIZE = 1024
S = 2                      # 超采样倍率，最后缩回 1024 获得抗锯齿
W = SIZE * S

RED = (255, 59, 48)        # iOS 系统红
os.makedirs(OUT, exist_ok=True)


def background(inner, outer):
    """径向渐变背景：中心稍亮，边缘变暗"""
    grad = Image.radial_gradient('L').resize((W, W), Image.BILINEAR)
    return Image.composite(
        Image.new('RGB', (W, W), outer),
        Image.new('RGB', (W, W), inner),
        grad,
    ).convert('RGBA')


def ring(draw, cx, cy, radius, color, width, start=None, end=None):
    box = [cx - radius, cy - radius, cx + radius, cy + radius]
    if start is None:
        draw.ellipse(box, outline=color, width=width)
    else:
        draw.arc(box, start=start, end=end, fill=color, width=width)


def render(variant):
    cx = cy = W / 2

    if variant == 'lens':
        img = background((40, 43, 49), (8, 9, 11))
        glow_layer = Image.new('RGBA', (W, W), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        gdraw = ImageDraw.Draw(glow_layer)

        r_out, r_mid = 316 * S, 238 * S
        ring(draw, cx, cy, r_out, (158, 167, 177), 26 * S)
        ring(draw, cx, cy, r_mid, (96, 104, 114), 15 * S)
        # 顶部高光弧，让金属环有体积感
        ring(draw, cx, cy, r_out, (226, 233, 240), 26 * S, start=196, end=246)
        # 6 条叶片刻度
        for i in range(6):
            angle = math.radians(i * 60 + 12)
            x1 = cx + math.cos(angle) * r_mid
            y1 = cy + math.sin(angle) * r_mid
            x2 = cx + math.cos(angle) * r_out
            y2 = cy + math.sin(angle) * r_out
            draw.line([x1, y1, x2, y2], fill=(122, 130, 140), width=10 * S)

        gdraw.ellipse([cx - 118 * S, cy - 118 * S, cx + 118 * S, cy + 118 * S], fill=RED + (170,))
        img = Image.alpha_composite(img, glow_layer.filter(ImageFilter.GaussianBlur(70 * S)))
        draw = ImageDraw.Draw(img)
        r_dot = 82 * S
        draw.ellipse([cx - r_dot, cy - r_dot, cx + r_dot, cy + r_dot], fill=RED)
        # 红点上的一点内高光
        hx, hy, hr = cx - 26 * S, cy - 30 * S, 20 * S
        draw.ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=(255, 138, 128))

    elif variant == 'screen':
        img = background((30, 32, 36), (5, 5, 6))
        glow_layer = Image.new('RGBA', (W, W), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        gdraw = ImageDraw.Draw(glow_layer)

        rw, rh, rad = 300 * S, 430 * S, 78 * S
        draw.rounded_rectangle(
            [cx - rw, cy - rh, cx + rw, cy + rh],
            radius=rad, outline=(146, 154, 163), width=18 * S,
        )
        dot_x, dot_y, dot_r = cx + 168 * S, cy - 300 * S, 46 * S
        gdraw.ellipse([dot_x - 96 * S, dot_y - 96 * S, dot_x + 96 * S, dot_y + 96 * S], fill=RED + (170,))
        img = Image.alpha_composite(img, glow_layer.filter(ImageFilter.GaussianBlur(64 * S)))
        draw = ImageDraw.Draw(img)
        draw.ellipse([dot_x - dot_r, dot_y - dot_r, dot_x + dot_r, dot_y + dot_r], fill=RED)

    else:  # 'dot'
        img = background((34, 36, 41), (7, 7, 8))
        glow_layer = Image.new('RGBA', (W, W), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        gdraw = ImageDraw.Draw(glow_layer)

        ring(draw, cx, cy, 262 * S, (112, 120, 130), 13 * S)
        gdraw.ellipse([cx - 200 * S, cy - 200 * S, cx + 200 * S, cy + 200 * S], fill=RED + (150,))
        img = Image.alpha_composite(img, glow_layer.filter(ImageFilter.GaussianBlur(80 * S)))
        draw = ImageDraw.Draw(img)
        r_dot = 118 * S
        draw.ellipse([cx - r_dot, cy - r_dot, cx + r_dot, cy + r_dot], fill=RED)

    # iOS 图标不能带透明通道，且需要 1024x1024
    return img.convert('RGB').resize((SIZE, SIZE), Image.LANCZOS)


for name in ('lens', 'screen', 'dot'):
    icon = render(name)
    path = os.path.join(OUT, 'icon-' + name + '.png')
    icon.save(path, 'PNG')
    print('  ' + os.path.basename(path) + '  ' + str(icon.size[0]) + 'x' + str(icon.size[1]) +
          '  ' + str(round(os.path.getsize(path) / 1024)) + ' KB')
