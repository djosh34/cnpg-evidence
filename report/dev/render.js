// Renders every image of the sample documents with a local Chrome, for
// development. The release binary does the same with its own Chrome.
//
// Usage: node dev/render.js CHROME OUT_DIR
// Writes OUT_DIR/clean/*.png and OUT_DIR/failing/*.png; exit 0, or 1 on any error.
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');

const [chrome, outDir] = process.argv.slice(2);
if (!chrome || !outDir) {
  console.error('usage: node dev/render.js CHROME OUT_DIR');
  process.exit(1);
}

const report = path.join(__dirname, '..');
const sample = name => JSON.parse(fs.readFileSync(path.join(report, 'samples', name), 'utf8'));
const page = 'file://' + path.join(report, 'page', 'index.html');

async function main() {
  const browser = await chromium.launch({ executablePath: chrome });
  try {
    const tab = await browser.newPage({ viewport: { width: 3200, height: 1600 }, deviceScaleFactor: 2 });
    tab.on('pageerror', error => console.error(`page error: ${error.message}`));
    for (const run of ['clean', 'failing']) {
      const out = path.join(outDir, run);
      fs.mkdirSync(out, { recursive: true });
      for (const source of ['evidence', 'host-check', 'prove']) {
        await tab.goto(page);
        const args = [sample(`${source}.${run}.json`), sample(`${source}.desired.json`)];
        const files = await tab.evaluate(([doc, desired]) => draw(doc, desired), args);
        for (const problem of await tab.evaluate(() => overflows())) console.warn(`${run}/${source}: overflow ${problem}`);
        for (const { file, selector } of files) {
          await tab.locator(selector).screenshot({ path: path.join(out, file) });
          console.log(path.join(out, file));
        }
      }
    }
  } finally {
    await browser.close();
  }
}

main().catch(error => {
  console.error(error.message);
  process.exit(1);
});
