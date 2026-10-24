#!/usr/bin/env node
/**
 * shoot-local.mjs — Puppeteer screenshots of a local dev-server URL at
 * multiple breakpoints.
 *
 * Examples:
 *   node shoot-local.mjs --url http://localhost:4200/ --out shots/ --bp 360,768,1440 --label hero
 *   node shoot-local.mjs --url http://localhost:4200/ --out shots/ --scroll '#early-access' --label early
 *
 * Flags:
 *   --url          Required. Page to load.
 *   --out          Required. Output directory (created if missing).
 *   --bp           Comma-separated viewport widths (default 360,768,1440).
 *   --height       Map of `width:height` pairs (e.g. 360:1100,768:1000). Default heuristic.
 *   --label        Prefix for output filenames (default "page").
 *   --scroll       CSS selector to scroll into view before shooting (optional).
 *   --full         Take a full-page screenshot instead of viewport-only.
 *   --wait         Extra ms to wait after load (for animations to settle).
 *   --chrome       Path to Chrome binary. Falls back to CHROME_PATH env var
 *                  (see env.example) — no hard-coded per-machine default, so
 *                  this refuses cleanly instead of guessing a path.
 */
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

// CHROME_PATH usually only lives in the workspace root .env — nothing else
// loads it into this process for us (env-check.sh only inspects the file,
// it never sources it), so we do it ourselves before reading it below.
function loadEnv(startDir) {
  let dir = startDir;
  for (;;) {
    const hasHarness = fs.existsSync(path.join(dir, 'harness.json')) ||
      fs.existsSync(path.join(dir, 'workspace.json'));
    if (hasHarness) {
      const envPath = path.join(dir, '.env');
      if (fs.existsSync(envPath)) {
        const lines = fs.readFileSync(envPath, 'utf8').split('\n');
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;
          const idx = trimmed.indexOf('=');
          const key = trimmed.slice(0, idx).trim();
          let val = trimmed.slice(idx + 1).trim();
          if (val.length >= 2 && ((val[0] === '"' && val.endsWith('"')) || (val[0] === "'" && val.endsWith("'")))) {
            val = val.slice(1, -1);
          }
          if (process.env[key] === undefined) process.env[key] = val;
        }
      }
      return;
    }
    const parent = path.dirname(dir);
    if (parent === dir) return;
    dir = parent;
  }
}
loadEnv(path.dirname(fileURLToPath(import.meta.url)));

const args = process.argv.slice(2);
function getArg(name, def = null) {
  const idx = args.indexOf(`--${name}`);
  return idx >= 0 && args[idx + 1] && !args[idx + 1].startsWith('--') ? args[idx + 1] : def;
}
function hasFlag(name) {
  return args.includes(`--${name}`);
}

const url = getArg('url');
const out = getArg('out');
if (!url || !out) {
  console.error('Usage: shoot-local.mjs --url <url> --out <dir> [--bp ...] [--scroll <sel>] [--label X]');
  process.exit(1);
}
const bp = (getArg('bp', '360,768,1440')).split(',').map(s => parseInt(s, 10));
const label = getArg('label', 'page');
const scroll = getArg('scroll', null);
const extraWait = parseInt(getArg('wait', '300'), 10);
const fullPage = hasFlag('full');
const chromePath = getArg('chrome', process.env.CHROME_PATH || null);

if (!chromePath) {
  console.error('CHROME_PATH не задан — укажи путь к Chrome/Chromium в .env (см. env.example) или через --chrome');
  process.exit(1);
}
if (!fs.existsSync(chromePath)) {
  console.error(`путь к Chrome не существует: ${chromePath}`);
  process.exit(1);
}

let puppeteer;
try {
  puppeteer = (await import('puppeteer-core')).default;
} catch {
  console.error('puppeteer-core не установлен: npm install puppeteer-core');
  process.exit(1);
}

const heightMap = {};
for (const pair of (getArg('height', '') || '').split(',').filter(Boolean)) {
  const [w, h] = pair.split(':').map(Number);
  if (w && h) heightMap[w] = h;
}
const heightDefault = { 360: 1100, 600: 1100, 768: 1000, 1024: 1000, 1280: 900, 1440: 900, 1800: 900 };

fs.mkdirSync(out, { recursive: true });

const browser = await puppeteer.launch({
  headless: 'new',
  defaultViewport: null,
  executablePath: chromePath,
});

for (const w of bp) {
  const h = heightMap[w] || heightDefault[w] || 900;
  const page = await browser.newPage();
  await page.setViewport({ width: w, height: h, deviceScaleFactor: 1, isMobile: w < 500 });
  try {
    await page.goto(url, { waitUntil: 'networkidle0', timeout: 60000 });
  } catch {
    console.warn(`[${w}] networkidle0 timeout -> fallback to domcontentloaded`);
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  }
  if (scroll) {
    await page.evaluate(sel => {
      const el = document.querySelector(sel);
      if (el) el.scrollIntoView({ behavior: 'auto', block: 'start' });
    }, scroll);
  }
  if (extraWait > 0) await new Promise(r => setTimeout(r, extraWait));

  const file = path.join(out, `${label}-${w}.png`);
  await page.screenshot({ path: file, fullPage });
  console.log(`  saved ${file}`);
  await page.close();
}
await browser.close();
