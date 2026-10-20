#!/usr/bin/env python3
"""Software rasteriser for exported ROOMNAPPED geometry (offline visual QA).

Usage:
  python3 tools/preview/render.py scene.json out_prefix [--views N] [--size WxH]

Renders a top-down overview (ceilings hidden) plus eye-level walkthrough views along the route, using a
z-buffer rasteriser with per-triangle lighting from the scene's point lights. It approximates Roblox's
look closely enough to catch layout, scale, clipping and readability problems without Studio.
"""
import json
import math
import sys

import numpy as np
from PIL import Image

HIDE_TOP = {"Ceiling", "Crown", "Rose", "Rod", "Shade", "Bulb", "CarCeiling", "AlcoveCeiling", "RoomLight", "RoofPane",
            "Chain", "Ring", "Candle", "Flame", "Crystal", "Lintel"}

MATERIAL_TINT = {
    "Neon": "emissive",
    "Glass": "glass",
    "Ice": "glass",
}


def rotation(cf):
    x, y, z = cf[0:3]
    r = np.array(cf[3:12], dtype=np.float64).reshape(3, 3)
    return np.array([x, y, z], dtype=np.float64), r


def box_mesh(sx, sy, sz):
    hx, hy, hz = sx / 2, sy / 2, sz / 2
    v = np.array([[-hx, -hy, -hz], [hx, -hy, -hz], [hx, hy, -hz], [-hx, hy, -hz],
                  [-hx, -hy, hz], [hx, -hy, hz], [hx, hy, hz], [-hx, hy, hz]])
    f = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
         (3, 7, 6), (3, 6, 2), (0, 4, 7), (0, 7, 3), (1, 2, 6), (1, 6, 5)]
    return v, f


def wedge_mesh(sx, sy, sz):
    # Roblox wedge: full bottom, full back face (+Z), slope descending to the front (-Z) bottom edge.
    hx, hy, hz = sx / 2, sy / 2, sz / 2
    v = np.array([[-hx, -hy, -hz], [hx, -hy, -hz], [hx, -hy, hz], [-hx, -hy, hz],
                  [-hx, hy, hz], [hx, hy, hz]])
    f = [(0, 1, 2), (0, 2, 3),  # bottom
         (3, 2, 5), (3, 5, 4),  # back
         (0, 4, 5), (0, 5, 1),  # slope
         (0, 3, 4), (1, 5, 2)]  # sides
    return v, f


def cylinder_mesh(sx, sy, sz, seg=14):
    r = min(sy, sz) / 2
    hx = sx / 2
    verts = []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        verts.append([-hx, math.cos(a) * r, math.sin(a) * r])
        verts.append([hx, math.cos(a) * r, math.sin(a) * r])
    verts.append([-hx, 0, 0])
    verts.append([hx, 0, 0])
    c0, c1 = 2 * seg, 2 * seg + 1
    f = []
    for i in range(seg):
        j = (i + 1) % seg
        a0, a1, b0, b1 = 2 * i, 2 * i + 1, 2 * j, 2 * j + 1
        f.append((a0, b0, b1))
        f.append((a0, b1, a1))
        f.append((c0, b0, a0))
        f.append((c1, a1, b1))
    return np.array(verts), f


def ball_mesh(sx, sy, sz, rings=7, seg=12):
    r = min(sx, sy, sz) / 2
    verts = []
    for i in range(rings + 1):
        phi = math.pi * i / rings
        for j in range(seg):
            th = 2 * math.pi * j / seg
            verts.append([r * math.sin(phi) * math.cos(th), r * math.cos(phi), r * math.sin(phi) * math.sin(th)])
    f = []
    for i in range(rings):
        for j in range(seg):
            a = i * seg + j
            b = i * seg + (j + 1) % seg
            c = (i + 1) * seg + j
            d = (i + 1) * seg + (j + 1) % seg
            f.append((a, c, b))
            f.append((b, c, d))
    return np.array(verts), f


def triangles_for(part, hide):
    if part["t"] >= 0.95:
        return []
    if hide and part["n"] in hide:
        return []
    sx, sy, sz = part["sz"]
    shape = part["s"]
    if shape == "Wedge" or shape == "CornerWedge":
        v, f = wedge_mesh(sx, sy, sz)
    elif shape == "Cylinder":
        v, f = cylinder_mesh(sx, sy, sz)
    elif shape == "Ball":
        v, f = ball_mesh(sx, sy, sz)
    else:
        v, f = box_mesh(sx, sy, sz)
    p, r = rotation(part["cf"])
    world = v @ r.T + p
    out = []
    for (a, b, c) in f:
        out.append((world[a], world[b], world[c]))
    return out


class Camera:
    def __init__(self, pos, target, fov, w, h):
        self.pos = np.array(pos, dtype=np.float64)
        fwd = np.array(target, dtype=np.float64) - self.pos
        fwd /= np.linalg.norm(fwd)
        up = np.array([0, 1, 0], dtype=np.float64)
        if abs(np.dot(fwd, up)) > 0.98:
            up = np.array([0, 0, -1], dtype=np.float64)
        right = np.cross(fwd, up)
        right /= np.linalg.norm(right)
        cup = np.cross(right, fwd)
        self.f, self.r, self.u = fwd, right, cup
        self.w, self.h = w, h
        self.fpx = (w / 2) / math.tan(math.radians(fov) / 2)

    def to_cam(self, p):
        d = p - self.pos
        return np.array([d @ self.r, d @ self.u, d @ self.f])


NEAR = 0.15


def clip_near(tri):
    inside = [v for v in tri if v[2] >= NEAR]
    if len(inside) == 3:
        return [tri]
    if len(inside) == 0:
        return []
    out_poly = []
    for i in range(3):
        a, b = tri[i], tri[(i + 1) % 3]
        ain, bin_ = a[2] >= NEAR, b[2] >= NEAR
        if ain:
            out_poly.append(a)
        if ain != bin_:
            t = (NEAR - a[2]) / (b[2] - a[2])
            out_poly.append(a + (b - a) * t)
    tris = []
    for i in range(1, len(out_poly) - 1):
        tris.append([out_poly[0], out_poly[i], out_poly[i + 1]])
    return tris


def shade(part, normal, centroid, lights, cam_pos, sun):
    base = np.array(part["c"], dtype=np.float64)
    mat = part["m"]
    if mat == "Neon":
        return np.clip(base * 1.25 + 0.15, 0, 1)
    n = normal
    view = cam_pos - centroid
    if np.dot(n, view) < 0:
        n = -n
    light = np.full(3, 0.20)
    light += 0.30 * max(0.0, float(np.dot(n, sun)))
    for (lp, lc, lr, lb) in lights:
        d = lp - centroid
        dist = np.linalg.norm(d)
        if dist > lr or dist < 1e-6:
            continue
        ndl = max(0.0, float(np.dot(n, d / dist)))
        fall = (1 - dist / lr) ** 1.6
        light += lc * lb * ndl * fall * 0.9
    col = base * np.clip(light, 0, 2.2)
    if mat in ("Metal", "Foil", "DiamondPlate", "Marble", "Glass", "Ice"):
        col = col * 0.9 + 0.06
    return np.clip(col, 0, 1)


def render(scene, cam, hide, fog=(0.05, 0.04, 0.06), fog_end=260.0):
    w, h = cam.w, cam.h
    depth = np.full((h, w), np.inf)
    img = np.zeros((h, w, 3))
    img[:] = np.array(fog)
    lights = [(np.array(l["p"]), np.array(l["c"]), float(l["r"]), float(l["b"])) for l in scene.get("lights", [])]
    sun = np.array([0.3, 0.9, 0.2])
    sun /= np.linalg.norm(sun)
    transparent = []
    xs = np.arange(w) + 0.5
    ys = np.arange(h) + 0.5
    for part in scene["parts"]:
        tris = triangles_for(part, hide)
        if not tris:
            continue
        alpha = 1.0
        if part["m"] in ("Glass", "Ice") or part["t"] > 0.05:
            alpha = max(0.15, 1 - part["t"]) if part["m"] not in ("Glass", "Ice") else min(0.55, max(0.2, 1 - part["t"]))
        for tri in tris:
            a, b, c = tri
            normal = np.cross(b - a, c - a)
            nl = np.linalg.norm(normal)
            if nl < 1e-9:
                continue
            normal /= nl
            centroid = (a + b + c) / 3
            if np.linalg.norm(centroid - cam.pos) > fog_end + 30:
                continue
            color = shade(part, normal, centroid, lights, cam.pos, sun)
            ct = [cam.to_cam(a), cam.to_cam(b), cam.to_cam(c)]
            for ctri in clip_near(ct):
                pts = []
                for v in ctri:
                    sx = w / 2 + v[0] / v[2] * cam.fpx
                    sy = h / 2 - v[1] / v[2] * cam.fpx
                    pts.append((sx, sy, 1.0 / v[2]))
                if alpha < 1.0:
                    transparent.append((pts, color, alpha, max(v[2] for v in ctri)))
                    continue
                raster(pts, color, depth, img, xs, ys, fog, fog_end)
    transparent.sort(key=lambda t: -t[3])
    for pts, color, alpha, _ in transparent:
        raster(pts, color, depth, img, xs, ys, fog, fog_end, alpha)
    return img


def raster(pts, color, depth, img, xs, ys, fog, fog_end, alpha=1.0):
    h, w = depth.shape
    (x0, y0, z0), (x1, y1, z1), (x2, y2, z2) = pts
    minx = max(int(math.floor(min(x0, x1, x2))), 0)
    maxx = min(int(math.ceil(max(x0, x1, x2))), w - 1)
    miny = max(int(math.floor(min(y0, y1, y2))), 0)
    maxy = min(int(math.ceil(max(y0, y1, y2))), h - 1)
    if minx > maxx or miny > maxy:
        return
    area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if abs(area) < 1e-9:
        return
    px = xs[minx:maxx + 1][None, :]
    py = ys[miny:maxy + 1][:, None]
    w0 = ((x1 - px) * (y2 - py) - (x2 - px) * (y1 - py)) / area
    w1 = ((x2 - px) * (y0 - py) - (x0 - px) * (y2 - py)) / area
    w2 = 1 - w0 - w1
    mask = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
    if not mask.any():
        return
    invz = w0 * z0 + w1 * z1 + w2 * z2
    z = 1.0 / np.maximum(invz, 1e-9)
    region = depth[miny:maxy + 1, minx:maxx + 1]
    write = mask & (z < region)
    if not write.any():
        return
    fogt = np.clip(z / fog_end, 0, 1)[..., None] ** 1.3
    col = color[None, None, :] * (1 - fogt) + np.array(fog)[None, None, :] * fogt
    target = img[miny:maxy + 1, minx:maxx + 1]
    if alpha >= 1.0:
        region[write] = z[write]
        target[write] = col[write]
    else:
        target[write] = target[write] * (1 - alpha) + col[write] * alpha


def save(img, path):
    arr = (np.clip(img, 0, 1) ** (1 / 1.15) * 255).astype(np.uint8)
    Image.fromarray(arr).save(path)


def main():
    scene_path, out_prefix = sys.argv[1], sys.argv[2]
    views = 4
    w, h = 800, 450
    args = sys.argv[3:]
    for i, a in enumerate(args):
        if a == "--views":
            views = int(args[i + 1])
        if a == "--size":
            w, h = map(int, args[i + 1].split("x"))
    scene = json.load(open(scene_path))
    parts = scene["parts"]
    pts = np.array([p["cf"][0:3] for p in parts])
    lo, hi = pts.min(axis=0), pts.max(axis=0)
    centre = (lo + hi) / 2
    span = max(hi[0] - lo[0], hi[2] - lo[2])
    # Overview from above (ceilings hidden).
    top = Camera([centre[0] + span * 0.18, centre[1] + span * 0.95 + 20, centre[2] + span * 0.42], centre, 55, w, h)
    save(render(scene, top, HIDE_TOP, fog_end=span * 3 + 200), f"{out_prefix}_top.png")
    print("wrote", f"{out_prefix}_top.png")
    tiles = scene.get("tiles")
    if tiles:
        step = max(1, len(tiles) // max(1, views))
        for k, i in enumerate(range(0, len(tiles), step)):
            if k >= views:
                break
            t = tiles[i]
            p = np.array(t["pos"]) + np.array([0, 6.5, 0]) - np.array(t["look"]) * 6
            target = p + np.array(t["look"]) * 20 + np.array([0, -1.5, 0])
            cam = Camera(p, target, 70, w, h)
            save(render(scene, cam, None), f"{out_prefix}_v{k}.png")
            print("wrote", f"{out_prefix}_v{k}.png")
    elif "spawn" in scene:
        s = np.array(scene["spawn"])
        for k, yaw in enumerate([0, 90, 180, 270][:views]):
            a = math.radians(yaw)
            p = s + np.array([0, 4, 0])
            cam = Camera(p, p + np.array([math.sin(a) * 20, -2, math.cos(a) * 20]), 75, w, h)
            save(render(scene, cam, None), f"{out_prefix}_v{k}.png")
            print("wrote", f"{out_prefix}_v{k}.png")
    else:
        cam = Camera([0, 7, 6], [0, 5, -10], 75, w, h)
        save(render(scene, cam, None), f"{out_prefix}_v0.png")
        print("wrote", f"{out_prefix}_v0.png")


if __name__ == "__main__":
    main()
