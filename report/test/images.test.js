// What the images show: rows, marks, legends, verdicts and file names, without a browser.
const test = require('node:test');
const assert = require('node:assert/strict');
const { load, sample, plain } = require('./load');

const page = load();
const desired = sample('evidence.desired.json');
const clean = sample('evidence.clean.json');
const failing = sample('evidence.failing.json');

function sheets(doc, desiredDoc) {
  return plain(page.plan(doc, desiredDoc));
}

function sheet(doc, desiredDoc, file) {
  const found = sheets(doc, desiredDoc).find(s => s.file === file);
  assert.ok(found, `no sheet ${file}`);
  return found;
}

// The rows of a sheet as text: each cell's values joined, a square as [x] or
// [ ], a red value or square marked +.
function rows(s) {
  return s.rows.map(r => r.cells.map(c => c.map(v => (v.state === 'extra' ? '+' : '') + (v.text ?? (v.mark ? '[x]' : '[ ]'))).join(' ')));
}

const show = (doc, file) => rows(sheet(doc, desired, `evidence-${file}-actual.png`));
const values = s => s.rows.flatMap(r => r.cells.flat());
const red = s => values(s).filter(v => v.state === 'extra');

const FILES = [
  '01-accounts', '02-login-rules', '03-client-ca', '04-encryption', '05-network', '06-ports', '07-container-isolation',
  '08-operator-secrets', '09-platform-pods', '10-platform-secrets', '11-platform-setup', '12-platform-nodes-certificates',
];

test('evidence: a desired and an actual image per item, numbered without a gap, versions actual only', () => {
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

test('the clean samples mark nothing and pass', () => {
  for (const source of ['evidence', 'host-check', 'prove']) {
    for (const s of sheets(sample(`${source}.clean.json`), sample(`${source}.desired.json`))) {
      assert.deepEqual(red(s), [], s.file);
      assert.equal(s.verdict, s.side === 'actual' ? 'Passed' : null, s.file);
    }
  }
});

test('an actual image fails when it shows a red mark; a desired image has no verdict', () => {
  for (const source of ['evidence', 'host-check', 'prove']) {
    for (const s of sheets(sample(`${source}.failing.json`), sample(`${source}.desired.json`))) {
      if (s.side === 'desired') assert.equal(s.verdict, null, s.file);
      else assert.equal(s.verdict, red(s).length ? 'Failed' : 'Passed', s.file);
    }
  }
  const verdict = file => sheet(failing, desired, `evidence-${file}-actual.png`).verdict;
  assert.equal(verdict('01-accounts'), 'Failed');
  assert.equal(verdict('11-platform-setup'), 'Passed');
});

test('the legend is the same on Passed and Failed images, and an image with no marks has none', () => {
  const failed = sheets(failing, desired);
  for (const s of sheets(clean, desired)) {
    assert.deepEqual(failed.find(f => f.file === s.file).legend, s.legend, s.file);
    if (s.side === 'actual' && s.file !== 'evidence-13-versions-actual.png') assert.ok(s.legend.length, s.file);
  }
  assert.deepEqual(sheet(clean, desired, 'evidence-02-login-rules-desired.png').legend, []);
  assert.deepEqual(sheet(clean, desired, 'evidence-13-versions-actual.png').legend, []);
  // A desired image that shows squares explains them.
  assert.deepEqual(sheet(clean, desired, 'evidence-01-accounts-desired.png').legend, [['on', 'Holds the right'], ['off', 'Does not hold the right']]);
});

test('every yes or no is a square: filled when held, red when desired does not give it', () => {
  const accounts = show(failing, '01-accounts');
  assert.deepEqual(accounts.find(r => r[0] === 'postgres').slice(5, 8), ['[x]', '[x]', '[x]']);
  assert.deepEqual(accounts.find(r => r[0] === 'orders').slice(5, 8), ['[ ]', '[ ]', '+[x]']);
  assert.deepEqual(accounts.find(r => r[0] === 'billing').slice(9), ['+[x]', '+billing']);
  const columns = sheet(failing, desired, 'evidence-01-accounts-actual.png').columns;
  assert.deepEqual(columns.filter(c => c.mark).map(c => c.label), ['Logs in', 'Superuser', 'Create roles', 'Create databases', 'Password stored']);
});

test('a right desired allows but actual does not hold is a normal empty square', () => {
  // desired lets cronjob-controller enter containers; it does not.
  const cronjob = show(clean, '09-platform-pods').find(r => r[0] === 'cronjob-controller');
  assert.deepEqual(cronjob.slice(2, 5), ['[ ]', '[ ]', '[ ]']);
  assert.deepEqual(sheet(clean, desired, 'evidence-09-platform-pods-desired.png').rows.find(r => r.cells[0][0].text === 'cronjob-controller').cells[2], [{ mark: true, state: '' }]);
});

test('a protection that is off is a red empty square', () => {
  assert.deepEqual(show(failing, '07-container-isolation'), [['pg-1', '[x]'], ['pg-2', '[x]'], ['pg-3', '+[ ]']]);
  assert.deepEqual(rows(sheet(failing, desired, 'evidence-07-container-isolation-desired.png')), [['Every instance', '[x]']]);
});

test('an extra row shows only its identity in red', () => {
  assert.deepEqual(show(failing, '01-accounts').find(r => r[0] === '+app'), ['+app', '[ ]', '', '', '', '[ ]', '[ ]', '[ ]', '', '[ ]', '']);
  assert.deepEqual(show(failing, '09-platform-pods').find(r => r[0] === '+mallory'), ['+mallory', '', '[ ]', '[ ]', '[ ]', '[ ]', '[ ]', '[ ]', '[ ]', '[ ]', '[ ]', '+[x]']);
  // A known account with a right beyond desired keeps its name normal.
  assert.deepEqual(show(failing, '09-platform-pods').find(r => r[0] === 'cert-manager-webhook').slice(2, 5), ['[ ]', '[ ]', '+[x]']);
  assert.deepEqual(show(failing, '05-network').find(r => r[1] === '+everyone'), ['pg-3', '+everyone', '+8000 +9187']);
});

test('an actual image never shows a value missing from actual', () => {
  for (const source of ['evidence', 'host-check', 'prove']) {
    for (const s of sheets(sample(`${source}.failing.json`), sample(`${source}.desired.json`))) {
      assert.deepEqual(values(s).filter(v => v.state === 'missing'), [], s.file);
    }
  }
  // cnpg_metrics_exporter no longer reaches template1.
  assert.equal(show(failing, '01-accounts').find(r => r[0] === 'cnpg_metrics_exporter')[3], 'billing orders postgres');
  const actual = structuredClone(clean);
  for (const key of Object.keys(actual.postgres)) actual.postgres[key] = actual.postgres[key].filter(r => r !== 'streaming_replica');
  assert.equal(show(actual, '01-accounts').find(r => r[0].includes('streaming_replica')), undefined);
  assert.equal(sheet(actual, desired, 'evidence-01-accounts-actual.png').verdict, 'Passed');
});

test('a row whose name is only desired is not drawn, and the population counts what is drawn', () => {
  const network = structuredClone(clean);
  delete network.network_policy['pg-1'].otel;
  assert.deepEqual(show(network, '05-network').filter(r => r[0] === 'pg-1').map(r => r[1]), ['cnpg-system operator', 'own node', 'pg pods']);
  const ca = structuredClone(failing);
  ca.client_ca.certificates = ca.client_ca.certificates.filter(c => c.name !== 'CN=example-ca');
  const s = sheet(ca, desired, 'evidence-03-client-ca-actual.png');
  assert.deepEqual(rows(s).map(r => r[1]), ['+CN=other-ca']);
  assert.equal(s.context.find(([term]) => term === 'Population')[1], '1 certificate');
});

test('the accounts image lists the certificate names of each account', () => {
  const s = sheet(failing, desired, 'evidence-01-accounts-actual.png');
  assert.equal(s.columns[2].label, 'Certificate names');
  const accounts = rows(s);
  assert.equal(accounts.find(r => r[0] === 'billing')[2], 'billing-app.test billing-report.test +billing-batch.test');
  assert.equal(accounts.find(r => r[0] === 'streaming_replica')[2], 'pg-replication streaming_replica');
});

test('correct rows first and red rows last, each group alphabetical, and values the same way', () => {
  assert.deepEqual(show(failing, '01-accounts').map(r => r[0]), ['cnpg_metrics_exporter', 'postgres', 'streaming_replica', '+app', 'billing', 'orders']);
  const pods = show(failing, '09-platform-pods').map(r => r[0]);
  assert.deepEqual(pods.slice(-3), ['cert-manager-webhook', '+debug-tunnel', '+mallory']);
  assert.deepEqual(pods.slice(0, -3), [...pods.slice(0, -3)].sort());
  assert.deepEqual(show(failing, '04-encryption').map(r => r[0]), ['pg-1', 'pg-3', 'pg-2']);
  assert.deepEqual(show(failing, '08-operator-secrets'), [['Backup plugin', 'databases'], ['CNPG operator', 'cnpg-system databases +kube-system']]);
});

test('pg_hba keeps its number order, and a moved line is red at its new number', () => {
  const actual = structuredClone(clean);
  const hba = actual.details.pg_hba;
  [hba[0].line, hba[1].line] = [hba[1].line, hba[0].line];
  const lines = show(actual, '02-login-rules').filter(r => r[0] === 'pg_hba');
  assert.deepEqual(lines.map(r => r[1]), hba.map(l => (l.number <= 2 ? `+${l.number}` : String(l.number))));
  assert.deepEqual(lines[0], ['pg_hba', '+1', `+${desired.details.pg_hba[1].line}`]);
});

test('pg_ident lines are compared without numbers: only a new line is red', () => {
  const ident = show(failing, '02-login-rules').filter(r => r[0] === 'pg_ident');
  // The new line 8 pushes billing-report.test from 8 to 9; only the new one is red.
  assert.deepEqual(ident.filter(r => r[2].startsWith('+')), [['pg_ident', '', '+clients billing-batch.test billing']]);
  assert.equal(ident.at(-1)[2], '+clients billing-batch.test billing');
  assert.deepEqual(ident.slice(0, -1).map(r => r[2]), ident.slice(0, -1).map(r => r[2]).sort());
});

test('per-instance login rules mark only what differs from the desired lines', () => {
  const actual = structuredClone(clean);
  actual.details.pg_hba = { 'pg-1': clean.details.pg_hba, 'pg-2': clean.details.pg_hba.slice(1).map((l, i) => ({ ...l, number: i + 1 })) };
  actual.details.pg_ident = { 'pg-1': clean.details.pg_ident, 'pg-2': clean.details.pg_ident.slice(1) };
  const lines = show(actual, '02-login-rules');
  const hba = on => lines.filter(r => r[0] === `pg_hba on ${on}`);
  assert.equal(hba('pg-1').length, clean.details.pg_hba.length);
  assert.ok(hba('pg-1').every(r => !r[2].startsWith('+')));
  // Without its first line, every pg_hba line of pg-2 moved up one number.
  assert.equal(hba('pg-2').length, clean.details.pg_hba.length - 1);
  assert.ok(hba('pg-2').every(r => r[1].startsWith('+') && r[2].startsWith('+')));
  const ident = lines.filter(r => r[0].startsWith('pg_ident'));
  assert.equal(ident.filter(r => r[0] === 'pg_ident on pg-1').length, clean.details.pg_ident.length);
  assert.equal(ident.filter(r => r[0] === 'pg_ident on pg-2').length, clean.details.pg_ident.length - 1);
  assert.deepEqual(ident.filter(r => r[2].startsWith('+')), []);
});

test('the platform grids have one column per namespace under each right', () => {
  const s = sheet(failing, desired, 'evidence-10-platform-secrets-actual.png');
  assert.deepEqual(s.columns.slice(2).map(c => `${c.group}: ${c.label}`), [
    'Read Secrets: cert-manager', 'Read Secrets: cnpg-system', 'Read Secrets: databases',
    'Change Secrets: cert-manager', 'Change Secrets: cnpg-system', 'Change Secrets: databases',
    'Create tokens: databases',
  ]);
  const secrets = rows(s);
  assert.deepEqual(secrets.find(r => r[0] === '+mallory'), ['+mallory', '', '[ ]', '[ ]', '+client-ca', '[ ]', '[ ]', '[ ]', '[ ]']);
  assert.deepEqual(secrets.find(r => r[0] === 'cert-manager-webhook').slice(2, 5), ['cert-manager-webhook-ca', '[ ]', '[ ]']);
  const setup = sheet(clean, desired, 'evidence-11-platform-setup-actual.png');
  assert.deepEqual(setup.columns.slice(2).map(c => c.label), ['databases', 'Change webhooks', 'Grant rights', 'Impersonate']);
  assert.deepEqual(rows(setup).find(r => r[0] === 'system:kube-controller-manager').slice(2), ['endpoints endpointslices', '[ ]', '[ ]', '[ ]']);
  assert.deepEqual(show(failing, '12-platform-nodes-certificates').at(-1), ['+pod node-agent-7xk2p', '+monitoring', '[ ]', '[ ]', '[ ]', '+[x]']);
});

test('a pair shares its columns', () => {
  const all = sheets(failing, desired);
  for (const d of all.filter(s => s.side === 'desired')) {
    assert.deepEqual(all.find(s => s.pair === d.pair && s.side === 'actual').columns, d.columns, d.pair);
  }
});

test('host-check and prove show the value read in red, without the desired value', () => {
  const hc = sheet(sample('host-check.failing.json'), sample('host-check.desired.json'), 'host-check-node-a-unprivileged-port-start-actual.png');
  assert.deepEqual(rows(hc), [['unprivileged-port-start', '+0']]);
  assert.deepEqual(hc.context.find(c => c[0] === 'Read on the node'), ['Read on the node', 'ip_unprivileged_port_start = 0']);
  const pr = sheet(sample('prove.failing.json'), sample('prove.desired.json'), 'prove-01-login-attempts-actual.png');
  assert.deepEqual(rows(pr).at(-1).filter((_, i) => i !== 1), ['password-no-tls', 'refused by pg_hba reject', '+allowed']);
});

test('a host-check value of true or false is a square, red when it is not the desired one', () => {
  const hcDesired = sample('host-check.desired.json');
  const hc = sample('host-check.clean.json');
  const selinux = doc => sheet(doc, hcDesired, 'host-check-node-a-k3s-selinux-actual.png');
  assert.deepEqual(rows(selinux(hc)), [['k3s-selinux', '[x]']]);
  assert.equal(selinux(hc).columns[1].mark, true);
  hc.checks.find(c => c.id === 'k3s-selinux').value = 'false';
  assert.deepEqual(rows(selinux(hc)), [['k3s-selinux', '+[ ]']]);
  assert.equal(selinux(hc).verdict, 'Failed');
  // A value that is neither true nor false stays text.
  hc.checks.find(c => c.id === 'k3s-selinux').value = 'unset';
  assert.deepEqual(rows(selinux(hc)), [['k3s-selinux', '+unset']]);
  assert.equal(selinux(hc).verdict, 'Failed');
});

test('each result prove.sh joined is its own value, red only when it is not the desired one', () => {
  const pr = sheet(sample('prove.failing.json'), sample('prove.desired.json'), 'prove-02-other-namespace-actual.png');
  assert.deepEqual(rows(pr).find(r => r[0] === 'other-namespace-9187'), ['other-namespace-9187', 'pg-1: 9187 pg-2: 9187 pg-3: 9187', 'timeout or connection refused', 'denied +allowed']);
});

test('the network images state their scope', () => {
  for (const s of sheets(clean, desired).filter(s => s.pair === 'evidence-05-network')) {
    assert.ok(s.statement.endsWith('This table covers ports 8000 and 9187. Database logins are shown in the login images.'));
  }
});

test('the network image keeps every port that may reach 8000 or 9187', () => {
  const actual = structuredClone(clean);
  Object.assign(actual.network_policy['pg-1'], { everyone: ['7999-9190', '1000-2000', 'UDP/9187'], 'other namespaces': [5432, 'metrics'] });
  const lines = show(actual, '05-network').filter(r => r[0] === 'pg-1');
  assert.deepEqual(lines.find(r => r[1] === '+everyone'), ['pg-1', '+everyone', '+7999-9190 +UDP/9187']);
  assert.deepEqual(lines.find(r => r[1] === 'other namespaces'), ['pg-1', 'other namespaces', '+metrics']);
});

test('a changed value in the first column marks that value, not the row', () => {
  const actual = structuredClone(clean);
  actual.client_ca.secret = 'other-ca';
  const s = sheet(actual, desired, 'evidence-03-client-ca-actual.png');
  assert.deepEqual(rows(s), [['+other-ca', 'CN=example-ca', s.rows[0].cells[2][0].text]]);
  assert.equal(page.rowState(s.rows[0], s.names), '');
});

test('the population counts the rows drawn, and says All only for more than one', () => {
  const population = s => s.context.find(([term]) => term === 'Population')?.[1];
  assert.equal(population(sheet(clean, desired, 'evidence-03-client-ca-actual.png')), '1 certificate');
  assert.equal(population(sheet(clean, desired, 'evidence-03-client-ca-desired.png')), '1 certificate');
  assert.equal(population(sheet(clean, desired, 'evidence-07-container-isolation-actual.png')), 'All 3 instances');
  assert.equal(population(sheet(clean, desired, 'evidence-07-container-isolation-desired.png')), undefined);
  assert.equal(population(sheet(failing, desired, 'evidence-01-accounts-actual.png')), 'All 6 database accounts');
});

test('a missing check or probe is not drawn', () => {
  const hc = sample('host-check.clean.json');
  hc.checks.shift();
  const check = sheet(hc, sample('host-check.desired.json'), 'host-check-node-a-selinux-enforcing-actual.png');
  assert.deepEqual(rows(check), []);
  const pr = sample('prove.clean.json');
  pr.probes.shift();
  const login = sheet(pr, sample('prove.desired.json'), 'prove-01-login-attempts-actual.png');
  assert.equal(rows(login).find(r => r[0].includes('password-tls')), undefined);
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

test('the ports image lists each Service and the host ports of each instance pod', () => {
  assert.deepEqual(rows(sheet(clean, desired, 'evidence-06-ports-desired.png')).map(r => r.slice(0, 3)), [
    ['Every instance pod', 'databases', 'hostPort'],
    ['pg-r', 'databases', 'ClusterIP'],
    ['pg-read-lb', 'databases', 'LoadBalancer'],
    ['pg-ro', 'databases', 'ClusterIP'],
    ['pg-rw', 'databases', 'ClusterIP'],
    ['pg-rw-lb', 'databases', 'LoadBalancer'],
  ]);
  const read = show(clean, '06-ports').find(r => r[0] === 'pg-read-lb');
  assert.deepEqual(read, ['pg-read-lb', 'databases', 'LoadBalancer', 'cnpg.io/cluster=pg cnpg.io/podRole=instance', 'Local', '5433 -> 5432', '', 'Present', '']);
});

test('the ports image marks a changed Service by its value and an extra Service by its name', () => {
  const ports = show(failing, '06-ports');
  assert.deepEqual(ports.find(r => r[0] === 'pg-read-lb')[4], '+Cluster');
  // An extra Service keeps its type and ports plain; any node port or external IP is red.
  assert.deepEqual(ports.find(r => r[0] === '+pg-debug'), ['+pg-debug', '+databases', 'NodePort', 'cnpg.io/cluster=pg cnpg.io/instanceRole=primary', 'Cluster', '5432 -> 5432', '+30432', 'None', '']);
  assert.deepEqual(ports.find(r => r[0] === '+pg-by-hand'), ['+pg-by-hand', '+otel', 'ClusterIP', 'None', 'None', '6000 -> 5432', '', 'None', '+198.51.100.50']);
  assert.deepEqual(ports.find(r => r[0] === 'pod pg-3'), ['pod pg-3', 'databases', 'hostPort', '', '', '+5432 -> 5432', '', '', '']);
  // Correct rows first, Services and pods together, then the red ones.
  assert.deepEqual(ports.map(r => r[0]), ['pg-r', 'pg-ro', 'pg-rw', 'pg-rw-lb', 'pod pg-1', 'pod pg-2', '+pg-by-hand', '+pg-debug', 'pg-read-lb', 'pod pg-3']);
  assert.equal(sheet(failing, desired, 'evidence-06-ports-actual.png').verdict, 'Failed');
  // A changed selector marks only the part desired lacks.
  const actual = structuredClone(clean);
  actual.ports.services['databases/pg-read-lb'].selector = 'cnpg.io/cluster=pg,cnpg.io/instanceRole=replica';
  assert.equal(show(actual, '06-ports').find(r => r[0] === 'pg-read-lb')[3], 'cnpg.io/cluster=pg +cnpg.io/instanceRole=replica');
});

test('the platform pods grid has a port-forward column, and an extra holder is red', () => {
  const s = sheet(failing, desired, 'evidence-09-platform-pods-actual.png');
  assert.deepEqual(s.columns.slice(2).map(c => `${c.group}: ${c.label}`), [
    'Enter containers: cert-manager', 'Enter containers: cnpg-system', 'Enter containers: databases',
    'Port-forward: databases',
    'Change pods: cert-manager', 'Change pods: cnpg-system', 'Change pods: databases',
    'Start pods: cert-manager', 'Start pods: cnpg-system', 'Start pods: databases',
  ]);
  const off = Array(6).fill('[ ]');
  assert.deepEqual(rows(s).find(r => r[0] === '+debug-tunnel'), ['+debug-tunnel', '+monitoring', '[ ]', '[ ]', '[ ]', '+[x]', ...off]);
  assert.equal(s.verdict, 'Failed');
  assert.equal(show(clean, '09-platform-pods').find(r => r[0] === 'namespace-controller')[5], '[x]');
});

test('the nodes image says that opening node ports covers Traefik IngressRouteTCPs', () => {
  for (const s of sheets(clean, desired).filter(s => s.pair === 'evidence-12-platform-nodes-certificates')) {
    assert.match(s.statement, /IngressRouteTCPs \(ingressroutetcps\.traefik\.io\)/);
  }
});

test('the prove images show where each attempt went, the read LoadBalancer port included', () => {
  const proveDesired = sample('prove.desired.json');
  const login = sheet(sample('prove.clean.json'), proveDesired, 'prove-01-login-attempts-actual.png');
  assert.equal(login.columns[1].label, 'Tried on');
  assert.equal(rows(login).find(r => r[0] === 'password-tls')[1], '192.0.2.10: 5432, 5433 192.0.2.11: 5432, 5433 192.0.2.12: 5432, 5433');
  const other = rows(sheet(sample('prove.clean.json'), proveDesired, 'prove-02-other-namespace-actual.png'));
  assert.equal(other.find(r => r[0] === 'other-namespace-lb')[1], '192.0.2.10: 5432, 5433 192.0.2.11: 5432, 5433 192.0.2.12: 5432, 5433');
  assert.equal(rows(sheet(sample('prove.clean.json'), proveDesired, 'prove-03-host-uid-actual.png'))[0][1], 'pg-1 uid 26');
  assert.equal(rows(sheet(proveDesired, undefined, 'prove-01-login-attempts-desired.png'))[0][1], 'Each LoadBalancer port of each node');
  // No row for the NodePorts.
  assert.ok(sheets(sample('prove.clean.json'), proveDesired).every(s => s.rows.every(r => !r.cells[0][0].text.includes('nodeport'))));
});
