// Открывает дашборд в headless Chromium в светлой и тёмной теме, проверяет, что все графики
// отрисованы без ошибок и предупреждений в консоли, и сохраняет скриншоты: светлый — в docs/dashboard.png
// (он в README), тёмный и телефонный — в .tmp/ для просмотра.
// Запуск: npm install && npx playwright install chromium && node scripts/screenshot.mjs
// Код возврата 1 — если график не отрисован, в консоли есть ошибка/предупреждение
// или не загрузился какой-то файл.
import { chromium } from "playwright";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../dashboard/", import.meta.url));
const DOCS = fileURLToPath(new URL("../docs/", import.meta.url));
const TMP = fileURLToPath(new URL("../.tmp/", import.meta.url));
const TYPES = { ".html": "text/html; charset=utf-8", ".json": "application/json; charset=utf-8" };
const EXPECTED_CHARTS = 5;

// Минимальный статический сервер: страница берёт спеки и данные через fetch, а с file:// браузер их не отдаст.
const server = createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^\/+/, "") || "index.html";
  const file = join(ROOT, path);
  if (!file.startsWith(ROOT)) { res.writeHead(403).end(); return; }  // только файлы dashboard/
  try {
    const body = await readFile(file);
    res.writeHead(200, { "content-type": TYPES[extname(path)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const url = `http://127.0.0.1:${server.address().port}/index.html`;

const problems = [];
const browser = await chromium.launch();
try {
  for (const [scheme, width, out] of [["light", 1280, join(DOCS, "dashboard.png")], ["dark", 1280, join(TMP, "dashboard-dark.png")],
                                    ["light", 390, join(TMP, "dashboard-phone.png")], ["light", 768, join(TMP, "dashboard-tablet.png")]]) {
    const tag = `${scheme} ${width}px`;
    const page = await browser.newPage({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme: scheme });
    page.on("console", (msg) => {
      if (msg.type() === "error" || msg.type() === "warning") problems.push(`${tag}: console.${msg.type()}: ${msg.text()}`);
    });
    page.on("pageerror", (err) => problems.push(`${tag}: pageerror: ${err.message}`));
    page.on("requestfailed", (r) => problems.push(`${tag}: requestfailed: ${r.url()} ${r.failure()?.errorText}`));
    page.on("response", (r) => { if (r.status() >= 400) problems.push(`${tag}: HTTP ${r.status()}: ${r.url()}`); });

    await page.goto(url, { waitUntil: "networkidle" });
    await page.waitForSelector("body[data-rendered]", { timeout: 30000 });
    const state = await page.evaluate(() => document.body.dataset.rendered);
    if (state !== "ok") problems.push(`${tag}: страница сообщила: ${state}`);
    const charts = await page.$$eval(".card svg.marks", (els) => els.length);
    if (charts !== EXPECTED_CHARTS) problems.push(`${tag}: отрисовано графиков: ${charts}, ожидалось ${EXPECTED_CHARTS}`);
    // Горизонтальной прокрутки страницы быть не должно (широкие графики прокручиваются внутри карточек).
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    if (overflow > 0) problems.push(`${tag}: страница шире окна на ${overflow}px`);
    // И внутри карточек: карточка не должна прокручиваться вбок (иначе на телефоне график обрезан).
    // Мерить нужно карточку: vega-embed растягивает сам контейнер графика под ширину SVG.
    // Широкие таблицы прокручиваются внутри своей обёртки .table-wrap, это не считается.
    const clipped = await page.$$eval(".card", (els) => els.filter((e) => e.scrollWidth > e.clientWidth + 1)
      .map((e) => `${e.getAttribute("aria-labelledby")} +${e.scrollWidth - e.clientWidth}px`));
    if (clipped.length) problems.push(`${tag}: графики шире карточек: ${clipped.join(", ")}`);
    const tiles = await page.$$eval("#kpi .tile", (els) => els.length);
    if (tiles !== 6) problems.push(`${tag}: плиток ${tiles}, ожидалось 6`);
    await page.screenshot({ path: out, fullPage: true });
    console.log(`${tag}: графиков ${charts}, плиток ${tiles}, скриншот ${out.replace(/^.*\/(docs|\.tmp)\//, "$1/")}`);
    await page.close();
  }
} finally {
  await browser.close();
  server.close();
}

if (problems.length) {
  console.error("ПРОБЛЕМЫ:\n" + problems.map((p) => "  " + p).join("\n"));
  process.exit(1);
}
console.log("ok: ошибок и предупреждений в консоли нет");
