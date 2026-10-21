#!/usr/bin/env python3
"""
scout: find free Creator Store assets for the asset library (A10 provenance starts here).

  python3 tools/assets/scout.py <out_dir> <query> [<query> ...] [--type Model|MeshPart|Decal]
                                [--pages N] [--max-tris N] [--max-parts N] [--allow-scripts] [--per-sheet N]

For every query it pages through the Creator Store search (public toolbox API, no login), keeps free assets
that pass the filters (triangle budget, part count, no scripts or audio unless allowed), downloads their
420x420 thumbnails and writes:
  <out_dir>/candidates.json   one record per asset: id, name, creator, verified, triangles, counts, votes
  <out_dir>/sheet_<n>.png     numbered contact sheets (index, id, triangles, mesh parts) for review
Thumbnails are cached in <out_dir>/thumbs. Only metadata and thumbnails are fetched; assets themselves load
in game through AssetService:LoadAssetAsync.
"""
import argparse
import io
import json
import os
import sys
import time
import urllib.parse
import urllib.request

from PIL import Image, ImageDraw, ImageFont

SEARCH = "https://apis.roblox.com/toolbox-service/v2/assets:search"
THUMBS = "https://thumbnails.roblox.com/v1/assets"
FONT = "/usr/share/fonts/opentype/inter/Inter-Bold.otf"


def get_json(url, tries=4):
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001 - network hiccups are retried
            if attempt == tries - 1:
                print("failed", url, e, file=sys.stderr)
                return None
            time.sleep(1.5 * (attempt + 1))


def get_bytes(url, tries=3):
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return r.read()
        except Exception:  # noqa: BLE001
            time.sleep(1 + attempt)
    return None


def search(query, kind, pages):
    out, token = [], None
    for _ in range(pages):
        params = {"searchCategoryType": kind, "query": query, "maxPageSize": 100}
        if token:
            params["pageToken"] = token
        data = get_json(SEARCH + "?" + urllib.parse.urlencode(params))
        if not data:
            break
        out.extend(data.get("creatorStoreAssets", []))
        token = data.get("nextPageToken")
        if not token:
            break
    return out


def record(entry, query):
    a, c, v = entry["asset"], entry.get("creator", {}), entry.get("voting", {})
    counts = a.get("instanceCounts", {}) or {}
    price = (entry.get("creatorStoreProduct") or {}).get("purchasePrice", {}).get("quantity", {})
    return {
        "id": a["id"],
        "name": a.get("name", ""),
        "type": a.get("assetTypeId"),
        "query": query,
        "creator": c.get("name", ""),
        "creatorRef": c.get("creator", ""),
        "verified": bool(c.get("verified")),
        "triangles": (a.get("objectMeshSummary") or {}).get("triangles"),
        "scripts": a.get("scriptCount") or 0,
        "meshParts": counts.get("meshPart"),
        "audio": counts.get("audio") or 0,
        "animations": counts.get("animation") or 0,
        "decals": counts.get("decal") or 0,
        "up": v.get("upVotes", 0),
        "down": v.get("downVotes", 0),
        "free": (price.get("significand", 0) or 0) == 0,
        "category": a.get("categoryPath", ""),
        "created": a.get("createTime", ""),
    }


def thumbnails(ids, cache):
    os.makedirs(cache, exist_ok=True)
    missing = [i for i in ids if not os.path.exists(os.path.join(cache, f"{i}.png"))]
    for start in range(0, len(missing), 100):
        chunk = missing[start:start + 100]
        url = THUMBS + "?" + urllib.parse.urlencode(
            {"assetIds": ",".join(str(i) for i in chunk), "size": "420x420", "format": "Png"})
        data = get_json(url) or {}
        for item in data.get("data", []):
            if item.get("state") == "Completed" and item.get("imageUrl"):
                raw = get_bytes(item["imageUrl"])
                if raw:
                    with open(os.path.join(cache, f"{item['targetId']}.png"), "wb") as f:
                        f.write(raw)


def sheets(records, out_dir, cache, per_sheet, cols=5, cell=220):
    font = ImageFont.truetype(FONT, 13) if os.path.exists(FONT) else ImageFont.load_default()
    small = ImageFont.truetype(FONT, 11) if os.path.exists(FONT) else ImageFont.load_default()
    paths = []
    for n, start in enumerate(range(0, len(records), per_sheet)):
        chunk = records[start:start + per_sheet]
        rows = (len(chunk) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * cell, rows * (cell + 34)), (40, 40, 48))
        d = ImageDraw.Draw(sheet)
        for k, r in enumerate(chunk):
            x, y = (k % cols) * cell, (k // cols) * (cell + 34)
            path = os.path.join(cache, f"{r['id']}.png")
            if os.path.exists(path):
                try:
                    img = Image.open(path).convert("RGBA").resize((cell - 8, cell - 8))
                    bg = Image.new("RGBA", img.size, (90, 90, 100, 255))
                    bg.alpha_composite(img)
                    sheet.paste(bg.convert("RGB"), (x + 4, y + 4))
                except Exception:  # noqa: BLE001
                    pass
            r["index"] = start + k
            d.text((x + 6, y + 6), str(start + k), font=font, fill=(255, 230, 120), stroke_width=2,
                   stroke_fill=(0, 0, 0))
            label = f"{r['id']} {r['triangles'] if r['triangles'] is not None else '?'}t"
            d.text((x + 4, y + cell - 2), label, font=small, fill=(230, 230, 230))
            d.text((x + 4, y + cell + 12), (r["name"] or "")[:30], font=small, fill=(170, 200, 255))
        path = os.path.join(out_dir, f"sheet_{n}.png")
        sheet.save(path)
        paths.append(path)
    return paths


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("queries", nargs="+")
    p.add_argument("--type", default="Model")
    p.add_argument("--pages", type=int, default=1)
    p.add_argument("--max-tris", type=int, default=20000)
    p.add_argument("--max-parts", type=int, default=60)
    p.add_argument("--allow-scripts", action="store_true")
    p.add_argument("--per-sheet", type=int, default=25)
    p.add_argument("--limit", type=int, default=60)
    a = p.parse_args()
    os.makedirs(a.out, exist_ok=True)
    seen, kept = set(), []
    for q in a.queries:
        for entry in search(q, a.type, a.pages):
            r = record(entry, q)
            if r["id"] in seen or not r["free"]:
                continue
            seen.add(r["id"])
            if a.type == "Model":
                if r["scripts"] and not a.allow_scripts:
                    continue
                if r["audio"]:
                    continue
                if r["triangles"] is not None and r["triangles"] > a.max_tris:
                    continue
                if r["meshParts"] is not None and r["meshParts"] > a.max_parts:
                    continue
            kept.append(r)
    kept = kept[: a.limit]
    cache = os.path.join(os.path.dirname(os.path.abspath(a.out)), "thumbs")
    thumbnails([r["id"] for r in kept], cache)
    paths = sheets(kept, a.out, cache, a.per_sheet)
    with open(os.path.join(a.out, "candidates.json"), "w") as f:
        json.dump(kept, f, indent=1)
    print(f"{len(kept)} candidates; sheets: {' '.join(paths)}")


if __name__ == "__main__":
    sys.exit(main())
