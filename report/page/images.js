// Every evidence image: its file name, its words, its columns, its legend and
// how its rows come from one side of a pair (see side() in compare.js).
//
// A row is {cells}, with every: true when it stands for every instance. Each
// cell is a list of values {text, state} or squares {mark, state}; an empty
// cell reads "None". The first cells name the row; an extra row is red in
// those cells only, and a missing row or value is not drawn. draw.js puts the
// correct rows first and the rows with a red mark last, each group in
// alphabetical order of its cells, and the values of a cell the same way. A
// row with section comes in that section's place; a row with keep holds its
// place in the order of keep instead.
//
// A column is a label, or {label, mark, group, wide} for a column of squares,
// the columns of one group sharing a heading above them. A wide one has room
// for names in place of a square. columns may be a function of both
// documents, so both images of a pair get the same columns.
// The legend lists, per side, the marks the image can show as [specimen,
// words]. The specimen is a square 'on', 'off', 'on extra' or 'off extra',
// {text} for a red value or {name} for a red row name.

const NETWORK_SCOPE = 'This table covers ports 8000 and 9187. Database logins are shown in the login images.';
const PLATFORM_DESIRED = 'The platform components that may hold these rights. Any other account must hold none of them.';
const PLATFORM_ACTUAL = 'Every Kubernetes account that holds one of these rights, as the API server answers for it.';
const SECRETS_NOTE = 'A square stands for every Secret in the namespace, a name for that Secret only.';
const OBJECTS_NOTE = 'The objects are the cluster\'s CNPG objects, Endpoints, EndpointSlices and NetworkPolicies. A square stands for every kind of them, a name for that kind only.';

// Filled when the member is there, empty when it is not or only desired.
const square = state => [{ mark: state !== null && state !== 'missing', state: state === 'missing' ? '' : state ?? '' }];
const mark = label => ({ label, mark: true });
const text = value => (typeof value === 'string' ? value : JSON.stringify(value));
const entry = (value, state) => ({ text: text(value), state });
const entries = list => list.map(item => entry(item.value, item.state));

// --- evidence.sh ---

const RIGHTS = [
  ['can_replicate', 'Replication'],
  ['can_bypass_row_security', 'Bypass row security'],
  ['can_run_server_programs', 'Run server programs'],
  ['can_read_server_files', 'Read server files'],
  ['can_write_server_files', 'Write server files'],
  ['can_read_all_data', 'Read all data'],
  ['can_write_all_data', 'Write all data'],
];

function accounts(s) {
  const databases = s.keys(['databases']);
  return s.items(['postgres', 'roles']).map(role => {
    const name = role.value;
    const reaches = [];
    const owns = [];
    const password = [];
    for (const { key: db } of databases) {
      const login = s.keys(['databases', db, 'logins']).find(k => k.key === name);
      if (login) reaches.push(entry(db, login.state));
      for (const owner of s.values(['databases', db, 'owner'])) if (owner.value === name) owns.push(entry(db, owner.state));
      for (const way of s.values(['databases', db, 'logins', name, 'password'])) if (way.value === true) password.push(entry(db, way.state));
      for (const way of s.values(['databases', db, 'logins', name, 'no_authentication'])) {
        if (way.value === true) password.push(entry(`${db}, no password`, way.state));
      }
    }
    const names = new Map();
    for (const { key: db } of databases) {
      for (const cn of s.items(['databases', db, 'logins', name, 'common_names'])) {
        if (!names.has(cn.value)) names.set(cn.value, []);
        names.get(cn.value).push(cn.state);
      }
    }
    // A name is red only when none of its databases has it in the desired document.
    const certificates = [...names].map(([cn, states]) => entry(cn, allState(states)));
    const rights = [];
    for (const [key, label] of RIGHTS) {
      const state = s.member(['postgres', key], name);
      if (state !== null) rights.push({ text: label, state });
    }
    return {
      cells: [
        [entry(name, role.state)],
        square(s.member(['postgres', 'can_log_in'], name)),
        certificates,
        reaches,
        owns,
        square(s.member(['postgres', 'superusers'], name)),
        square(s.member(['postgres', 'can_create_roles'], name)),
        square(s.member(['postgres', 'can_create_databases'], name)),
        rights,
        square(s.member(['postgres', 'have_password'], name)),
        password,
      ],
    };
  });
}

function loginRules(s) {
  const rows = [];
  const parts = item => {
    const line = item.value;
    const number = line !== null && typeof line === 'object' && 'number' in line ? line.number : null;
    const words = line !== null && typeof line === 'object' && 'line' in line ? line.line : line;
    return { number, words: text(words), state: item.state };
  };
  // A line is red when the desired lines lack it. pg_hba is known by number
  // and words, so a line that moved is red too, and its rows keep their number
  // order. PostgreSQL reads every line of a pg_ident map, so pg_ident is a list
  // compared without numbers.
  const add = (file, items, hba) => {
    const lines = items.map(parts);
    const known = l => (hba ? `${l.number}\n${l.words}` : l.words);
    const desired = new Set(lines.filter(l => l.state !== 'extra').map(known));
    for (const line of lines) {
      if (line.state === 'missing') continue;
      const state = desired.has(known(line)) ? '' : 'extra';
      if (hba) {
        rows.push({
          section: 1,
          keep: `${file}\n${String(line.number ?? '').padStart(6, '0')}`,
          cells: [[entry(file, '')], line.number === null ? [] : [entry(String(line.number), state)], [entry(line.words, state)]],
        });
      } else {
        rows.push({ section: 2, cells: [[entry(file, '')], [{ text: '', state: '' }], [entry(line.words, state)]] });
      }
    }
  };
  for (const file of ['pg_hba', 'pg_ident']) {
    const path = ['details', file];
    // When the instances disagree, the lines come as one list per instance,
    // each compared with the one desired list they replace.
    if (Array.isArray(s.at(path)) || s.at(path) === undefined) {
      add(file, s.items(path), file === 'pg_hba');
    } else {
      const replaced = s.values(path).filter(v => v.state === 'missing' && Array.isArray(v.value)).flatMap(v => v.value.map(value => ({ value, state: 'missing' })));
      const own = item => ({ value: item.value, state: 'extra' });
      s.keys(path).forEach(({ key }) => add(`${file} on ${key}`, [...s.items([...path, key]).map(own), ...replaced], file === 'pg_hba'));
    }
  }
  for (const [file, section] of [['pg_hba', 3], ['pg_ident', 4]]) {
    for (const item of s.items(['details', `${file}_not_understood`])) {
      if (item.state !== 'missing') rows.push({ section, cells: [[entry(`${file}, not understood`, '')], [], [entry(item.value, item.state)]] });
    }
  }
  return rows;
}

function clientCa(s) {
  const secret = entries(s.values(['client_ca', 'secret']));
  const certificates = s.items(['client_ca', 'certificates']).filter(c => c.state !== 'missing');
  if (!certificates.length) return [{ cells: [secret, [], []] }];
  return certificates.map(({ value, state }) => ({
    cells: [secret, [entry(value.name, state)], [entry(fingerprint(value.sha256_fingerprint), state)]],
  }));
}

// A SHA-256 fingerprint on two lines of 16 bytes.
function fingerprint(value) {
  const bytes = String(value).split(':');
  return bytes.length === 32 ? `${bytes.slice(0, 16).join(':')}\n${bytes.slice(16).join(':')}` : String(value);
}

const instance = key => (key === '*' ? 'Every instance' : key);

function encryption(s) {
  return s.keys(['tls']).map(pod => ({
    every: pod.key === '*',
    cells: [
      [entry(instance(pod.key), pod.state)],
      entries(s.values(['tls', pod.key, 'postgresql'])),
      entries(s.values(['tls', pod.key, 'metrics'])),
    ],
  }));
}

// Whether a port of a NetworkPolicy may admit 8000 or 9187: "all", either
// number, a range over either, or a named port or other protocol, whose
// number only the pod knows.
function mayReachScope(port) {
  const scope = [8000, 9187];
  if (typeof port === 'number' || /^\d+$/.test(port)) return scope.includes(Number(port));
  const range = /^(\d+)-(\d+)$/.exec(port);
  if (range) return scope.some(p => p >= Number(range[1]) && p <= Number(range[2]));
  return true;
}

function network(s) {
  const rows = [];
  for (const pod of s.keys(['network_policy'])) {
    for (const source of s.keys(['network_policy', pod.key])) {
      const ports = s.items(['network_policy', pod.key, source.key]).filter(p => mayReachScope(p.value));
      if (!ports.length) continue;
      rows.push({
        every: pod.key === '*',
        cells: [
          [entry(instance(pod.key), pod.state)],
          [entry(source.key, source.state)],
          ports.map(p => entry(p.value === 'all' ? 'All ports' : String(p.value), p.state)),
        ],
      });
    }
  }
  return rows;
}

// Isolation is a protection: an empty square, a pod that shares the host's
// ids, is red when the desired document does not allow it.
function containerIsolation(s) {
  const sharing = s.items(['pods_sharing_host_uids']).filter(p => p.state !== 'missing');
  const pods = s.desired ? ['*'] : s.items(['details', 'instances']).map(i => i.value);
  for (const pod of sharing) if (!pods.includes(pod.value)) pods.push(pod.value);
  return pods.map(pod => {
    const shares = sharing.filter(p => p.value === pod).map(p => p.state);
    return {
      every: pod === '*',
      cells: [[entry(instance(pod), '')], [{ mark: !shares.length, state: shares.length ? anyState(shares) : '' }]],
    };
  });
}

function operatorSecrets(s) {
  return [
    ['CNPG operator', 'operator_reads_secrets_in'],
    ['Backup plugin', 'plugin_reads_secrets_in'],
  ].map(([who, key]) => ({ cells: [[entry(who, '')], entries(s.items(['kubernetes', key]))] }));
}

function versions(s) {
  return s.keys(['software']).map(({ key }) => ({ cells: [[entry(key, '')], entries(s.values(['software', key]))] }));
}

// --- Kubernetes rights: one row per account, one square column per namespace under each right ---

// An account as [name, namespace]: a ServiceAccount by its name and
// namespace, a group or user by its name.
function account(subject) {
  const sa = /^system:serviceaccount:([^:]+):(.+)$/.exec(subject);
  if (sa) return [sa[2], sa[1]];
  if (subject.startsWith('group:')) return [`${subject.slice(6)} (group)`, ''];
  return [subject, ''];
}

const k8s = (...path) => ['kubernetes', ...path];
const held = state => state !== null && state !== 'missing';

// The namespaces of both documents that have right, so both images of a pair
// have the same columns.
function namespacesWith(docs, right) {
  const found = new Set();
  for (const doc of docs) {
    for (const [ns, rights] of Object.entries(doc.kubernetes?.namespaces ?? {})) if (Object.hasOwn(rights, right)) found.add(ns);
  }
  return [...found].sort();
}

// Every account a desired value lists: a list, an allowed set, or a map of them.
function listedIn(value) {
  if (Array.isArray(value)) return value;
  if (isAllowedSet(value)) return value.allowed;
  if (isObject(value)) return Object.values(value).flatMap(listedIn);
  return [];
}

// The accounts in the list at path, or in each list of the map at path.
function subjectsAt(s, path) {
  const lists = isObject(s.at(path)) ? s.keys(path).map(({ key }) => [...path, key]) : [path];
  return lists.flatMap(list => s.items(list).map(item => item.value));
}

// A right's cell, for one account and the right at path.
const plainRight = (s, path, subject) => square(s.member(path, subject));

// Filled when subject holds the right on every Secret of the namespace: a "*"
// in the desired document, one of allKeys, or each Secret the namespace has.
// Else the Secrets it holds the right on, or an empty square.
function secretsRight(allKeys) {
  return (s, path, subject) => {
    const found = new Map();
    for (const { key } of s.keys(path)) {
      const state = s.member([...path, key], subject);
      if (held(state)) found.set(key, state);
    }
    const keys = s.keys(path).map(k => k.key).filter(k => k !== '*' && !allKeys.includes(k));
    if (['*', ...allKeys].some(k => found.has(k)) || (keys.length && keys.every(k => found.has(k)))) {
      return [{ mark: true, state: anyState([...found.values()]) }];
    }
    const some = keys.filter(k => found.has(k)).map(k => entry(k === 'all (create)' ? 'new Secrets' : k, found.get(k)));
    return some.length ? some : square(null);
  };
}

// Filled when subject can change every kind of object in the namespace, else
// the kinds it can change, or an empty square.
function objectsRight(s, path, subject) {
  const kinds = s.keys(path);
  const found = kinds.map(({ key }) => entry(key, s.member([...path, key], subject))).filter(e => held(e.state));
  if (found.length && found.length === kinds.length) return [{ mark: true, state: anyState(found.map(e => e.state)) }];
  return found.length ? found : square(null);
}

// A right is {key, label, namespaced, cell, wide}: a namespaced right gets a
// column per namespace under its label, and a wide column has room for names.
function rightColumns(rights) {
  return docs => [
    ...ACCOUNT_COLUMNS,
    ...rights.flatMap(r => (r.namespaced ? namespacesWith(docs, r.key).map(ns => ({ ...mark(ns), group: r.label, wide: r.wide })) : [mark(r.label)])),
  ];
}

// One row per account that holds any of rights. Only an account the desired
// document does not list for any of them is red by name.
function rightRows(rights) {
  return (s, docs) => {
    const paths = rights.flatMap(r => (r.namespaced ? namespacesWith(docs, r.key).map(ns => [r, k8s('namespaces', ns, r.key)]) : [[r, k8s(r.key)]]));
    const known = new Set();
    for (const r of rights) {
      const values = r.namespaced ? Object.values(docs[0].kubernetes?.namespaces ?? {}).map(ns => ns[r.key]) : [docs[0].kubernetes?.[r.key]];
      for (const value of values) for (const subject of listedIn(value)) known.add(subject);
    }
    const subjects = new Set(paths.flatMap(([, path]) => subjectsAt(s, path)));
    const rows = [];
    for (const subject of subjects) {
      const cells = paths.map(([r, path]) => (r.cell ?? plainRight)(s, path, subject));
      if (!cells.flat().some(v => v.mark || Object.hasOwn(v, 'text'))) continue;
      const [name, ns] = account(subject);
      const state = s.desired || known.has(subject) ? '' : 'extra';
      rows.push({ cells: [[entry(name, state)], ns ? [entry(ns, state)] : [], ...cells] });
    }
    return rows;
  };
}

const POD_RIGHTS = [
  { key: 'exec_into_pods', label: 'Enter containers', namespaced: true },
  { key: 'change_pods', label: 'Change pods', namespaced: true },
  { key: 'run_pods', label: 'Start pods', namespaced: true },
];

const SECRET_RIGHTS = [
  { key: 'read_secret', label: 'Read Secrets', namespaced: true, wide: true, cell: secretsRight(['all (list)', 'all (watch)']) },
  { key: 'write_secret', label: 'Change Secrets', namespaced: true, wide: true, cell: secretsRight([]) },
  { key: 'create_pg_tokens', label: 'Create tokens', namespaced: true },
];

const SETUP_RIGHTS = [
  { key: 'change', label: 'Change objects', namespaced: true, wide: true, cell: objectsRight },
  { key: 'change_webhooks', label: 'Change webhooks' },
  { key: 'bind_or_escalate_roles', label: 'Grant rights' },
  { key: 'impersonate', label: 'Impersonate' },
];

const NODE_RIGHTS = [
  { key: 'can_open_node_ports', label: 'Open node ports' },
  { key: 'proxy_to_nodes', label: 'Node agents' },
  { key: 'request_certificates', label: 'Request certificates' },
];

// The accounts with node rights, then the host-network pods that can bind a
// port below 1024.
function platformNodes(s, docs) {
  const off = square(null);
  const rows = rightRows(NODE_RIGHTS)(s, docs).map(row => ({ cells: [...row.cells, off] }));
  for (const pod of s.items(['host_network_pods_that_can_bind_low_ports'])) {
    const [ns, name] = String(pod.value).includes('/') ? String(pod.value).split('/', 2) : ['', String(pod.value)];
    rows.push({ cells: [[entry(`pod ${name}`, pod.state)], ns ? [entry(ns, pod.state)] : [], off, off, off, square(pod.state)] });
  }
  return rows;
}

const ACCOUNT_COLUMNS = ['Account', 'Namespace'];

// --- The legends: [specimen, words] per mark an image type can show ---

const RED_VALUE = words => [{ text: 'Red value' }, words];
const RED_ACCOUNT = [{ name: 'Red account' }, 'An account the desired image does not list'];
const BEYOND = ['on extra', 'Holds the right, but the desired image does not allow it'];

const EVIDENCE = [
  {
    name: '01-accounts',
    sections: ['postgres', 'databases'],
    title: 'Database accounts and their rights',
    control: 'Each database account has only the rights it needs, and no other account exists.',
    desired: 'The database accounts of desired.yaml and of CNPG, with the databases they reach and the rights they hold.',
    actual: 'Every database account in the primary\'s catalog, with the databases its login rules let it reach and the rights it holds.',
    noun: ['database account', 'database accounts'],
    columns: ['Account', mark('Logs in'), 'Certificate names', 'Reaches', 'Owns', mark('Superuser'), mark('Create roles'), mark('Create databases'), 'Other rights', mark('Password stored'), 'Password login'],
    names: 1,
    rows: accounts,
    // The words of the approved accounts image.
    legend: {
      desired: [['on', 'Holds the right'], ['off', 'Does not hold the right']],
      actual: [
        ['on', 'Holds the right'],
        ['off', 'Does not hold the right'],
        ['on extra', 'Holds the right, but the desired image does not give it'],
        RED_VALUE('A certificate name, database or right the desired image does not give the account'),
        [{ name: 'Red account' }, 'An account the desired image does not have'],
      ],
    },
  },
  {
    name: '02-login-rules',
    sections: ['details'],
    title: 'Login rules',
    control: 'PostgreSQL has only the approved login rules, in the approved order.',
    desired: 'The pg_hba and pg_ident lines of CNPG and the sample chart. The pg_hba lines are numbered in the order PostgreSQL matches them.',
    actual: 'The pg_hba and pg_ident lines every instance has loaded. The pg_hba lines are numbered in the order PostgreSQL matches them, and the first matching line decides a login.',
    noun: ['line', 'lines'],
    columns: ['File', 'Number', 'Line'],
    names: 1,
    rows: loginRules,
    legend: {
      desired: [],
      actual: [[{ text: 'Red line' }, 'A line the desired image does not have. A pg_hba line counts by its number, so a line that moved is red too.']],
    },
  },
  {
    name: '03-client-ca',
    sections: ['client_ca'],
    title: 'Client certificate authority',
    control: 'Only the approved CA signs certificates that can log in.',
    desired: 'The Secret the cluster takes client CAs from, and the approved CA certificates.',
    actual: 'The Secret the cluster takes client CAs from, and every certificate in it.',
    noun: ['certificate', 'certificates'],
    columns: ['Secret', 'Certificate', 'SHA-256 fingerprint'],
    names: 0,
    rows: clientCa,
    legend: { desired: [], actual: [RED_VALUE('A Secret or certificate the desired image does not have')] },
  },
  {
    name: '04-encryption',
    sections: ['tls'],
    title: 'Encrypted connections',
    control: 'Every instance accepts only TLS 1.3 on PostgreSQL and answers with TLS on metrics.',
    desired: 'The lowest TLS version PostgreSQL accepts on port 5432, and the TLS version of the metrics port 9187.',
    actual: 'Per instance, the lowest TLS version PostgreSQL accepts on port 5432, and the TLS version the metrics port 9187 answered with.',
    noun: ['instance', 'instances'],
    columns: ['Instance', 'PostgreSQL 5432, lowest TLS', 'Metrics 9187, TLS'],
    names: 1,
    rows: encryption,
    legend: { desired: [], actual: [RED_VALUE('A TLS version or answer the desired image does not have')] },
  },
  {
    name: '05-network',
    sections: ['network_policy'],
    title: 'Network access to the instances',
    control: 'From other namespaces, only the CNPG operator reaches the instances on 8000, and only the OTel collectors on 9187.',
    desired: `The sources the NetworkPolicies may admit to each instance. ${NETWORK_SCOPE}`,
    actual: `Per instance, every source the NetworkPolicies admit, and the ports it may connect to. ${NETWORK_SCOPE}`,
    columns: ['Instance', 'Source', 'Ports'],
    names: 2,
    rows: network,
    legend: {
      desired: [],
      actual: [RED_VALUE('A port the desired image does not allow from this source'), [{ name: 'Red source' }, 'A source the desired image does not have']],
    },
  },
  {
    name: '06-container-isolation',
    sections: ['pods_sharing_host_uids'],
    title: 'Container isolation',
    control: 'Each instance runs in its own user namespace, so its uid 26 is no user on the host.',
    desired: 'Every instance pod sets hostUsers: false.',
    actual: 'Every instance pod, and whether it sets hostUsers: false.',
    noun: ['instance', 'instances'],
    columns: ['Instance', mark('Own user namespace')],
    names: 1,
    rows: containerIsolation,
    legend: {
      desired: [['on', 'Runs in its own user namespace']],
      actual: [['on', 'Runs in its own user namespace'], ['off extra', 'Shares its user ids with the host']],
    },
  },
  {
    name: '07-operator-secrets',
    sections: ['kubernetes'],
    title: 'Where the operator and the plugin read Secrets',
    control: 'The CNPG operator and the backup plugin read Secrets only in the operator\'s and the cluster\'s namespaces.',
    desired: 'The namespaces where each may read Secrets.',
    actual: 'Every namespace where each can get, list or watch Secrets.',
    columns: ['Component', 'Namespaces'],
    names: 1,
    rows: operatorSecrets,
    legend: { desired: [], actual: [RED_VALUE('A namespace the desired image does not allow')] },
  },
  {
    name: '08-platform-pods',
    sections: ['kubernetes'],
    title: 'Platform access: containers and pods',
    control: 'Only approved platform components can enter the instance containers, change their pods or start pods next to them.',
    desired: PLATFORM_DESIRED,
    actual: PLATFORM_ACTUAL,
    noun: ['account', 'accounts'],
    columns: rightColumns(POD_RIGHTS),
    names: 2,
    rows: rightRows(POD_RIGHTS),
    legend: {
      desired: [['on', 'May hold the right in this namespace'], ['off', 'Must not hold the right in this namespace']],
      actual: [['on', 'Holds the right in this namespace'], ['off', 'Does not hold the right in this namespace'], BEYOND, RED_ACCOUNT],
    },
  },
  {
    name: '09-platform-secrets',
    sections: ['kubernetes'],
    title: 'Platform access: Secrets',
    control: 'Only approved platform components can read or change the cluster\'s Secrets or create tokens for its account.',
    desired: `${PLATFORM_DESIRED} ${SECRETS_NOTE}`,
    actual: `${PLATFORM_ACTUAL} ${SECRETS_NOTE}`,
    noun: ['account', 'accounts'],
    columns: rightColumns(SECRET_RIGHTS),
    names: 2,
    rows: rightRows(SECRET_RIGHTS),
    legend: {
      desired: [['on', 'May hold the right in this namespace'], ['off', 'Must not hold the right in this namespace']],
      actual: [
        ['on', 'Holds the right in this namespace'],
        ['off', 'Does not hold the right in this namespace'],
        BEYOND,
        RED_VALUE('A Secret the desired image does not allow the account'),
        RED_ACCOUNT,
      ],
    },
  },
  {
    name: '10-platform-setup',
    sections: ['kubernetes'],
    title: 'Platform access: cluster setup',
    control: 'Only approved platform components can change the CNPG objects, the webhooks or role bindings, or act as another account.',
    desired: `${PLATFORM_DESIRED} ${OBJECTS_NOTE}`,
    actual: `${PLATFORM_ACTUAL} ${OBJECTS_NOTE}`,
    noun: ['account', 'accounts'],
    columns: rightColumns(SETUP_RIGHTS),
    names: 2,
    rows: rightRows(SETUP_RIGHTS),
    legend: {
      desired: [['on', 'May hold the right'], ['off', 'Must not hold the right']],
      actual: [['on', 'Holds the right'], ['off', 'Does not hold the right'], BEYOND, RED_VALUE('A kind of object the desired image does not allow the account'), RED_ACCOUNT],
    },
  },
  {
    name: '11-platform-nodes-certificates',
    sections: ['kubernetes', 'host_network_pods_that_can_bind_low_ports'],
    title: 'Platform access: nodes and certificates',
    control: 'Only approved platform components can open ports on the nodes, reach the node agents or request certificates. No host-network pod can bind a port below 1024.',
    desired: PLATFORM_DESIRED,
    actual: `${PLATFORM_ACTUAL} Host-network pods that can bind a port below 1024 are listed as pods.`,
    noun: ['account or pod', 'accounts and pods'],
    columns: docs => [...rightColumns(NODE_RIGHTS)(docs), mark('Bind low ports')],
    names: 2,
    rows: platformNodes,
    legend: {
      desired: [['on', 'May hold the right'], ['off', 'Must not hold the right']],
      actual: [['on', 'Holds the right'], ['off', 'Does not hold the right'], BEYOND, [{ name: 'Red account or pod' }, 'An account or pod the desired image does not list']],
    },
  },
  {
    name: '12-versions',
    sections: ['software'],
    actualOnly: true,
    title: 'Versions',
    control: 'The software versions the evidence was read from. They have no desired value.',
    actual: 'The Kubernetes, CNPG operator, backup plugin and PostgreSQL versions.',
    columns: ['Software', 'Version'],
    names: 1,
    rows: versions,
    legend: { actual: [] },
  },
];

// --- host-check.sh: one image per check ---

const CHECKS = {
  'selinux-enforcing': ['SELinux mode', 'The kernel enforces SELinux.'],
  'postgres-uid-account': ['Accounts with the PostgreSQL uid or gid', 'Every host account with PostgreSQL\'s uid or primary gid is locked and has a nologin shell.'],
  'postgres-gid-group': ['Members of the PostgreSQL group', 'Every member of the group with PostgreSQL\'s gid is locked and has a nologin shell.'],
  'postgres-sudoers': ['Sudo rules for the PostgreSQL ids', 'No sudoers line names PostgreSQL\'s account, group, uid or gid.'],
  'postgresql-server-absent': ['PostgreSQL server package', 'No PostgreSQL server package is installed on the host.'],
  'storage-dir-mode': ['Data volume directory', 'The directory of the data volumes is 0700 or tighter, owned by root, without an ACL.'],
  'kubelet-pods-mode': ['Pod volume directory', 'The kubelet pod directory is 0750 or tighter, owned by root, without an ACL.'],
  'k3s-kubeconfig-mode': ['k3s admin kubeconfig', 'The k3s kubeconfig is 0600 or tighter, owned by root, without an ACL.'],
  'k3s-selinux': ['SELinux labels for containers', 'containerd gives each container its own SELinux label.'],
  'k3s-network-policy': ['Network policy controller', 'No k3s setting turns off the network policy controller.'],
  'subordinate-ids': ['Subordinate ids', 'No account\'s subordinate id range overlaps the range kubelet gives pods.'],
  'unprivileged-port-start': ['Lowest port without root', 'Only root can bind ports below 1024.'],
  'bind-service-capability': ['Programs that can bind low ports', 'No program under /usr or /opt carries cap_net_bind_service.'],
};

const YES_NO = ['true', 'false', true, false];

// A value of true or false is a square, any other value is text. A check
// whose value is true or false in either document gets a square column.
function hostCheckImage(id, docs) {
  if (!Object.hasOwn(CHECKS, id)) throw new Error(`unknown host-check check ${JSON.stringify(id)}`);
  const [title, control] = CHECKS[id];
  const yesNo = docs.some(doc => YES_NO.includes(doc.checks?.find(c => c.id === id)?.value));
  const value = item => (YES_NO.includes(item.value) ? { mark: item.value === true || item.value === 'true', state: item.state } : entry(item.value, item.state));
  return {
    name: id,
    sections: ['checks'],
    title,
    control,
    desired: 'The value the check has on a node where it passes.',
    actual: 'The value the check read on this node.',
    columns: ['Check', yesNo ? mark('Value') : 'Value'],
    names: 1,
    raw: ['checks', id, 'raw'],
    legend: {
      desired: yesNo ? [['on', 'true'], ['off', 'false']] : [],
      actual: [
        ...(yesNo ? [['on', 'true'], ['off', 'false'], ['on extra', 'true, but the desired image has false'], ['off extra', 'false, but the desired image has true']] : []),
        RED_VALUE('A value other than the one the check passes with'),
        [{ name: 'Red check' }, 'A check the desired image does not have'],
      ],
    },
    rows: s => {
      const row = s.items(['checks']).find(r => r.value?.id === id);
      if (!row) return [];
      return [{ cells: [[entry(id, row.state)], s.values(['checks', id, 'value']).map(value)] }];
    },
  };
}

// --- prove.sh ---

function probeGroup(name) {
  if (name.startsWith('uid-')) return '03-host-uid';
  if (name.includes('other-namespace')) return '02-other-namespace';
  return '01-login-attempts';
}

// prove.sh joins the different results of one attempt with ", ". Each is a
// value of its own, red when the desired value is another.
function results(s, name) {
  const found = s.values(['probes', name, 'value']);
  const desired = found.filter(v => v.state === 'missing').flatMap(v => String(v.value).split(', '));
  return found
    .filter(v => v.state !== 'missing')
    .flatMap(v => (v.state === 'extra' ? String(v.value).split(', ').map(part => entry(part, desired.includes(part) ? '' : 'extra')) : [entry(v.value, '')]));
}

function probes(group) {
  return s => s.items(['probes'])
    .filter(row => probeGroup(String(row.value?.probe)) === group)
    .map(row => {
      const name = row.value.probe;
      return {
        cells: [[entry(name, row.state)], entries(s.values(['probes', name, 'expected'])), results(s, name)],
      };
    });
}

const PROVE = [
  {
    name: '01-login-attempts',
    title: 'Login attempts from a node',
    control: 'No password login works, and a certificate logs in only as its own account.',
    desired: 'Each login attempt and the result it must get. The control attempt must log in, to show the path works.',
  },
  {
    name: '02-other-namespace',
    title: 'Connections from another namespace',
    control: 'A pod in another namespace cannot reach the instances on 5432, 8000 or 9187, nor log in through the Services.',
    desired: 'Each connection attempt from a new pod in its own namespace, and the result it must get. The control attempt must connect.',
  },
  {
    name: '03-host-uid',
    title: 'Access as the host PostgreSQL uid',
    control: 'A host user with PostgreSQL\'s uid cannot reach the socket, the data or the ServiceAccount token of an instance.',
    desired: 'Each attempt as the uid on this node, and the result it must get.',
  },
].map(image => ({
  ...image,
  sections: ['probes'],
  actual: 'Each attempt that was made, and its result. One row stands for every address, pod or uid the attempt was made with.',
  noun: ['attempt', 'attempts'],
  columns: ['Attempt', 'Must be', 'Result'],
  names: 1,
  rows: probes(image.name),
  legend: {
    desired: [],
    actual: [RED_VALUE('A result other than the one the attempt must get'), [{ name: 'Red attempt' }, 'An attempt the desired image does not have']],
  },
}));

// The images of a source. host-check has one per check, from both documents.
function imagesOf(source, docs) {
  if (source === 'evidence') return EVIDENCE;
  if (source === 'prove') return PROVE;
  if (source === 'host-check') {
    const ids = [];
    for (const doc of docs) for (const check of doc.checks ?? []) if (!ids.includes(check.id)) ids.push(check.id);
    return ids.map(id => hostCheckImage(id, docs));
  }
  throw new Error(`unknown source ${JSON.stringify(source)}`);
}
