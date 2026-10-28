// Draws the images of one document as sheets on this page, one sheet per
// image file. The caller loads index.html, awaits draw(doc, desired) and
// screenshots each returned selector into its file.
//
// draw(desired document): the desired image of each pair.
// draw(actual document, desired document): both images of each pair, the
// actual one with the values beyond desired in red and a Passed or Failed.

const SOURCES = {
  evidence: { by: 'evidence.sh, read only, through the Kubernetes API and PostgreSQL' },
  'host-check': { by: 'host-check.sh on the node, read only' },
  prove: { by: 'prove.sh, by trying each login and access' },
};

const MIN_TABLE_WIDTH = 1080;

// Node names and check ids go into file names.
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

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
      if (typeof node !== 'string' || !NAME.test(node)) fail(`node is not a node name: ${JSON.stringify(node)}`);
    }
  } else {
    fail(`kind is neither desired nor actual: ${JSON.stringify(kind)}`);
  }

  const sheets = [];
  const docs = [desired, actual].filter(Boolean);
  for (const image of imagesOf(source, docs)) {
    for (const key of image.sections) {
      if (!image.actualOnly) need(desired, key, 'desired');
      if (actual) need(actual, key, 'actual');
    }
    if (!NAME.test(image.name)) fail(`not a name for a file: ${JSON.stringify(image.name)}`);
    const base = source === 'host-check' ? `host-check-${node}-${image.name}` : `${source}-${image.name}`;
    const pair = [];
    if (!image.actualOnly) pair.push({ side: 'desired', doc: desired, reader: side(desired, null) });
    if (actual) pair.push({ side: 'actual', doc: actual, reader: side(actual, diffs) });
    const columns = (typeof image.columns === 'function' ? image.columns(docs) : image.columns).map(c => (typeof c === 'string' ? { label: c } : c));
    for (const { side: which, doc: from, reader } of pair) {
      const rows = ordered(visible(image.rows(reader, docs), image.names));
      const context = [['System', system(source, from, node)]];
      if (which === 'desired') context.push(['Made by', 'desired.sh, from desired.yaml']);
      else context.push(['Collected by', SOURCES[source].by]);
      // A desired row for every instance ("*") gives no count.
      if (image.noun && !rows.some(r => r.every)) {
        const count = rows.length;
        const [one, many] = image.noun;
        context.push(['Population', `${which === 'actual' && count > 1 ? 'All ' : ''}${count} ${count === 1 ? one : many}`]);
      }
      if (image.raw && which === 'actual') {
        const raw = valueAt(from, image.raw);
        if (raw !== undefined) context.push(['Read on the node', typeof raw === 'string' ? raw : JSON.stringify(raw)]);
      }
      sheets.push({
        file: `${base}-${which}.png`,
        pair: base,
        side: which,
        title: image.title,
        control: image.control,
        statement: image[which],
        context,
        collectedAt: which === 'actual' ? collectedAt(from.collected_at) : null,
        // Failed when the image shows at least one red mark.
        verdict: which === 'actual' ? (rows.some(r => bad(r.cells.flat())) ? 'Failed' : 'Passed') : null,
        legend: image.legend[which],
        columns,
        names: image.names,
        rows,
      });
    }
  }
  return sheets;
}

// 'extra' or 'missing' when the cells that name the row all are.
function rowState(row, names) {
  return allState(row.cells.slice(0, names).flat().map(v => v.state));
}

// Less than desired is no finding: a row or value only the desired side has is
// not drawn. A row goes when a cell that names it holds only desired values,
// or, on an image without name cells, when all its values are desired only.
function visible(rows, names) {
  const desiredOnly = values => allState(values.map(v => v.state)) === 'missing';
  return rows
    .filter(row => (names ? !row.cells.slice(0, names).some(desiredOnly) : !desiredOnly(row.cells.flat())))
    .map(row => ({ ...row, cells: row.cells.map(values => values.filter(v => v.state !== 'missing')) }));
}

const bad = values => values.some(v => v.state === 'extra');
const before = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

// Correct first, red last, each group alphabetical: the values of each cell,
// then the rows by their cells from the first column on. Rows with keep stay
// in the order of keep; within a section, either every row has keep or none.
function ordered(rows) {
  const byValue = (a, b) => bad([a]) - bad([b]) || before(a.text ?? '', b.text ?? '');
  const key = row => row.cells.map(values => values.map(v => v.text ?? (v.mark ? '1' : '0')).join('\n')).join('\t');
  return rows
    .map(row => ({ ...row, cells: row.cells.map(values => [...values].sort(byValue)) }))
    .sort((a, b) => {
      const section = (a.section ?? 0) - (b.section ?? 0);
      if (section) return section;
      if (a.keep !== undefined && b.keep !== undefined) return before(a.keep, b.keep);
      return bad(a.cells.flat()) - bad(b.cells.flat()) || before(key(a), key(b));
    });
}

function element(tag, className, content) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (content !== undefined) el.textContent = content;
  return el;
}

function squareElement(value) {
  return element('span', `box${value.mark ? ' on' : ''}${value.state ? ` ${value.state}` : ''}`);
}

// An extra row is red in the cells that name it; every other cell shows its own state.
function cell(values, column, isName, rowState) {
  const td = element('td', isName ? 'name' : column.mark ? 'mark' : '');
  if (!values.length && !isName) values = [{ text: 'None', state: '' }];
  for (const value of values) {
    const line = element('div', 'v');
    td.append(line);
    if (Object.hasOwn(value, 'mark')) line.append(squareElement(value));
    else line.append(element('span', `val ${isName ? rowState || value.state : value.state}`.trim(), value.text));
  }
  return td;
}

// The squares on one line, the red words on the next.
function legendElement(entries) {
  const legend = element('div', 'legend');
  entries.forEach(([specimen, words], i) => {
    if (i > 0 && typeof specimen !== 'string' && typeof entries[i - 1][0] === 'string') legend.append(element('div', 'break'));
    const item = element('div', 'item');
    if (typeof specimen === 'string') item.append(squareElement({ mark: specimen.startsWith('on'), state: specimen.endsWith('extra') ? 'extra' : '' }));
    else if (specimen.name) item.append(element('span', 'specimen name', specimen.name));
    else item.append(element('span', 'specimen', specimen.text));
    item.append(element('span', 'words', words));
    legend.append(item);
  });
  return legend;
}

// One heading row, or two when columns share a group heading above them.
function headElement(columns, names) {
  const thead = element('thead');
  if (columns.some(c => c.group)) {
    const groups = element('tr', 'groups');
    for (let i = 0; i < columns.length; ) {
      let span = 1;
      while (columns[i].group && columns[i + span]?.group === columns[i].group) span++;
      const th = element('th', columns[i].group ? 'group' : 'blank');
      if (columns[i].group) th.append(element('span', '', columns[i].group));
      th.colSpan = span;
      groups.append(th);
      i += span;
    }
    thead.append(groups);
  }
  const head = element('tr');
  columns.forEach((c, i) => head.append(element('th', i < names ? 'name' : c.mark ? `mark${c.wide ? ' wide' : ''}` : '', c.label)));
  thead.append(head);
  return thead;
}

function sheetElement(sheet, id) {
  const section = element('section', `sheet ${sheet.side}`);
  section.id = id;
  const header = element('header');
  const intro = element('div', 'intro');
  intro.append(element('h1', '', sheet.title), element('p', 'control', `Control: ${sheet.control}`), element('p', '', sheet.statement));
  const aside = element('div', 'side');
  const stamp = element('div', 'stamp');
  stamp.append(element('span', 'tag', sheet.side === 'desired' ? 'Desired' : 'Actual'));
  if (sheet.verdict) stamp.append(element('span', `verdict ${sheet.verdict.toLowerCase()}`, sheet.verdict));
  aside.append(stamp);
  if (sheet.collectedAt) aside.append(element('p', 'time-label', 'Collected at'), element('p', 'time', sheet.collectedAt));
  const context = element('dl', 'context');
  for (const [term, text] of sheet.context) context.append(element('dt', '', term), element('dd', '', text));
  header.append(intro, aside, context);

  const table = element('table');
  table.append(headElement(sheet.columns, sheet.names));
  const body = element('tbody');
  for (const row of sheet.rows) {
    const tr = element('tr');
    const state = rowState(row, sheet.names);
    row.cells.forEach((values, i) => tr.append(cell(values, sheet.columns[i], i < sheet.names, state)));
    body.append(tr);
  }
  table.append(body);
  section.append(header);
  if (sheet.legend.length) section.append(legendElement(sheet.legend));
  section.append(table);
  return section;
}

// Both sheets of a pair get the column widths of the desired table, so a pair
// lines up whether it was drawn in one call or two. A narrow table is widened
// to MIN_TABLE_WIDTH over its value columns.
function align(sheets) {
  const desired = sheets.find(s => s.classList.contains('desired')) ?? sheets[0];
  const heads = [...desired.querySelectorAll('thead tr:last-child th')];
  const widths = heads.map(th => Math.ceil(th.getBoundingClientRect().width));
  const names = desired.querySelectorAll('thead tr:last-child th.name').length;
  const short = MIN_TABLE_WIDTH - widths.reduce((a, b) => a + b, 0);
  if (short > 0) {
    const spread = widths.length - names || widths.length;
    const from = widths.length - spread;
    for (let i = from; i < widths.length; i++) widths[i] += Math.floor(short / spread) + (i === widths.length - 1 ? short % spread : 0);
  }
  const total = widths.reduce((a, b) => a + b, 0);
  for (const sheet of sheets) {
    const table = sheet.querySelector('table');
    // A fixed table takes its widths from its columns, not from a second heading row.
    const cols = element('colgroup');
    for (const width of widths) {
      const col = element('col');
      col.style.width = `${width}px`;
      cols.append(col);
    }
    table.prepend(cols);
    table.style.tableLayout = 'fixed';
    table.style.width = `${total}px`;
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
