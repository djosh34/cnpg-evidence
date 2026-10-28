// The desired samples are what desired.sh prints for the invented values in
// samples/desired-values.json and the CA in samples/client-ca.pem.
const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { sample } = require('./load');

const samples = path.join(__dirname, '..', 'samples');
const desiredSh = path.join(__dirname, '..', '..', 'scripts', 'desired', 'desired.sh');
const values = fs.readFileSync(path.join(samples, 'desired-values.json'));

for (const [source, args] of [
  ['evidence', ['--ca', path.join(samples, 'client-ca.pem')]],
  ['host-check', ['--source', 'host-check']],
  ['prove', ['--source', 'prove']],
]) {
  test(`${source}.desired.json is what desired.sh prints`, () => {
    const printed = JSON.parse(execFileSync('bash', [desiredSh, ...args], { input: values }));
    assert.deepEqual(sample(`${source}.desired.json`), printed);
  });
}
