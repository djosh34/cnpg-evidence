// What the images show: rows, red values and file names, without a browser.
const test = require('node:test');
const assert = require('node:assert/strict');
const { load, sample, plain } = require('./load');

const page = load();
const desired = sample('evidence.desired.json');
const clean = sample('evidence.clean.json');

function sheets(doc, desiredDoc) {
  return plain(page.plan(doc, desiredDoc));
}

function sheet(doc, desiredDoc, file) {
  const found = sheets(doc, desiredDoc).find(s => s.file === file);
  assert.ok(found, `no sheet ${file}`);
  return found;
}

// The rows of a sheet as text: each cell's values joined, marked +extra or -missing.
function rows(s) {
  return s.rows.map(r => r.cells.map(c => c.map(v => (v.state === 'extra' ? '+' : v.state === 'missing' ? '-' : '') + v.text).join(' ')));
}

const marked = s => s.rows.flatMap(r => r.cells.flat()).filter(v => v.state);

const FILES = [
  '01-accounts', '02-certificate-names', '03-login-rules', '04-client-ca', '05-encryption', '06-network',
  '07-container-isolation', '08-operator-secrets', '09-platform-pods', '10-platform-secrets', '11-platform-setup',
  '12-platform-nodes-certificates',
];

test('evidence: a desired and an actual image per item, versions actual only', () => {
  const expected = [...FILES.flatMap(f => [`evidence-${f}-desired.png`, `evidence-${f}-actual.png`]), 'evidence-13-versions-actual.png'];
  assert.deepEqual(sheets(clean, desired).map(s => s.file), expected);
  assert.deepEqual(sheets(desired).map(s => s.file), FILES.map(f => `evidence-${f}-desired.png`));
});

test('host-check: one pair per check, named by the node', () => {
  const files = sheets(sample('host-check.clean.json'), sample('host-check.desired.json')).map(s => s.file);
  assert.equal(files.length, 26);
  assert.equal(files[0], 'host-check-node-a-selinux-enforcing-desired.png');
  assert.equal(files[25], 'host-check-node-a-bind-service-capability-actual.png');
});

test('prove: three pairs', () => {
  assert.deepEqual(sheets(sample('prove.clean.json'), sample('prove.desired.json')).map(s => s.file), [
    'prove-01-login-attempts-desired.png', 'prove-01-login-attempts-actual.png',
    'prove-02-other-namespace-desired.png', 'prove-02-other-namespace-actual.png',
    'prove-03-host-uid-desired.png', 'prove-03-host-uid-actual.png',
  ]);
});

test('the clean samples mark nothing', () => {
  for (const source of ['evidence', 'host-check', 'prove']) {
    for (const s of sheets(sample(`${source}.clean.json`), sample(`${source}.desired.json`))) {
      assert.deepEqual(marked(s), [], s.file);
    }
  }
});

test('a pair shares its columns and row order', () => {
  const all = sheets(sample('evidence.failing.json'), desired);
  for (const d of all.filter(s => s.side === 'desired')) {
    const a = all.find(s => s.pair === d.pair && s.side === 'actual');
    assert.deepEqual(a.columns, d.columns);
    const keys = s => s.rows.map(r => r.sort);
    const common = keys(a).filter(k => keys(d).includes(k));
    assert.deepEqual(common, keys(d).filter(k => common.includes(k)), d.pair);
  }
});

test('an extra role with no rights is an extra row', () => {
  const actual = structuredClone(clean);
  actual.postgres.roles.push('reporting');
  const s = sheet(actual, desired, 'evidence-01-accounts-actual.png');
  const row = s.rows.find(r => r.cells[0][0].text === 'reporting');
  assert.equal(row.cells[0][0].state, 'extra');
  assert.deepEqual(rows({ rows: [row] }), [['+reporting', 'No', '', '', 'No', 'No', 'No', '', 'No', '']]);
  assert.equal(sheet(actual, desired, 'evidence-01-accounts-desired.png').rows.length, 5);
});

test('a missing role is a struck-through row', () => {
  const actual = structuredClone(clean);
  for (const key of Object.keys(actual.postgres)) actual.postgres[key] = actual.postgres[key].filter(r => r !== 'streaming_replica');
  const s = sheet(actual, desired, 'evidence-01-accounts-actual.png');
  const row = s.rows.find(r => r.cells[0][0].text === 'streaming_replica');
  assert.equal(row.cells[0][0].state, 'missing');
  assert.deepEqual(rows({ rows: [row] }).map(r => [r[0], r[1], r[7]]), [['-streaming_replica', '-Yes', '-Replication -Read server files']]);
});

test('a moved pg_hba line shows its old place missing and its new place extra', () => {
  const actual = structuredClone(clean);
  const hba = actual.details.pg_hba;
  [hba[0].line, hba[1].line] = [hba[1].line, hba[0].line];
  const lines = rows(sheet(actual, desired, 'evidence-03-login-rules-actual.png')).filter(r => r[0].includes('pg_hba')).slice(0, 4);
  assert.deepEqual(lines, [
    ['-pg_hba', '-1', `-${desired.details.pg_hba[0].line}`],
    ['+pg_hba', '+1', `+${desired.details.pg_hba[1].line}`],
    ['-pg_hba', '-2', `-${desired.details.pg_hba[1].line}`],
    ['+pg_hba', '+2', `+${desired.details.pg_hba[0].line}`],
  ]);
});

test('the failing sample marks each changed value', () => {
  const failing = sample('evidence.failing.json');
  const show = file => rows(sheet(failing, desired, `evidence-${file}-actual.png`));
  assert.deepEqual(show('05-encryption').find(r => r[0] === 'pg-2'), ['pg-2', '+TLSv1.2 -TLSv1.3', 'TLSv1.3']);
  assert.deepEqual(show('06-network').find(r => r[1] === '+everyone'), ['pg-3', '+everyone', '+8000 +9187']);
  assert.deepEqual(show('07-container-isolation').find(r => r[0] === 'pg-3'), ['pg-3', '+No']);
  assert.deepEqual(show('08-operator-secrets')[0], ['CNPG operator', 'cnpg-system databases +kube-system']);
  assert.deepEqual(show('09-platform-pods').find(r => r[0] === '+mallory'), ['+mallory', '', '', '', '+databases']);
  assert.deepEqual(show('10-platform-secrets').find(r => r[0] === '+mallory'), ['+mallory', '', '+databases: client-ca', '', '']);
  assert.deepEqual(show('12-platform-nodes-certificates').find(r => r[0].includes('node-agent')), ['+pod node-agent-7xk2p', '+monitoring', 'No', 'No', 'No', '+Yes']);
  const accounts = show('01-accounts');
  assert.deepEqual(accounts.find(r => r[0] === 'billing').slice(8), ['+Yes', '+billing']);
  assert.equal(accounts.find(r => r[0] === 'orders')[6], '+Yes');
  assert.deepEqual(show('04-client-ca').map(r => r[1]), ['CN=example-ca', '+CN=other-ca']);
});

test('host-check and prove show the value read and the value desired', () => {
  const hc = sheet(sample('host-check.failing.json'), sample('host-check.desired.json'), 'host-check-node-a-unprivileged-port-start-actual.png');
  assert.deepEqual(rows(hc), [['unprivileged-port-start', '+0 -1024 or higher']]);
  assert.deepEqual(hc.context.find(c => c[0] === 'Read on the node'), ['Read on the node', 'ip_unprivileged_port_start = 0']);
  const pr = sheet(sample('prove.failing.json'), sample('prove.desired.json'), 'prove-01-login-attempts-actual.png');
  assert.deepEqual(rows(pr).find(r => r[0] === 'password-no-tls'), ['password-no-tls', 'refused by pg_hba reject', '+allowed -denied']);
});

test('the network images state their scope', () => {
  for (const s of sheets(clean, desired).filter(s => s.pair === 'evidence-06-network')) {
    assert.ok(s.statement.endsWith('This table covers ports 8000 and 9187. Database logins are shown in the login images.'));
  }
});

test('the network image keeps every port that may reach 8000 or 9187', () => {
  const actual = structuredClone(clean);
  Object.assign(actual.network_policy['pg-1'], { everyone: ['7999-9190', '1000-2000', 'UDP/9187'], 'other namespaces': [5432, 'metrics'] });
  const lines = rows(sheet(actual, desired, 'evidence-06-network-actual.png')).filter(r => r[0] === 'pg-1');
  assert.deepEqual(lines.find(r => r[1] === '+everyone'), ['pg-1', '+everyone', '+7999-9190 +UDP/9187']);
  assert.deepEqual(lines.find(r => r[1] === 'other namespaces'), ['pg-1', 'other namespaces', '+metrics']);
});

test('a changed value in the first column marks that value, not the row', () => {
  const actual = structuredClone(clean);
  actual.client_ca.secret = 'other-ca';
  const s = sheet(actual, desired, 'evidence-04-client-ca-actual.png');
  assert.deepEqual(rows(s), [['+other-ca -client-ca', 'CN=example-ca', s.rows[0].cells[2][0].text]]);
  assert.equal(page.rowState(s.rows[0], s.names), '');
});

test('the population says All only for more than one', () => {
  const population = s => s.context.find(([term]) => term === 'Population')[1];
  assert.equal(population(sheet(clean, desired, 'evidence-04-client-ca-actual.png')), '1 certificate');
  assert.equal(population(sheet(clean, desired, 'evidence-04-client-ca-desired.png')), '1 certificate');
  assert.equal(population(sheet(clean, desired, 'evidence-07-container-isolation-actual.png')), 'All 3 instances');
});

test('a missing check or probe keeps its desired values', () => {
  const hc = sample('host-check.clean.json');
  hc.checks.shift();
  const check = sheet(hc, sample('host-check.desired.json'), 'host-check-node-a-selinux-enforcing-actual.png');
  assert.deepEqual(rows(check), [['-selinux-enforcing', '-enforcing']]);
  const pr = sample('prove.clean.json');
  pr.probes.shift();
  const login = sheet(pr, sample('prove.desired.json'), 'prove-01-login-attempts-actual.png');
  assert.deepEqual(rows(login).find(r => r[0] === '-password-tls'), ['-password-tls', '-refused by pg_hba reject', '-denied']);
});

test('per-instance login rules show the desired lines they replace', () => {
  const actual = structuredClone(clean);
  actual.details.pg_hba = { 'pg-1': clean.details.pg_hba, 'pg-2': clean.details.pg_hba.slice(1) };
  const lines = rows(sheet(actual, desired, 'evidence-03-login-rules-actual.png')).filter(r => r[0].includes('pg_hba'));
  assert.equal(lines.filter(r => r[0] === '-pg_hba').length, 9);
  assert.equal(lines.filter(r => r[0] === '+pg_hba on pg-1').length, 9);
  assert.equal(lines.filter(r => r[0] === '+pg_hba on pg-2').length, 8);
});

test('documents that cannot be drawn are refused', () => {
  assert.throws(() => page.plan(clean), /needs its desired document/);
  assert.throws(() => page.plan(desired, desired), /drawn alone/);
  assert.throws(() => page.plan(sample('host-check.desired.json')), /together with a node file/);
  const noSection = structuredClone(clean);
  delete noSection.tls;
  assert.throws(() => page.plan(noSection, desired), /actual document has no key tls/);
  assert.throws(() => page.plan({ ...clean, collected_at: 'yesterday' }, desired), /not a UTC time/);
  assert.throws(() => page.plan({ ...sample('host-check.clean.json'), node: '../x' }, sample('host-check.desired.json')), /not a node name/);
  assert.throws(() => page.plan({ kind: 'actual', source: 'other' }, desired), /unknown source/);
  const unknownCheck = sample('host-check.clean.json');
  unknownCheck.checks[0].id = '../x';
  assert.throws(() => page.plan(unknownCheck, sample('host-check.desired.json')), /unknown host-check check/);
});
