// Draws the images of one document as sheets on this page, one sheet per
// image file. The caller loads index.html, awaits draw(doc, desired) and
// screenshots each returned selector into its file.
//
// draw(desired document): the desired image of each pair.
// draw(actual document, desired document): both images of each pair, the
// actual one with the differences marked.

const SOURCES = {
  evidence: { by: 'evidence.sh, read only, through the Kubernetes API and PostgreSQL' },
  'host-check': { by: 'host-check.sh on the node, read only' },
  prove: { by: 'prove.sh, by trying each login and access' },
};

const MIN_TABLE_WIDTH = 1080;

function fail(message) {
  throw new Error(message);
}

function need(doc, key, kind) {
  if (doc === null || typeof doc !== 'object' || !Object.hasOwn(doc, key)) fail(`the ${kind} document has no key ${key}`);
  return doc[key];
}

// "2026-01-02T03:04:05Z" -> "2026-01-02 03:04 UTC"
function collectedAt(value) {
  const match = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}):\d{2}(\.\d+)?Z$/.exec(String(value));
  if (!match) fail(`collected_at is not a UTC time: ${JSON.stringify(value)}`);
  return `${match[1]} ${match[2]} UTC`;
}

function system(source, doc, node) {
  if (source === 'evidence') {
    const cluster = need(doc, 'cluster', doc.kind);
    return `PostgreSQL cluster ${cluster.name} in namespace ${cluster.namespace}`;
  }
  if (source === 'prove') return `PostgreSQL cluster ${need(doc, 'cluster', doc.kind)} in namespace ${need(doc, 'namespace', doc.kind)}`;
  return `Node ${node}`;
}

// Every sheet to draw, with its rows and words, without touching the page.
function plan(doc, desired) {
  const kind = need(doc, 'kind', 'given');
  const source = need(doc, 'source', 'given');
  if (!Object.hasOwn(SOURCES, source)) fail(`unknown source ${JSON.stringify(source)}`);
  let actual = null;
  let diffs = null;
  let node = '';
  if (kind === 'desired') {
    if (desired !== undefined) fail('a desired document is drawn alone');
    if (source === 'host-check') fail('a host-check desired document is drawn together with a node file');
    desired = doc;
  } else if (kind === 'actual') {
    if (desired === undefined) fail('an actual document needs its desired document');
    need(desired, 'kind', 'desired');
    actual = doc;
    diffs = differences(desired, actual);
    collectedAt(need(actual, 'collected_at', 'actual'));
    if (source === 'host-check') {
      node = need(actual, 'node', 'actual');
      if (typeof node !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(node)) fail(`node is not a node name: ${JSON.stringify(node)}`);
    }
  } else {
    fail(`kind is neither desired nor actual: ${JSON.stringify(kind)}`);
  }

  const sheets = [];
  for (const image of imagesOf(source, [desired, actual].filter(Boolean))) {
    for (const key of image.sections) {
      if (!image.actualOnly) need(desired, key, 'desired');
      if (actual) need(actual, key, 'actual');
    }
    const base = source === 'host-check' ? `host-check-${node}-${image.name}` : `${source}-${image.name}`;
    const pair = [];
    if (!image.actualOnly) pair.push({ side: 'desired', doc: desired, reader: side(desired, null) });
    if (actual) pair.push({ side: 'actual', doc: actual, reader: side(actual, diffs) });
    for (const { side: which, doc: from, reader } of pair) {
      const rows = sorted(image.rows(reader));
      const context = [['System', system(source, from, node)]];
      if (which === 'desired') context.push(['Made by', 'desired.sh, from desired.yaml']);
      else context.push(['Collected by', SOURCES[source].by]);
      // A desired row for every instance ("*") gives no count.
      if (image.noun && !rows.some(r => r.sort === '*')) {
        const count = rows.filter(r => r.cells[0][0]?.state !== 'missing').length;
        context.push(['Population', `${which === 'actual' ? 'All ' : ''}${count} ${image.noun}`]);
      }
      if (image.raw && which === 'actual') {
        const raw = valueAt(from, image.raw);
        if (raw !== undefined) context.push(['Read on the node', typeof raw === 'string' ? raw : JSON.stringify(raw)]);
      }
      if (which === 'actual' && !image.actualOnly) context.push(['Key', KEY]);
      sheets.push({
        file: `${base}-${which}.png`,
        pair: base,
        side: which,
        title: image.title,
        control: image.control,
        statement: image[which],
        context,
        collectedAt: which === 'actual' ? collectedAt(from.collected_at) : null,
        columns: image.columns,
        names: image.names,
        inline: Boolean(image.inline),
        rows,
      });
    }
  }
  return sheets;
}

function element(tag, className, content) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (content !== undefined) el.textContent = content;
  return el;
}

function cell(values, isName, inline, rowState) {
  const td = element('td', isName ? 'name' : '');
  if (!values.length && !isName) values = [{ text: 'None', state: '' }];
  let line = null;
  for (const value of values) {
    if (inline && line) line.append(', ');
    else td.append((line = element('div', 'v')));
    line.append(element('span', `val ${rowState || value.state}`.trim(), value.text));
  }
  return td;
}

function sheetElement(sheet, id) {
  const section = element('section', `sheet ${sheet.side}`);
  section.id = id;
  const header = element('header');
  const intro = element('div', 'intro');
  intro.append(element('h1', '', sheet.title), element('p', 'control', `Control: ${sheet.control}`), element('p', '', sheet.statement));
  const aside = element('div', 'side');
  aside.append(element('span', 'tag', sheet.side === 'desired' ? 'Desired' : 'Actual'));
  if (sheet.collectedAt) aside.append(element('p', 'time-label', 'Collected at'), element('p', 'time', sheet.collectedAt));
  const context = element('dl', 'context');
  for (const [term, text] of sheet.context) context.append(element('dt', '', term), element('dd', '', text));
  header.append(intro, aside, context);

  const table = element('table');
  const head = element('tr');
  sheet.columns.forEach((label, i) => head.append(element('th', i < sheet.names ? 'name' : '', label)));
  table.append(element('thead'));
  table.tHead.append(head);
  const body = element('tbody');
  for (const row of sheet.rows) {
    const tr = element('tr');
    const first = row.cells[0][0]?.state ?? '';
    tr.className = first;
    row.cells.forEach((values, i) => tr.append(cell(values, i < sheet.names, sheet.inline && i >= sheet.names, first)));
    body.append(tr);
  }
  table.append(body);
  section.append(header, table);
  return section;
}

// Both sheets of a pair get the column widths of the desired table, so a pair
// lines up whether it was drawn in one call or two. A narrow table is widened
// to MIN_TABLE_WIDTH over its value columns.
function align(sheets) {
  const desired = sheets.find(s => s.classList.contains('desired')) ?? sheets[0];
  const heads = [...desired.querySelectorAll('thead th')];
  const widths = heads.map(th => Math.ceil(th.getBoundingClientRect().width));
  const names = desired.querySelectorAll('thead th.name').length;
  const short = MIN_TABLE_WIDTH - widths.reduce((a, b) => a + b, 0);
  if (short > 0) {
    const spread = widths.length - names || widths.length;
    const from = widths.length - spread;
    for (let i = from; i < widths.length; i++) widths[i] += Math.floor(short / spread) + (i === widths.length - 1 ? short % spread : 0);
  }
  const total = widths.reduce((a, b) => a + b, 0);
  for (const sheet of sheets) {
    const table = sheet.querySelector('table');
    table.style.tableLayout = 'fixed';
    table.style.width = `${total}px`;
    table.querySelectorAll('thead th').forEach((th, i) => {
      th.style.width = `${widths[i]}px`;
    });
    sheet.classList.add('aligned');
    const pad = parseFloat(getComputedStyle(sheet).paddingLeft);
    sheet.style.width = `${total + 2 * pad}px`;
  }
}

async function draw(doc, desired) {
  const sheets = plan(doc, desired);
  await Promise.all([...document.fonts].map(font => font.load()));
  await document.fonts.ready;
  document.body.replaceChildren();
  const files = [];
  const pairs = new Map();
  sheets.forEach((sheet, i) => {
    const el = sheetElement(sheet, `sheet-${i}`);
    document.body.append(el);
    files.push({ file: sheet.file, selector: `#${el.id}` });
    if (!pairs.has(sheet.pair)) pairs.set(sheet.pair, []);
    pairs.get(sheet.pair).push(el);
  });
  for (const pair of pairs.values()) align(pair);
  return files;
}

// Text that runs past its box or into the right margin, for the development
// render to report.
function overflows() {
  const problems = [];
  for (const sheet of document.querySelectorAll('.sheet')) {
    const box = sheet.getBoundingClientRect();
    const pad = parseFloat(getComputedStyle(sheet).paddingRight);
    for (const el of sheet.querySelectorAll('th, td, h1, p, dt, dd, .val')) {
      const r = el.getBoundingClientRect();
      if (el.scrollWidth > el.clientWidth + 1 || r.right > box.right - pad + 1) {
        problems.push(`${sheet.id}: ${el.textContent.trim().slice(0, 50)}`);
      }
    }
  }
  return problems;
}
