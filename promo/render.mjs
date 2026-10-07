// Deterministic frame renderer: drives window.__seek(t) one frame at a time and
// pipes PNGs straight into ffmpeg, so the export is true 60fps with no dropped frames.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import puppeteer from "puppeteer-core";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const PORT = 8731;
const FPS = 60;
const W = 1920;
const H = 1080;
// The page is authored at 1920x1080; rendering at 2x gives a true 3840x2160 master
// with text and 1px rules rasterised at full 4K rather than upscaled.
const SCALE = 2;

const CHROME =
  process.env.CHROME_PATH ||
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".png": "image/png",
  ".otf": "font/otf",
  ".ttf": "font/ttf",
};

function serve() {
  const server = http.createServer((req, res) => {
    const rel = decodeURIComponent(req.url.split("?")[0]).replace(/^\/+/, "");
    const file = path.join(DIR, rel || "luma-bar-promo.html");
    if (!file.startsWith(DIR) || !fs.existsSync(file)) {
      res.writeHead(404).end("not found");
      return;
    }
    res.writeHead(200, { "content-type": MIME[path.extname(file)] || "application/octet-stream" });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(PORT, "127.0.0.1", () => resolve(server)));
}

function ffmpeg(args) {
  const p = spawn("ffmpeg", args, { stdio: ["pipe", "inherit", "inherit"] });
  return p;
}

function runffmpeg(args) {
  const p = spawn("ffmpeg", args, { stdio: ["ignore", "inherit", "inherit"] });
  return once(p, "close").then((codes) => {
    if (codes[0] !== 0) throw new Error(`ffmpeg exited ${codes[0]}: ${args.join(" ")}`);
  });
}

const AUDIO =
  process.env.LUMA_AUDIO ||
  "/Users/linusshyu/Downloads/MEOVV - LIT RIGHT NOW (1).mp3";

const server = await serve();

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: true,
  args: [
    `--window-size=${W},${H}`,
    "--hide-scrollbars",
    `--force-device-scale-factor=${SCALE}`,
    "--font-render-hinting=none",
    "--disable-lcd-text",
    "--force-color-profile=srgb",
    "--disable-background-timer-throttling",
  ],
});

const page = await browser.newPage();
await page.setViewport({ width: W, height: H, deviceScaleFactor: SCALE });
await page.goto(`http://127.0.0.1:${PORT}/luma-bar-promo.html?static`, { waitUntil: "networkidle0" });
await page.evaluate(async () => {
  await document.fonts.ready;
  await Promise.all(
    [...document.images].map((i) => (i.complete ? null : i.decode().catch(() => {})))
  );
});
await new Promise((r) => setTimeout(r, 600));

const DURATION = await page.evaluate(() => window.__duration);
const AUDIO_START = (await page.evaluate(() => window.__audioStart)) || 16.865;
const TOTAL = Math.round(DURATION * FPS);
const POSTER_AT = DURATION - 3.0;

// poster frame (lossless)
await page.evaluate((t) => window.__seek(t), POSTER_AT);
fs.writeFileSync(path.join(DIR, "luma-bar-poster.png"), await page.screenshot({ type: "png" }));

const out = path.join(DIR, "luma-bar-promo-4k.mp4");
// Frames go over the wire as near-lossless JPEG: at 3840x2160 the PNG encode in the
// browser dominates the render time, and the final H.264 pass is 4:2:0 regardless.
const enc = ffmpeg([
  "-y", "-v", "error",
  "-f", "image2pipe", "-c:v", "mjpeg", "-framerate", String(FPS), "-i", "-",
  "-c:v", "libx264", "-preset", "medium", "-crf", "16",
  "-pix_fmt", "yuv420p", "-movflags", "+faststart",
  out,
]);

process.stdout.write(`rendering ${TOTAL} frames @ ${FPS}fps, ${W * SCALE}x${H * SCALE}\n`);
const started = Date.now();
for (let f = 0; f < TOTAL; f++) {
  await page.evaluate((t) => window.__seek(t), f / FPS);
  const buf = await page.screenshot({ type: "jpeg", quality: 97, optimizeForSpeed: true });
  if (!enc.stdin.write(buf)) await once(enc.stdin, "drain");
  if (f % 120 === 0) {
    const pct = ((f / TOTAL) * 100).toFixed(0).padStart(3);
    const secs = ((Date.now() - started) / 1000).toFixed(0);
    process.stdout.write(`  ${pct}%  frame ${f}/${TOTAL}  ${secs}s\n`);
  }
}
enc.stdin.end();
await once(enc, "close");

await browser.close();
server.close();

const fade = `afade=t=in:st=0:d=0.04,afade=t=out:st=${(DURATION - 1.6).toFixed(3)}:d=1.6`;

async function muxAudio(videoPath) {
  if (!fs.existsSync(AUDIO)) {
    process.stdout.write(`skip audio (missing ${AUDIO})\n`);
    return;
  }
  const tmp = videoPath.replace(/\.mp4$/, ".mux.mp4");
  process.stdout.write(`muxing audio into ${path.basename(videoPath)}\n`);
  await runffmpeg([
    "-y", "-v", "error",
    "-i", videoPath,
    "-ss", String(AUDIO_START), "-i", AUDIO,
    "-map", "0:v:0", "-map", "1:a:0",
    "-c:v", "copy",
    "-af", fade,
    "-c:a", "aac", "-b:a", "256k",
    "-t", String(DURATION),
    "-movflags", "+faststart",
    tmp,
  ]);
  fs.renameSync(tmp, videoPath);
}

await muxAudio(out);

process.stdout.write("done\n");
