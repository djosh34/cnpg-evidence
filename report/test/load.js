// Runs the page scripts in one scope, as the browser runs them, and returns
// the functions the tests call.
const fs = require('node:fs');
const path = require('node:path');

const page = path.join(__dirname, '..', 'page');

function load() {
  const code = ['compare.js', 'images.js', 'draw.js'].map(file => fs.readFileSync(path.join(page, file), 'utf8')).join('\n');
  return new Function(`${code}\nreturn { differences, side, plan };`)();
}

function sample(name) {
  return JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'samples', name), 'utf8'));
}

// Values as plain JSON data, for assert.
function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

module.exports = { load, sample, plain };
