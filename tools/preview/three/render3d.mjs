#!/usr/bin/env node
// render3d: three.js renders of an exported scene (tools/preview/export.luau) in headless Chromium.
//
//   node tools/preview/three/render3d.mjs <scene.json> <out_prefix> [--views N] [--size WxH] [--tiles 3,7,12]
//                                         [--top] [--at x,y,z:tx,ty,tz]
//
// Eye-level walkthrough views are spread along the route (or placed at --tiles), --top adds an overview with
// ceilings hidden and --at renders explicit camera positions. Roblox Textures/Decals are drawn with their
// asset thumbnails (cached in tools/preview/three/cache). Visual QA only: an approximation of Future
// lighting, close enough to judge composition, lighting, scale and materials.
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const scenePath = args[0], outPrefix = args[1];
if (!scenePath || !outPrefix) {
  console.error("usage: render3d.mjs <scene.json> <out_prefix> [--views N] [--size WxH] [--tiles a,b] [--top] [--at x,y,z:tx,ty,tz]");
  process.exit(1);
}
let views = 4, size = [1280, 720], tiles = null, top = false;
const at = [];
for (let i = 2; i < args.length; i++) {
  if (args[i] === "--views") views = Number(args[++i]);
  else if (args[i] === "--size") size = args[++i].split("x").map(Number);
  else if (args[i] === "--tiles") tiles = args[++i].split(",").map(Number);
  else if (args[i] === "--top") top = true;
  else if (args[i] === "--at") {
    const [p, t] = args[++i].split(":");
    at.push({ pos: p.split(",").map(Number), target: t.split(",").map(Number) });
  }
}
const data = JSON.parse(fs.readFileSync(scenePath, "utf8"));

// Thumbnails for every image the scene references.
const cacheDir = path.join(here, "cache");
fs.mkdirSync(cacheDir, { recursive: true });
const ids = new Set();
for (const p of data.parts) for (const t of p.tex || []) { const m = String(t.id).match(/(\d+)/); if (m) ids.add(m[1]); }
for (const v of Object.values(data.variants || {})) ids.add(String(v.image));
const missing = [...ids].filter(id => !fs.existsSync(path.join(cacheDir, `${id}.png`)));
for (let i = 0; i < missing.length; i += 100) {
  const chunk = missing.slice(i, i + 100);
  try {
    const res = await fetch(`https://thumbnails.roblox.com/v1/assets?assetIds=${chunk.join(",")}&size=420x420&format=Png`);
    const json = await res.json();
    for (const item of json.data || []) {
      if (item.state !== "Completed") continue;
      const img = await fetch(item.imageUrl);
      fs.writeFileSync(path.join(cacheDir, `${item.targetId}.png`), Buffer.from(await img.arrayBuffer()));
    }
  } catch (e) { console.error("thumbnail fetch failed", e.message); }
}

// Camera views.
const viewList = [];
const route = data.tiles || [];
const eye = 5.4;
function along(i) {
  const t = route[i];
  const look = t.look;
  return { pos: [t.pos[0] - look[0] * 6, eye, t.pos[2] - look[2] * 6],
    target: [t.pos[0] + look[0] * 20, eye - 1.2, t.pos[2] + look[2] * 20] };
}
if (route.length) {
  const picks = tiles || Array.from({ length: views }, (_, k) => Math.min(route.length - 1, Math.round((k + 0.5) * route.length / views)));
  for (const i of picks) if (route[i]) viewList.push(along(i));
} else if (data.spawn) {
  const s = data.spawn;
  for (let k = 0; k < views; k++) {
    const a = (k / views) * Math.PI * 2;
    viewList.push({ pos: [s[0] + Math.cos(a) * 30, 9, s[2] + Math.sin(a) * 30], target: [s[0], 4, s[2]] });
  }
}
for (const v of at) viewList.push(v);
let topView = null;
if (top) {
  let min = [1e9, 1e9, 1e9], max = [-1e9, -1e9, -1e9];
  for (const p of data.parts) for (let k = 0; k < 3; k++) { min[k] = Math.min(min[k], p.cf[k]); max[k] = Math.max(max[k], p.cf[k]); }
  const c = [(min[0] + max[0]) / 2, 0, (min[2] + max[2]) / 2];
  const span = Math.max(max[0] - min[0], max[2] - min[2]);
  topView = { pos: [c[0] + span * 0.35, span * 0.95, c[2] + span * 0.55], target: c, fov: 50 };
}

const themeMood = {
  classic: { exposure: 0.2 }, laundry: { exposure: 0.1 }, boiler: { exposure: 0.25 }, greenhouse: { exposure: 0.1 },
  frost: { exposure: 0.05 }, vault: { exposure: 0.3 }, lobby: { exposure: 0.15 },
};
const mood = Object.assign({
  ambient: data.ambient || [0.12, 0.1, 0.12],
  fog: data.fog || [0.06, 0.05, 0.06],
  fogDensity: 0.0045,
  ambientIntensity: 1.4,
  bloom: 0.5,
}, themeMood[data.theme] || {});

// Serve the viewer (ES modules need http, not file://).
const server = http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split("?")[0]);
  const file = path.join(here, url === "/" ? "viewer.html" : url);
  if (!file.startsWith(here) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
  const type = file.endsWith(".html") ? "text/html" : file.endsWith(".js") ? "text/javascript" : file.endsWith(".png") ? "image/png" : "application/octet-stream";
  res.writeHead(200, { "Content-Type": type });
  fs.createReadStream(file).pipe(res);
});
await new Promise(r => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

const exe = ["/opt/pw-browsers/chromium-1194/chrome-linux/chrome", "/opt/pw-browsers/chromium"].find(p => fs.existsSync(p));
const browser = await chromium.launch({ executablePath: exe, args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] });
const page = await browser.newPage({ viewport: { width: size[0], height: size[1] } });
page.on("console", m => { if (m.type() === "error") console.error("[page]", m.text()); });
await page.goto(`http://127.0.0.1:${port}/viewer.html?w=${size[0]}&h=${size[1]}`);
await page.waitForFunction(() => window.ready === true, null, { timeout: 60000 });
await page.evaluate(([d, m]) => window.loadScene(d, m), [data, mood]);
let n = 0;
for (const v of viewList) {
  await page.evaluate(v => window.renderView(v), v);
  await page.screenshot({ path: `${outPrefix}_v${n}.png` });
  console.log(`wrote ${outPrefix}_v${n}.png`);
  n++;
}
if (topView) {
  await page.evaluate(v => window.renderView(v), topView);
  await page.screenshot({ path: `${outPrefix}_top.png` });
  console.log(`wrote ${outPrefix}_top.png`);
}
await browser.close();
server.close();
