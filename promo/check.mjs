// Renders a handful of key times to promo/check/*.png for eyeballing composition.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import puppeteer from "puppeteer-core";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const PORT = 8732;
const TIMES = process.argv.slice(2).map(Number);
const CHROME =
  process.env.CHROME_PATH ||
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const MIME = { ".html": "text/html; charset=utf-8", ".png": "image/png", ".otf": "font/otf" };

const server = http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split("?")[0]).replace(/^\/+/, "");
  const file = path.join(DIR, rel || "luma-bar-promo.html");
  if (!file.startsWith(DIR) || !fs.existsSync(file)) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": MIME[path.extname(file)] || "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(PORT, "127.0.0.1", r));

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: true,
  args: ["--window-size=1920,1080", "--hide-scrollbars", "--force-device-scale-factor=1",
         "--font-render-hinting=none", "--force-color-profile=srgb"],
});
const page = await browser.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));
page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 });
await page.goto(`http://127.0.0.1:${PORT}/luma-bar-promo.html?static`, { waitUntil: "networkidle0" });
await page.evaluate(async () => { await document.fonts.ready; });
await new Promise((r) => setTimeout(r, 500));

fs.mkdirSync(path.join(DIR, "check"), { recursive: true });
for (const t of TIMES) {
  await page.evaluate((x) => window.__seek(x), t);
  const name = `t${String(t).replace(".", "_")}.png`;
  fs.writeFileSync(path.join(DIR, "check", name), await page.screenshot({ type: "png" }));
  console.log("wrote", name);
}
if (errors.length) console.log("PAGE ERRORS:\n" + errors.join("\n"));
await browser.close();
server.close();
