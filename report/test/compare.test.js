// The comparison of the page: the differences between a desired and an
// actual document.
const test = require('node:test');
const assert = require('node:assert/strict');
const { load, sample, plain } = require('./load');

const page = load();

function js(desired, actual) {
  return plain(page.differences(desired, actual)).map(d => JSON.stringify(d)).sort();
}

for (const source of ['evidence', 'host-check', 'prove']) {
  test(`${source}: the clean sample has no difference, the failing sample has some`, () => {
    const desired = sample(`${source}.desired.json`);
    assert.deepEqual(js(desired, sample(`${source}.clean.json`)), []);
    assert.ok(js(desired, sample(`${source}.failing.json`)).length > 0);
  });
}

test('a changed value shows the actual value as extra and the desired value as missing', () => {
  const actual = sample('prove.failing.json');
  const differences = js(sample('prove.desired.json'), actual);
  assert.ok(differences.includes(JSON.stringify({ path: ['probes', 'password-no-tls', 'value'], extra: 'allowed' })));
  assert.ok(differences.includes(JSON.stringify({ path: ['probes', 'password-no-tls', 'value'], missing: 'denied' })));
});

const desired = sample('evidence.desired.json');
const clean = sample('evidence.clean.json');

test('an extra role with no rights is one extra value', () => {
  const actual = structuredClone(clean);
  actual.postgres.roles.push('reporting');
  assert.deepEqual(js(desired, actual), [JSON.stringify({ path: ['postgres', 'roles'], extra: 'reporting' })]);
});

test('a missing role is missing from every list that names it', () => {
  const actual = structuredClone(clean);
  for (const key of Object.keys(actual.postgres)) actual.postgres[key] = actual.postgres[key].filter(r => r !== 'streaming_replica');
  const differences = js(desired, actual);
  assert.ok(differences.includes(JSON.stringify({ path: ['postgres', 'roles'], missing: 'streaming_replica' })));
  assert.equal(differences.length, 4);
});

test('a moved pg_hba line is one missing and one extra row per number', () => {
  const actual = structuredClone(clean);
  const hba = actual.details.pg_hba;
  [hba[0].line, hba[1].line] = [hba[1].line, hba[0].line];
  const differences = js(desired, actual);
  assert.equal(differences.length, 4);
  assert.ok(differences.includes(JSON.stringify({ path: ['details', 'pg_hba'], extra: { number: 1, line: desired.details.pg_hba[1].line } })));
  assert.ok(differences.includes(JSON.stringify({ path: ['details', 'pg_hba'], missing: desired.details.pg_hba[0] })));
});

test('an allowed set: a member it lacks is extra, a member the actual list lacks is none', () => {
  const actual = structuredClone(clean);
  actual.kubernetes.run_pods = ['group:system:masters', 'mallory'];
  assert.deepEqual(js(desired, actual), [JSON.stringify({ path: ['kubernetes', 'run_pods'], extra: 'mallory' })]);
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
