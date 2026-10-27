// The literal differences between a desired and an actual document, by the
// same rule as scripts/desired/compare.jq, and a reader that gives each image
// the values of one side with their state.
//
// A difference is {path, extra} for a value only the actual document has, or
// {path, missing} for one only the desired document has. A difference marks a
// value, not a failed check: the scripts' own checks stay the verdict.

const SKIPPED_TOP = ['kind', 'source', 'collected_at', 'cluster', 'node', 'status', 'violations'];
const SKIPPED_PATHS = [['details', 'primary'], ['details', 'instances']];

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function same(a, b) {
  if (Array.isArray(a) || Array.isArray(b)) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((x, i) => same(x, b[i]));
  }
  if (isObject(a) || isObject(b)) {
    if (!isObject(a) || !isObject(b)) return false;
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length && keys.every(k => Object.hasOwn(b, k) && same(a[k], b[k]));
  }
  return a === b;
}

// {"allowed": [...]}: the actual list may hold any of these members and no other.
function isAllowedSet(value) {
  return isObject(value) && Object.keys(value).length === 1 && Array.isArray(value.allowed);
}

// A row of a list is known by its id or probe, else by itself without raw.
function isKeyed(row) {
  return isObject(row) && (Object.hasOwn(row, 'id') || Object.hasOwn(row, 'probe'));
}

function identity(row) {
  if (!isObject(row)) return row;
  if (Object.hasOwn(row, 'id')) return row.id;
  if (Object.hasOwn(row, 'probe')) return row.probe;
  return withoutRaw(row);
}

function withoutRaw(value) {
  if (!isObject(value)) return value;
  const { raw, ...rest } = value;
  return rest;
}

function samePath(a, b) {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}

function differences(desired, actual) {
  if (desired.kind !== 'desired' || actual.kind !== 'actual') throw new Error('compare a desired with an actual document');
  if (desired.source !== actual.source) throw new Error(`the documents come from ${desired.source} and ${actual.source}`);
  const out = [];
  for (const key of Object.keys(actual)) {
    if (!SKIPPED_TOP.includes(key) && Object.hasOwn(desired, key)) walk(out, [key], desired[key], actual[key]);
  }
  for (const key of Object.keys(desired)) {
    if (!SKIPPED_TOP.includes(key) && !Object.hasOwn(actual, key)) out.push({ path: [key], missing: desired[key] });
  }
  return out;
}

function walk(out, path, desired, actual) {
  if (isAllowedSet(desired)) {
    if (!Array.isArray(actual)) {
      out.push({ path, extra: actual });
      return;
    }
    const extra = actual.filter(member => !desired.allowed.some(allowed => same(allowed, member)));
    for (const member of unique(extra)) out.push({ path, extra: member });
  } else if (isObject(desired) && isObject(actual)) {
    for (const key of Object.keys(actual)) {
      const at = [...path, key];
      if (key === 'raw' || SKIPPED_PATHS.some(skipped => samePath(skipped, at))) continue;
      if (Object.hasOwn(desired, key)) walk(out, at, desired[key], actual[key]);
      else if (Object.hasOwn(desired, '*')) walk(out, at, desired['*'], actual[key]);
      else out.push({ path: at, extra: actual[key] });
    }
    for (const key of Object.keys(desired)) {
      if (key !== '*' && !Object.hasOwn(actual, key) && !isAllowedSet(desired[key])) {
        out.push({ path: [...path, key], missing: desired[key] });
      }
    }
  } else if (Array.isArray(desired) && Array.isArray(actual)) {
    for (const row of actual) {
      const match = desired.find(d => same(identity(d), identity(row)));
      if (match === undefined) out.push({ path, extra: withoutRaw(row) });
      else if (isKeyed(row)) walk(out, [...path, identity(row)], match, row);
    }
    for (const row of desired) {
      if (!actual.some(a => same(identity(a), identity(row)))) out.push({ path, missing: row });
    }
  } else if (!same(desired, actual)) {
    out.push({ path, extra: withoutRaw(actual) }, { path, missing: desired });
  }
}

// Each member once, sorted, as jq's unique does for the strings and numbers here.
function unique(values) {
  const out = [];
  for (const value of values) if (!out.some(v => same(v, value))) out.push(value);
  return out.sort((a, b) => (JSON.stringify(a) < JSON.stringify(b) ? -1 : JSON.stringify(a) > JSON.stringify(b) ? 1 : 0));
}

// The value at path: object keys, and in a list of keyed rows, the row's id or probe.
function valueAt(value, path) {
  for (const key of path) {
    if (Array.isArray(value)) value = value.find(row => isKeyed(row) && identity(row) === key);
    else if (isObject(value) && Object.hasOwn(value, key)) value = value[key];
    else return undefined;
  }
  return value;
}

function isPrefix(prefix, path) {
  return prefix.length <= path.length && prefix.every((x, i) => x === path[i]);
}

// One side of a pair, as the images read it. The desired side (diffs null)
// gives its values with state ''. The actual side gives its own values, each
// with state 'extra' when the comparison found it only there, else '', and
// adds the desired values it lacks with state 'missing'. An allowed set reads
// as its members.
function side(doc, diffs) {
  const desired = diffs === null;

  function at(path) {
    const value = valueAt(doc, path);
    return isAllowedSet(value) ? value.allowed : value;
  }

  // What the differences of one kind hold at path: their own value when they
  // sit at path, or the part of it below path when they sit above it.
  function held(kind, path) {
    if (desired) return [];
    return diffs
      .filter(d => Object.hasOwn(d, kind) && isPrefix(d.path, path))
      .map(d => ({ exact: d.path.length === path.length, value: valueAt(d[kind], path.slice(d.path.length)) }))
      .filter(h => h.value !== undefined)
      .map(h => ({ ...h, value: isAllowedSet(h.value) ? h.value.allowed : h.value }));
  }

  function list(path) {
    const value = at(path);
    if (value === undefined) return [];
    if (!Array.isArray(value)) throw new Error(`${path.join('.')} is not a list`);
    return value;
  }

  // The members of the list at path.
  function items(path) {
    const own = list(path);
    const ownState = member => {
      const plain = withoutRaw(member);
      const extra = held('extra', path).some(h => same(h.value, plain) || (Array.isArray(h.value) && h.value.some(x => same(x, plain))));
      return extra ? 'extra' : '';
    };
    const out = own.map(value => ({ value, state: ownState(value) }));
    const ownExists = at(path) !== undefined;
    for (const h of held('missing', path)) {
      const members = h.exact && ownExists ? [h.value] : Array.isArray(h.value) ? h.value : [];
      for (const value of members) out.push({ value, state: 'missing' });
    }
    return out;
  }

  // The keys of the map at path.
  function keys(path) {
    const value = at(path);
    const own = isObject(value) ? Object.keys(value) : [];
    const out = own.map(key => ({ key, state: held('extra', [...path, key]).length ? 'extra' : '' }));
    const add = key => {
      if (!out.some(k => k.key === key)) out.push({ key, state: 'missing' });
    };
    if (!desired) {
      for (const d of diffs) {
        if (Object.hasOwn(d, 'missing') && d.path.length === path.length + 1 && isPrefix(path, d.path)) add(d.path[path.length]);
      }
      for (const h of held('missing', path)) if (isObject(h.value)) Object.keys(h.value).forEach(add);
    }
    return out;
  }

  // The value at path, and on the actual side, the desired value it differs from.
  function values(path) {
    const value = at(path);
    const out = [];
    if (value !== undefined) out.push({ value, state: held('extra', path).length ? 'extra' : '' });
    for (const h of held('missing', path)) out.push({ value: h.value, state: 'missing' });
    return out;
  }

  // The state of member in the list at path, or null when neither side has it.
  function member(path, value) {
    const found = items(path).find(item => same(item.value, value));
    return found ? found.state : null;
  }

  return { desired, at, items, keys, values, member };
}

// The state of something drawn from several values: 'extra' or 'missing' when
// all of them are, else ''.
function allState(states) {
  if (states.length && states.every(s => s === 'extra')) return 'extra';
  if (states.length && states.every(s => s === 'missing')) return 'missing';
  return '';
}

// The state of one value that stands for several: 'extra' when any is.
function anyState(states) {
  return states.includes('extra') ? 'extra' : allState(states);
}
