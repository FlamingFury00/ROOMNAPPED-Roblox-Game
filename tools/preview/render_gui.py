#!/usr/bin/env python3
"""
render_gui: rasterise a ScreenGui tree exported by export_gui.luau, approximating Roblox's GUI layout.

Supported: UDim2 size/position, AnchorPoint, Visible, ZIndex (sibling), BackgroundColor3/Transparency,
UICorner, UIStroke (Border + Contextual text outline), UIGradient (colour + transparency, any rotation),
UIPadding, UIListLayout (both directions, alignment, padding), UIGridLayout, UIScale, AutomaticSize (X/Y/XY,
including text measurement), UIAspectRatioConstraint, UISizeConstraint, UITextSizeConstraint, TextScaled,
TextWrapped, alignments, ClipsDescendants, ScrollingFrame canvas offset, small-angle rotation of shapes,
ScreenInsets (CoreUISafeInsets reserves the top bar).

Not a pixel-exact engine; it is precise enough to judge layout, spacing, overlap and readability.

Usage: render_gui.py <gui.json> <out.png> [--size WxH] [--inset N] [--scale-note]
"""
import argparse
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONT_DIR = os.path.join(ROOT, "build", "fonts")
INTER = "/usr/share/fonts/opentype/inter"

FONT_FILES = {
    "LuckiestGuy": [os.path.join(FONT_DIR, "LuckiestGuy-Regular.ttf")],
    "FredokaOne": [os.path.join(FONT_DIR, "Fredoka.ttf")],
    "Creepster": [os.path.join(FONT_DIR, "Creepster-Regular.ttf")],
    "SpecialElite": [os.path.join(FONT_DIR, "SpecialElite-Regular.ttf")],
    "Fondamento": [os.path.join(FONT_DIR, "Fondamento-Regular.ttf")],
    "RobotoMono": [os.path.join(FONT_DIR, "RobotoMono.ttf")],
}
INTER_WEIGHTS = {
    "Thin": "Inter-Thin.otf",
    "Light": "Inter-Light.otf",
    "Regular": "Inter-Regular.otf",
    "Medium": "Inter-Medium.otf",
    "SemiBold": "Inter-SemiBold.otf",
    "Bold": "Inter-Bold.otf",
    "ExtraBold": "Inter-ExtraBold.otf",
    "Heavy": "Inter-Black.otf",
}

_font_cache = {}


def font_for(family, weight, size):
    size = max(1, int(round(size)))
    name = "BuilderSans"
    if family:
        base = os.path.basename(family).split(".")[0]
        name = base
    key = (name, weight, size)
    if key in _font_cache:
        return _font_cache[key]
    path = None
    if name in FONT_FILES:
        for candidate in FONT_FILES[name]:
            if os.path.exists(candidate):
                path = candidate
                break
    if path is None:
        file = INTER_WEIGHTS.get(weight or "Regular", "Inter-Medium.otf")
        candidate = os.path.join(INTER, file)
        path = candidate if os.path.exists(candidate) else os.path.join(INTER, "Inter-Regular.otf")
    try:
        font = ImageFont.truetype(path, size)
        if name == "FredokaOne":
            try:
                axes = font.get_variation_axes()
                values = [600 if a["name"] in (b"Weight", "Weight") else 100 for a in axes]
                font.set_variation_by_axes(values)
            except Exception:
                pass
    except Exception:
        font = ImageFont.load_default()
    _font_cache[key] = font
    return font


def rgba(color, transparency=0.0):
    r, g, b = color
    return (int(r * 255 + 0.5), int(g * 255 + 0.5), int(b * 255 + 0.5), int((1 - transparency) * 255 + 0.5))


def lerp(a, b, t):
    return a + (b - a) * t


def sample_sequence(seq, t):
    # seq: [[time, r, g, b]] or [[time, value]]
    if not seq:
        return None
    if t <= seq[0][0]:
        return seq[0][1:]
    for i in range(len(seq) - 1):
        a, b = seq[i], seq[i + 1]
        if a[0] <= t <= b[0]:
            u = 0 if b[0] == a[0] else (t - a[0]) / (b[0] - a[0])
            return [lerp(a[j], b[j], u) for j in range(1, len(a))]
    return seq[-1][1:]


# ---------------------------------------------------------------------------------------------------------
# Tree helpers

MODIFIERS = {
    "UICorner",
    "UIStroke",
    "UIGradient",
    "UIPadding",
    "UIListLayout",
    "UIGridLayout",
    "UIScale",
    "UIAspectRatioConstraint",
    "UISizeConstraint",
    "UITextSizeConstraint",
}


def modifier(node, cls):
    for c in node.get("children", []):
        if c["class"] == cls:
            return c
    return None


def gui_children(node):
    return [c for c in node.get("children", []) if c["class"] not in MODIFIERS]


def is_text(node):
    return node["class"] in ("TextLabel", "TextButton", "TextBox")


# ---------------------------------------------------------------------------------------------------------
# Text measurement


def measure_text(node, k, max_width=None):
    text = node.get("text") or ""
    if text == "":
        return 0, 0
    size = node.get("textSize", 14) * k
    font = font_for(node.get("font"), node.get("weight"), size)
    lines = wrap_lines(text, font, max_width if node.get("wrapped") else None)
    widths = [font.getlength(line) for line in lines]
    ascent, descent = font.getmetrics()
    line_height = (ascent + descent)
    return (max(widths) if widths else 0), line_height * len(lines)


def wrap_lines(text, font, max_width):
    text = strip_rich(text)
    paragraphs = text.split("\n")
    if not max_width or max_width <= 0:
        return paragraphs
    out = []
    for paragraph in paragraphs:
        words = paragraph.split(" ")
        line = ""
        for word in words:
            candidate = word if line == "" else line + " " + word
            if font.getlength(candidate) <= max_width or line == "":
                line = candidate
            else:
                out.append(line)
                line = word
        out.append(line)
    return out


def strip_rich(text):
    import re

    return re.sub(r"<[^>]+>", "", text)


def truncate_lines(lines, font, max_width, max_lines):
    """TextTruncate: keep the lines that fit the box and end the last visible one with an ellipsis."""
    clipped = len(lines) > max_lines
    lines = lines[:max_lines]
    out = []
    for i, line in enumerate(lines):
        last = i == len(lines) - 1
        if font.getlength(line) <= max_width and not (last and clipped):
            out.append(line)
            continue
        cut = line
        while cut and font.getlength(cut + "…") > max_width:
            cut = cut[:-1]
        out.append(cut.rstrip() + "…")
    return out


# ---------------------------------------------------------------------------------------------------------
# Layout


class Box:
    __slots__ = ("x", "y", "w", "h", "k", "node", "children", "clip", "rotation", "content")

    def __init__(self, node, x, y, w, h, k):
        self.node = node
        self.x, self.y, self.w, self.h = x, y, w, h
        self.k = k
        self.children = []
        self.clip = None
        self.rotation = node.get("rotation", 0) or 0
        self.content = None  # (w, h) of a list/grid layout's content, like AbsoluteContentSize


def resolve_size(node, pw, ph, k):
    xs, xo, ys, yo = node.get("size", [0, 0, 0, 0])
    w = pw * xs + xo * k
    h = ph * ys + yo * k
    return max(0.0, w), max(0.0, h)


def apply_constraints(node, w, h, k):
    aspect = modifier(node, "UIAspectRatioConstraint")
    if aspect:
        r = aspect.get("ratio", 1) or 1
        atype = aspect.get("aspectType", "FitWithinMaxSize")
        dominant = aspect.get("dominant", "Width")
        if atype == "ScaleWithParentSize":
            if dominant == "Width":
                h = w / r
            else:
                w = h * r
        else:
            if w / max(h, 1e-6) > r:
                w = h * r
            else:
                h = w / r
    sc = modifier(node, "UISizeConstraint")
    if sc:
        mn, mx = sc.get("min", [0, 0]), sc.get("max", [math.inf, math.inf])
        w = min(max(w, mn[0] * k), (mx[0] if mx[0] < 1e30 else math.inf) * k)
        h = min(max(h, mn[1] * k), (mx[1] if mx[1] < 1e30 else math.inf) * k)
    return w, h


def padding_of(node, w, h, k):
    pad = modifier(node, "UIPadding")
    if not pad:
        return 0, 0, 0, 0
    p = pad["pad"]
    top = h * p[0] + p[1] * k
    bottom = h * p[2] + p[3] * k
    left = w * p[4] + p[5] * k
    right = w * p[6] + p[7] * k
    return top, bottom, left, right


RESPONSIVE_MIN, RESPONSIVE_MAX, REFERENCE = 0.62, 1.55, (1280, 720)  # keep in sync with Responsive.luau


def responsive_override(node, pw, ph):
    """Responsive.root frames are recomputed for the render size (the export ran at 1280x720)."""
    scale_mod = modifier(node, "UIScale")
    if not scale_mod or scale_mod.get("name") != "ResponsiveScale":
        return node
    s = min(pw / REFERENCE[0], ph / REFERENCE[1])
    s = min(max(s, RESPONSIVE_MIN), RESPONSIVE_MAX)
    patched = dict(node)
    patched["size"] = [1 / s, 0, 1 / s, 0]
    children = []
    for c in node.get("children", []):
        if c is scale_mod:
            c = dict(c)
            c["scale"] = s
        children.append(c)
    patched["children"] = children
    return patched


def layout(node, px, py, pw, ph, k, list_slot=None):
    """Lay out `node` inside parent content rect (px, py, pw, ph). Returns Box."""
    node = responsive_override(node, pw, ph)
    w, h = resolve_size(node, pw, ph, k)
    w, h = apply_constraints(node, w, h, k)
    auto = node.get("auto", "None")
    if list_slot is None:
        pos = node.get("position", [0, 0, 0, 0])
        ax, ay = node.get("anchor", [0, 0])

        def place(w, h):
            return px + pw * pos[0] + pos[1] * k - ax * w, py + ph * pos[2] + pos[3] * k - ay * h

        x, y = place(w, h)
    else:
        x, y = list_slot(w, h)
        place = None

    scale_mod = modifier(node, "UIScale")
    s = scale_mod.get("scale", 1) if scale_mod else 1

    def build(w, h, x, y):
        if s != 1:
            ax, ay = node.get("anchor", [0, 0])
            cx, cy = x + ax * w, y + ay * h
            sw, sh = w * s, h * s
            bx, by = cx - ax * sw, cy - ay * sh
            box = Box(node, bx, by, sw, sh, k * s)
        else:
            box = Box(node, x, y, w, h, k)
        layout_children(box)
        return box

    box = build(w, h, x, y)
    if auto != "None":
        # Grow to fit content (Size acts as a minimum), then lay out again.
        top, bottom, left, right = padding_of(node, box.w, box.h, box.k)
        cw, ch = box.content if box.content else content_extent(box)
        tw, th = 0, 0
        if is_text(node):
            max_w = None
            if auto == "Y":
                max_w = box.w - left - right
            tw, th = measure_text(node, box.k, max_w)
        need_w = max(cw, tw) + left + right
        need_h = max(ch, th) + top + bottom
        nw = max(w, need_w / s) if auto in ("X", "XY") else w
        nh = max(h, need_h / s) if auto in ("Y", "XY") else h
        if abs(nw - w) > 0.5 or abs(nh - h) > 0.5:
            if list_slot is None:
                x, y = place(nw, nh)
            else:
                x, y = list_slot(nw, nh)
            box = build(nw, nh, x, y)
    return box


def content_extent(box):
    """Size of the children's bounding box, measured from the content origin."""
    node = box.node
    top, bottom, left, right = padding_of(node, box.w, box.h, box.k)
    ox, oy = box.x + left, box.y + top
    max_x, max_y = 0.0, 0.0
    for child in box.children:
        if not child.node.get("visible", True):
            continue
        max_x = max(max_x, child.x + child.w - ox)
        max_y = max(max_y, child.y + child.h - oy)
    return max_x, max_y


def layout_children(box):
    node = box.node
    top, bottom, left, right = padding_of(node, box.w, box.h, box.k)
    cx, cy = box.x + left, box.y + top
    cw, ch = max(0.0, box.w - left - right), max(0.0, box.h - top - bottom)
    if node["class"] == "ScrollingFrame":
        cpos = node.get("canvasPosition", [0, 0])
        cx -= cpos[0] * box.k
        cy -= cpos[1] * box.k
    kids = [c for c in gui_children(node)]
    list_layout = modifier(node, "UIListLayout")
    grid_layout = modifier(node, "UIGridLayout")
    if list_layout or grid_layout:
        flow = [c for c in kids if c.get("visible", True)]
        flow.sort(key=lambda c: (c.get("order", 0)))
        others = []
    else:
        flow = []
        others = kids
    if list_layout:
        vertical = list_layout.get("fill", "Vertical") == "Vertical"
        pad_s, pad_o = list_layout.get("padding", [0, 0])
        gap = (ch if vertical else cw) * pad_s + pad_o * box.k
        # First pass: sizes.
        sizes = []
        for c in flow:
            probe = layout(c, cx, cy, cw, ch, box.k, list_slot=lambda w, h: (0, 0))
            sizes.append((probe.w, probe.h))
        total = sum((s[1] if vertical else s[0]) for s in sizes) + gap * max(0, len(flow) - 1)
        cross = max([(s[0] if vertical else s[1]) for s in sizes] or [0])
        box.content = (cross, total) if vertical else (total, cross)
        h_align = list_layout.get("hAlign", "Left")
        v_align = list_layout.get("vAlign", "Top")
        if not vertical and list_layout.get("wraps"):
            # Wraps: break into lines that fit the width; lines stack with the same padding.
            lines, line, line_w, line_h = [], [], 0.0, 0.0
            for i, (w0, h0) in enumerate(sizes):
                add = w0 if not line else gap + w0
                if line and line_w + add > cw + 0.5:
                    lines.append((line, line_w, line_h))
                    line, line_w, line_h, add = [], 0.0, 0.0, w0
                line.append(i)
                line_w += add
                line_h = max(line_h, h0)
            if line:
                lines.append((line, line_w, line_h))
            total_h = sum(entry[2] for entry in lines) + gap * max(0, len(lines) - 1)
            box.content = (max([entry[1] for entry in lines] or [0]), total_h)
            y = cy + (0 if v_align == "Top" else (ch - total_h) / 2 if v_align == "Center" else ch - total_h)
            for indices, lw, lh in lines:
                x = cx + (0 if h_align == "Left" else (cw - lw) / 2 if h_align == "Center" else cw - lw)
                for i in indices:
                    def slot(w, h, x=x, y=y, lh=lh):
                        return x, y + (0 if v_align == "Top" else (lh - h) / 2 if v_align == "Center" else lh - h)

                    child = layout(flow[i], cx, cy, cw, ch, box.k, list_slot=slot)
                    box.children.append(child)
                    x += child.w + gap
                y += lh + gap
            flow = []
        if vertical:
            start = cy + (0 if v_align == "Top" else (ch - total) / 2 if v_align == "Center" else ch - total)
        else:
            start = cx + (0 if h_align == "Left" else (cw - total) / 2 if h_align == "Center" else cw - total)
        cursor = start
        for c, (w0, h0) in zip(flow, sizes):
            if vertical:
                def slot(w, h, cursor=cursor):
                    x = cx + (0 if h_align == "Left" else (cw - w) / 2 if h_align == "Center" else cw - w)
                    return x, cursor

                child = layout(c, cx, cy, cw, ch, box.k, list_slot=slot)
                cursor += child.h + gap
            else:
                def slot(w, h, cursor=cursor):
                    y = cy + (0 if v_align == "Top" else (ch - h) / 2 if v_align == "Center" else ch - h)
                    return cursor, y

                child = layout(c, cx, cy, cw, ch, box.k, list_slot=slot)
                cursor += child.w + gap
            box.children.append(child)
    elif grid_layout:
        cs = grid_layout.get("cellSize", [0, 100, 0, 100])
        cp = grid_layout.get("cellPadding", [0, 5, 0, 5])
        cell_w, cell_h = cw * cs[0] + cs[1] * box.k, ch * cs[2] + cs[3] * box.k
        gap_x, gap_y = cw * cp[0] + cp[1] * box.k, ch * cp[2] + cp[3] * box.k
        per_row = max(1, int((cw + gap_x) // max(1, cell_w + gap_x)))
        for i, c in enumerate(flow):
            row, col = divmod(i, per_row)

            def slot(w, h, row=row, col=col):
                return cx + col * (cell_w + gap_x), cy + row * (cell_h + gap_y)

            fake = dict(c)
            fake["size"] = [0, cell_w / box.k, 0, cell_h / box.k]
            box.children.append(layout(fake, cx, cy, cw, ch, box.k, list_slot=slot))
    for c in others:
        box.children.append(layout(c, cx, cy, cw, ch, box.k))
    if node.get("clip") or node["class"] == "ScrollingFrame":
        box.clip = (box.x, box.y, box.w, box.h)


# ---------------------------------------------------------------------------------------------------------
# Drawing


def corner_radius(box):
    corner = modifier(box.node, "UICorner")
    if not corner:
        return 0
    s, o = corner.get("radius", [0, 8])
    r = min(box.w, box.h) * s + o * box.k
    return max(0, min(r, min(box.w, box.h) / 2))


def gradient_layer(box, base_rgba, gradient):
    w, h = max(1, int(math.ceil(box.w))), max(1, int(math.ceil(box.h)))
    img = Image.new("RGBA", (w, h))
    px = img.load()
    rot = math.radians(gradient.get("rotation", 0))
    dx, dy = math.cos(rot), math.sin(rot)
    colors = gradient.get("color")
    trans = gradient.get("transparency")
    # Project each pixel on the gradient axis (centre-based, normalised to [0, 1]).
    half = abs(dx) * w / 2 + abs(dy) * h / 2
    step = max(1, int(max(w, h) / 256))
    for yy in range(0, h, step):
        for xx in range(0, w, step):
            t = ((xx - w / 2) * dx + (yy - h / 2) * dy) / max(half * 2, 1e-6) + 0.5
            t = min(1, max(0, t))
            c = sample_sequence(colors, t) if colors else [1, 1, 1]
            a = sample_sequence(trans, t)[0] if trans else 0
            r = int(base_rgba[0] * c[0])
            g = int(base_rgba[1] * c[1])
            b = int(base_rgba[2] * c[2])
            alpha = int(base_rgba[3] * (1 - a))
            for sy in range(yy, min(h, yy + step)):
                for sx in range(xx, min(w, xx + step)):
                    px[sx, sy] = (r, g, b, alpha)
    return img


def rounded_mask(w, h, r, supersample=3):
    W, H = max(1, int(math.ceil(w))) * supersample, max(1, int(math.ceil(h))) * supersample
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=int(r * supersample), fill=255)
    return mask.resize((max(1, int(math.ceil(w))), max(1, int(math.ceil(h)))), Image.LANCZOS)


def draw_background(canvas, box):
    node = box.node
    bgt = node.get("bgt", 1)
    if bgt >= 0.999 or box.w < 0.5 or box.h < 0.5:
        return
    color = rgba(node.get("bg", [1, 1, 1]), bgt)
    gradient = modifier(node, "UIGradient")
    r = corner_radius(box)
    w, h = max(1, int(math.ceil(box.w))), max(1, int(math.ceil(box.h)))
    if gradient and gradient.get("enabled", True):
        layer = gradient_layer(box, color, gradient)
    else:
        layer = Image.new("RGBA", (w, h), color)
    mask = rounded_mask(box.w, box.h, r)
    alpha = Image.composite(layer.getchannel("A"), Image.new("L", (w, h), 0), mask)
    layer.putalpha(alpha)
    if abs(box.rotation) > 0.5:
        layer = layer.rotate(-box.rotation, resample=Image.BICUBIC, expand=True)
        cx, cy = box.x + box.w / 2, box.y + box.h / 2
        canvas.alpha_composite(layer, (int(round(cx - layer.width / 2)), int(round(cy - layer.height / 2))))
    else:
        canvas.alpha_composite(layer, (int(round(box.x)), int(round(box.y))))


def draw_border(canvas, box):
    node = box.node
    stroke = modifier(node, "UIStroke")
    if not stroke or not stroke.get("enabled", True):
        return
    if stroke.get("mode") == "Contextual" and is_text(node):
        return
    if stroke.get("transparency", 0) >= 0.999:
        return
    t = stroke.get("thickness", 1) * box.k
    if t <= 0:
        return
    r = corner_radius(box)
    pad = int(math.ceil(t)) + 2
    w, h = int(math.ceil(box.w)) + pad * 2, int(math.ceil(box.h)) + pad * 2
    ss = 3
    layer = Image.new("RGBA", (w * ss, h * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    color = rgba(stroke.get("color", [0, 0, 0]), stroke.get("transparency", 0))
    x0, y0 = (pad - t / 2) * ss, (pad - t / 2) * ss
    x1, y1 = (pad + box.w + t / 2) * ss, (pad + box.h + t / 2) * ss
    d.rounded_rectangle([x0, y0, x1, y1], radius=int((r + t / 2) * ss), outline=color, width=max(1, int(t * ss)))
    layer = layer.resize((w, h), Image.LANCZOS)
    if abs(box.rotation) > 0.5:
        layer = layer.rotate(-box.rotation, resample=Image.BICUBIC, expand=True)
        cx, cy = box.x + box.w / 2, box.y + box.h / 2
        canvas.alpha_composite(layer, (int(round(cx - layer.width / 2)), int(round(cy - layer.height / 2))))
    else:
        canvas.alpha_composite(layer, (int(round(box.x - pad)), int(round(box.y - pad))))


def draw_text(canvas, box):
    node = box.node
    text = strip_rich(node.get("text") or "")
    if text == "" or node.get("textT", 0) >= 0.999:
        return
    k = box.k
    size = node.get("textSize", 14) * k
    tsc = modifier(node, "UITextSizeConstraint")
    if node.get("scaled"):
        hi = (tsc["max"] if tsc else 100) * k
        lo = (tsc["min"] if tsc else 1) * k
        size = hi
        while size > lo:
            font = font_for(node.get("font"), node.get("weight"), size)
            lines = wrap_lines(text, font, box.w if node.get("wrapped") else None)
            asc, desc = font.getmetrics()
            if max(font.getlength(l) for l in lines) <= box.w and (asc + desc) * len(lines) <= box.h:
                break
            size -= max(1, size * 0.06)
    font = font_for(node.get("font"), node.get("weight"), size)
    lines = wrap_lines(text, font, box.w if node.get("wrapped") else None)
    asc, desc = font.getmetrics()
    line_h = asc + desc
    if node.get("truncate", "None") != "None":
        lines = truncate_lines(lines, font, box.w, max(1, int(box.h // line_h)))
    total_h = line_h * len(lines)
    ya = node.get("yAlign", "Center")
    y = box.y + (0 if ya == "Top" else (box.h - total_h) / 2 if ya == "Center" else box.h - total_h)
    xa = node.get("xAlign", "Center")
    color = rgba(node.get("textColor", [0, 0, 0]), node.get("textT", 0))
    stroke = modifier(node, "UIStroke")
    stroke_w = 0
    stroke_color = None
    if stroke and stroke.get("enabled", True) and stroke.get("mode", "Contextual") == "Contextual" and stroke.get(
        "transparency", 0
    ) < 0.999:
        stroke_w = max(1, int(round(stroke.get("thickness", 1) * k)))
        stroke_color = rgba(stroke.get("color", [0, 0, 0]), stroke.get("transparency", 0))
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for line in lines:
        lw = font.getlength(line)
        x = box.x + (0 if xa == "Left" else (box.w - lw) / 2 if xa == "Center" else box.w - lw)
        if stroke_color:
            d.text((x, y), line, font=font, fill=color, stroke_width=stroke_w, stroke_fill=stroke_color)
        else:
            d.text((x, y), line, font=font, fill=color)
        y += line_h
    canvas.alpha_composite(layer)


def draw_image(canvas, box):
    node = box.node
    if not node.get("image") or node.get("imageT", 0) >= 0.999:
        return
    d = ImageDraw.Draw(canvas)
    r = corner_radius(box)
    d.rounded_rectangle(
        [box.x, box.y, box.x + box.w, box.y + box.h], radius=int(r), fill=(150, 150, 170, 200), outline=(90, 90, 110, 255)
    )


def draw_box(canvas, box):
    node = box.node
    if not node.get("visible", True):
        return
    if box.clip:
        x, y, w, h = box.clip
        layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        draw_self(layer, box)
        for child in sorted(box.children, key=lambda c: c.node.get("z", 1)):
            draw_box(layer, child)
        mask = Image.new("L", canvas.size, 0)
        ImageDraw.Draw(mask).rectangle([x, y, x + w, y + h], fill=255)
        clipped = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        clipped.paste(layer, (0, 0), mask)
        canvas.alpha_composite(clipped)
        return
    draw_self(canvas, box)
    for child in sorted(box.children, key=lambda c: c.node.get("z", 1)):
        draw_box(canvas, child)


def draw_self(canvas, box):
    draw_background(canvas, box)
    if box.node["class"] in ("ImageLabel", "ImageButton"):
        draw_image(canvas, box)
    draw_border(canvas, box)
    if is_text(box.node):
        draw_text(canvas, box)


# ---------------------------------------------------------------------------------------------------------


# ---------------------------------------------------------------------------------------------------------
# Touch controls: Roblox's TouchGui (simulated by the client harness on touch phones) is drawn as the player
# sees it, and every HUD element that covers the thumbstick zone or the jump button is reported.

TOUCH_MARGIN = 6  # px a HUD element may come to the controls before it counts as covering them
TOUCH_CHECKED = ("RN_Hud", "RN_Overlay")


def find_box(box, name):
    if box.node.get("name") == name:
        return box
    for child in box.children:
        found = find_box(child, name)
        if found:
            return found
    return None


def has_content(node):
    cls = node["class"]
    if cls in ("Frame", "TextLabel", "TextButton", "TextBox", "ImageLabel", "ImageButton", "ScrollingFrame"):
        if node.get("bgt", 1) < 0.98:
            return True
    if is_text(node) and (node.get("text") or "") != "" and node.get("textT", 0) < 0.98:
        return True
    if cls in ("ImageLabel", "ImageButton") and node.get("image") and node.get("imageT", 0) < 0.98:
        return True
    stroke = modifier(node, "UIStroke")
    if stroke and stroke.get("enabled", True) and stroke.get("transparency", 0) < 0.98:
        return True
    return False


def content_rects(box, path, clip, out):
    node = box.node
    if not node.get("visible", True):
        return
    name = node.get("name", node["class"])
    path = path + "/" + name
    x0, y0, x1, y1 = box.x, box.y, box.x + box.w, box.y + box.h
    if clip:
        cx0, cy0, cx1, cy1 = clip
        x0, y0, x1, y1 = max(x0, cx0), max(y0, cy0), min(x1, cx1), min(y1, cy1)
    if x1 - x0 > 0.5 and y1 - y0 > 0.5 and has_content(node):
        out.append((path, (x0, y0, x1, y1)))
    child_clip = clip
    if box.clip:
        bx, by, bw, bh = box.clip
        child_clip = (bx, by, bx + bw, by + bh)
        if clip:
            child_clip = (max(child_clip[0], clip[0]), max(child_clip[1], clip[1]),
                          min(child_clip[2], clip[2]), min(child_clip[3], clip[3]))
    for child in box.children:
        content_rects(child, path, child_clip, out)


def overlaps(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def touch_zones(roots, width):
    """(stick, jump) rects from the TouchGui boxes, or None without touch controls."""
    touch = roots.get("TouchGui")
    if not touch:
        return None
    jump = stick = None
    for child in touch.children:
        jump = jump or find_box(child, "JumpButton")
        stick = stick or find_box(child, "DynamicThumbstickFrame") or find_box(child, "ThumbstickFrame")
    if not jump or not stick:
        return None
    m = TOUCH_MARGIN
    stick_rect = (max(stick.x, 0) - m, stick.y - m, stick.x + stick.w + m, stick.y + stick.h + m)
    jump_rect = (jump.x - m, jump.y - m, jump.x + jump.w + m, jump.y + jump.h + m)
    return {"stick": stick_rect, "jump": jump_rect, "jumpBox": jump, "stickBox": stick}


def draw_touch(canvas, zones, height):
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    stick = zones["stickBox"]
    x0, y0 = max(stick.x, 0), stick.y
    d.rectangle([x0, y0, stick.x + stick.w, min(stick.y + stick.h, height)], fill=(255, 255, 255, 18),
                outline=(255, 255, 255, 70))
    # Resting thumbstick ring (DynamicThumbstick startImage: 3.3 / 2.8 ring sizes in from the frame corner).
    cx, cy, r = stick.x + 100 + 66, min(stick.y + stick.h, height + 100) - 100 - 56, 37
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255, 170), width=3)
    d.ellipse([cx - 16, cy - 16, cx + 16, cy + 16], fill=(255, 255, 255, 120))
    jump = zones["jumpBox"]
    d.ellipse([jump.x, jump.y, jump.x + jump.w, jump.y + jump.h], fill=(255, 255, 255, 60),
              outline=(255, 255, 255, 200), width=3)
    font = font_for("BuilderSans", "Bold", max(10, int(jump.w * 0.2)))
    d.text((jump.x + jump.w / 2, jump.y + jump.h / 2), "JUMP", font=font, fill=(255, 255, 255, 230), anchor="mm")
    canvas.alpha_composite(layer)


def check_touch(roots, zones):
    problems = []
    for gui_name in TOUCH_CHECKED:
        root = roots.get(gui_name)
        if not root:
            continue
        rects = []
        for child in root.children:
            content_rects(child, gui_name, None, rects)
        for path, rect in rects:
            for zone in ("stick", "jump"):
                # Report the outermost covering element only (its children sit inside it).
                if overlaps(rect, zones[zone]) and not any(
                    z == zone and path.startswith(p + "/") for z, p, _ in problems
                ):
                    problems.append((zone, path, rect))
    for zone, path, rect in problems:
        print("WARNING touch overlap (%s): %s [%d,%d - %d,%d]" % (zone, path, rect[0], rect[1], rect[2], rect[3]))
    print("touch zones: %d overlap(s)" % len(problems))
    return problems


def render(data, width, height, inset, background, touch=False):
    canvas = Image.new("RGBA", (width, height), background)
    guis = [g for g in data["guis"] if g.get("enabled", True)]
    guis.sort(key=lambda g: g.get("order", 0))
    roots = {}
    for gui in guis:
        top = inset if gui.get("insets") in ("CoreUISafeInsets",) else 0
        root = Box(gui, 0, top, width, height - top, 1)
        roots[gui.get("name", "")] = root
        for child in gui_children(gui):
            root.children.append(layout(child, 0, top, width, height - top, 1))
        if gui.get("name") == "TouchGui":
            continue
        for child in sorted(root.children, key=lambda c: c.node.get("z", 1)):
            draw_box(canvas, child)
    if touch:
        zones = touch_zones(roots, width)
        if zones:
            draw_touch(canvas, zones, height)
            check_touch(roots, zones)
        else:
            print("WARNING touch: no TouchGui in the export")
    return canvas


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("json")
    parser.add_argument("out")
    parser.add_argument("--size", default="1280x720")
    parser.add_argument("--inset", type=int, default=None)
    parser.add_argument("--bg", default="38,44,58")
    parser.add_argument("--touch", action="store_true", help="draw the touch controls and report HUD overlaps")
    args = parser.parse_args()
    width, height = (int(v) for v in args.size.lower().split("x"))
    inset = args.inset if args.inset is not None else (58 if height >= 600 else 44)
    with open(args.json) as f:
        data = json.load(f)
    bg = tuple(int(v) for v in args.bg.split(",")) + (255,)
    image = render(data, width, height, inset, bg, args.touch)
    image.convert("RGB").save(args.out)
    print("wrote", args.out)


if __name__ == "__main__":
    sys.exit(main())
