// The comparison of the page gives the same differences as compare.sh.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { load, sample, plain } = require('./load');

const page = load();
const compareSh = path.join(__dirname, '..', '..', 'scripts', 'desired', 'compare.sh');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'report-compare-'));
test.after(() => fs.rmSync(dir, { recursive: true, force: true }));

// compare.sh's differences, each as one JSON string, sorted.
function script(desired, actual) {
  const files = ['desired', 'actual'].map((name, i) => {
    const file = path.join(dir, `${name}.json`);
    fs.writeFileSync(file, JSON.stringify([desired, actual][i]));
    return file;
  });
  return JSON.parse(execFileSync('bash', [compareSh, ...files], { encoding: 'utf8' })).map(d => JSON.stringify(d)).sort();
}

function js(desired, actual) {
  return plain(page.differences(desired, actual)).map(d => JSON.stringify(d)).sort();
}

for (const source of ['evidence', 'host-check', 'prove']) {
  for (const run of ['clean', 'failing']) {
    test(`${source} ${run}: the same differences as compare.sh`, () => {
      const desired = sample(`${source}.desired.json`);
      const actual = sample(`${source}.${run}.json`);
      const differences = js(desired, actual);
      assert.deepEqual(differences, script(desired, actual));
      assert.equal(differences.length === 0, run === 'clean');
    });
  }
}

const desired = sample('evidence.desired.json');
const clean = sample('evidence.clean.json');

test('an extra role with no rights is one extra value', () => {
  const actual = structuredClone(clean);
  actual.postgres.roles.push('reporting');
  assert.deepEqual(js(desired, actual), [JSON.stringify({ path: ['postgres', 'roles'], extra: 'reporting' })]);
  assert.deepEqual(js(desired, actual), script(desired, actual));
});

test('a missing role is missing from every list that names it', () => {
  const actual = structuredClone(clean);
  for (const key of Object.keys(actual.postgres)) actual.postgres[key] = actual.postgres[key].filter(r => r !== 'streaming_replica');
  const differences = js(desired, actual);
  assert.ok(differences.includes(JSON.stringify({ path: ['postgres', 'roles'], missing: 'streaming_replica' })));
  assert.equal(differences.length, 4);
  assert.deepEqual(differences, script(desired, actual));
});

test('a moved pg_hba line is one missing and one extra row per number', () => {
  const actual = structuredClone(clean);
  const hba = actual.details.pg_hba;
  [hba[0].line, hba[1].line] = [hba[1].line, hba[0].line];
  const differences = js(desired, actual);
  assert.equal(differences.length, 4);
  assert.ok(differences.includes(JSON.stringify({ path: ['details', 'pg_hba'], extra: { number: 1, line: desired.details.pg_hba[1].line } })));
  assert.ok(differences.includes(JSON.stringify({ path: ['details', 'pg_hba'], missing: desired.details.pg_hba[0] })));
  assert.deepEqual(differences, script(desired, actual));
});

test('an allowed set: a member it lacks is extra, a member the actual list lacks is none', () => {
  const actual = structuredClone(clean);
  actual.kubernetes.namespaces.databases.exec_into_pods = ['group:system:masters', 'mallory'];
  assert.deepEqual(js(desired, actual), [JSON.stringify({ path: ['kubernetes', 'namespaces', 'databases', 'exec_into_pods'], extra: 'mallory' })]);
});

test('skipped keys and raw are never compared', () => {
  const actual = structuredClone(clean);
  Object.assign(actual, { status: 'fail', violations: ['x'], collected_at: '2030-01-01T00:00:00Z', software: { postgresql: '1' } });
  actual.details.primary = 'pg-9';
  assert.deepEqual(js(desired, actual), []);
  const prove = sample('prove.clean.json');
  prove.probes[0].raw = [{ target: 'x', value: 'allowed', actual: 'logged in' }];
  assert.deepEqual(js(sample('prove.desired.json'), prove), []);
});

test('documents of two kinds or sources are refused', () => {
  assert.throws(() => page.differences(clean, desired), /compare a desired with an actual document/);
  assert.throws(() => page.differences(desired, sample('prove.clean.json')), /evidence and prove/);
});
