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

const PLATFORM_DESIRED = 'The platform components that may hold these rights. Any other account must hold none of them.';
const PLATFORM_ACTUAL = 'Every Kubernetes account that holds one of these rights, as the API server answers for it.';
const RIGHTS_NOTE = 'PostgreSQL superuser is entering or changing the instance pods, starting pods, reading or writing Secrets, writing ConfigMaps, or changing the CNPG objects in the cluster\'s namespace. Routes are Ingresses and, where the cluster serves them, Traefik IngressRoutes and IngressRouteTCPs.';

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
  ['can_read_ident_view', 'Read pg_ident view'],
  ['can_run_ident_function', 'Run pg_ident function'],
];

// The certificate names and databases of an account, from the certificate
// logins. A name or database is red only when none of its rows is desired.
function accounts(s) {
  const logins = s.items(['certificate_logins']).filter(l => l.state !== 'missing');
  const of = (name, key) => {
    const found = new Map();
    for (const login of logins.filter(l => l.value?.role === name)) {
      if (!found.has(login.value[key])) found.set(login.value[key], []);
      found.get(login.value[key]).push(login.state);
    }
    return [...found].map(([value, states]) => entry(value, allState(states)));
  };
  return s.items(['postgres', 'roles']).map(role => {
    const name = role.value;
    const rights = [];
    for (const [key, label] of RIGHTS) {
      const state = s.member(['postgres', key], name);
      if (state !== null) rights.push({ text: label, state });
    }
    return {
      cells: [
        [entry(name, role.state)],
        square(s.member(['postgres', 'can_log_in'], name)),
        of(name, 'common_name'),
        of(name, 'database'),
        square(s.member(['postgres', 'superusers'], name)),
        square(s.member(['postgres', 'can_create_roles'], name)),
        square(s.member(['postgres', 'can_create_databases'], name)),
        rights,
        square(s.member(['postgres', 'have_password'], name)),
      ],
    };
  });
}

// One row per certificate name, account and database, then each database no
// certificate reaches.
function certificateLogins(s) {
  const logins = s.items(['certificate_logins']).filter(l => l.state !== 'missing');
  const rows = logins.map(({ value, state }) => ({
    cells: [[entry(value.common_name, state)], [entry(value.role, state)], [entry(value.database, state)]],
  }));
  const reached = new Set(logins.map(l => l.value.database));
  for (const db of s.items(['postgres', 'databases'])) {
    if (db.state !== 'missing' && !reached.has(db.value)) rows.push({ cells: [[], [], [entry(db.value, db.state)]] });
  }
  return rows;
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

// prove.sh joins the different results of one attempt with ", ". Each is a
// value of its own, red when the desired value is another.
function results(s, path) {
  const found = s.values(path);
  const desired = found.filter(v => v.state === 'missing').flatMap(v => String(v.value).split(', '));
  return found
    .filter(v => v.state !== 'missing')
    .flatMap(v => String(v.value).split(', ').map(part => entry(part, v.state === 'extra' && !desired.includes(part) ? 'extra' : '')));
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

// --- Kubernetes rights: one row per account, one square column per right ---

// An account as [name, namespace]: a ServiceAccount by its name and
// namespace, a group or user by its name.
function account(subject) {
  const sa = /^system:serviceaccount:([^:]+):(.+)$/.exec(subject);
  if (sa) return [sa[2], sa[1]];
  if (subject.startsWith('group:')) return [`${subject.slice(6)} (group)`, ''];
  return [subject, ''];
}

const PLATFORM_RIGHTS = [
  ['superuser_in_cluster_namespace', 'PostgreSQL superuser'],
  ['create_certificates', 'Create certificates'],
  ['write_routes', 'Write routes'],
  ['run_pods', 'Start pods'],
  ['become_cluster_admin', 'Become cluster-admin'],
];

// One row per account that holds any of the rights. Only an account the
// desired document does not list for any of them is red by name.
function platformRights(s, docs) {
  const known = new Set(PLATFORM_RIGHTS.flatMap(([key]) => {
    const value = docs[0].kubernetes?.[key];
    return isAllowedSet(value) ? value.allowed : Array.isArray(value) ? value : [];
  }));
  const subjects = new Set(PLATFORM_RIGHTS.flatMap(([key]) => s.items(['kubernetes', key]).map(item => item.value)));
  return [...subjects].map(subject => {
    const [name, ns] = account(subject);
    const state = s.desired || known.has(subject) ? '' : 'extra';
    return {
      cells: [[entry(name, state)], ns ? [entry(ns, state)] : [], ...PLATFORM_RIGHTS.map(([key]) => square(s.member(['kubernetes', key], subject)))],
    };
  });
}

const ACCOUNT_COLUMNS = ['Account', 'Namespace'];

// --- The legends: [specimen, words] per mark an image type can show ---

const RED_VALUE = words => [{ text: 'Red value' }, words];
const RED_ACCOUNT = [{ name: 'Red account' }, 'An account the desired image does not list'];
const BEYOND = ['on extra', 'Holds the right, but the desired image does not allow it'];

const EVIDENCE = [
  {
    name: '01-accounts',
    sections: ['postgres', 'certificate_logins'],
    title: 'Database accounts and their rights',
    control: 'Each database account has only the rights it needs, and no other account exists.',
    desired: 'The database accounts of desired.yaml and of CNPG, with the databases they reach and the rights they hold.',
    actual: 'Every database account in the primary\'s catalog, with the databases its login rules let it reach and the rights it holds.',
    noun: ['database account', 'database accounts'],
    columns: ['Account', mark('Logs in'), 'Certificate names', 'Reaches', mark('Superuser'), mark('Create roles'), mark('Create databases'), 'Other rights', mark('Password stored')],
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
    name: '02-certificate-logins',
    sections: ['certificate_logins', 'postgres'],
    title: 'Certificate logins',
    control: 'Each certificate name logs in as one account, and that account reaches one database. No other database exists.',
    desired: 'Each certificate name of desired.yaml and of CNPG, the account it logs in as and the database it reaches, then the databases no certificate reaches.',
    actual: 'Each certificate name the pg_ident lines of every instance map to an account, and the database the certificate pg_hba lines of desired.yaml and CNPG open to it, then the databases no certificate reaches. The login rules image compares the pg_hba lines themselves.',
    noun: ['row', 'rows'],
    columns: ['Certificate name', 'Account', 'Database'],
    names: 3,
    rows: certificateLogins,
    legend: { desired: [], actual: [[{ name: 'Red row' }, 'A certificate name, account or database the desired image does not have']] },
  },
  {
    name: '03-login-rules',
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
    name: '04-client-ca',
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
    name: '05-encryption',
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
    name: '08-platform-rights',
    sections: ['kubernetes'],
    title: 'Platform access',
    control: 'Only approved platform components can get PostgreSQL superuser in the cluster\'s namespace, create certificates, write routes, start pods or become cluster-admin.',
    desired: `${PLATFORM_DESIRED} ${RIGHTS_NOTE}`,
    actual: `${PLATFORM_ACTUAL} ${RIGHTS_NOTE}`,
    noun: ['account', 'accounts'],
    columns: [...ACCOUNT_COLUMNS, ...PLATFORM_RIGHTS.map(([, label]) => mark(label))],
    names: 2,
    rows: platformRights,
    legend: {
      desired: [['on', 'May hold the right'], ['off', 'Must not hold the right']],
      actual: [['on', 'Holds the right'], ['off', 'Does not hold the right'], BEYOND, RED_ACCOUNT],
    },
  },
  {
    name: '09-versions',
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
  'selinux': ['SELinux mode and container labels', 'The kernel enforces SELinux and the generated containerd config enables SELinux labels.'],
  'postgres-account': ['Accounts with the PostgreSQL uid or gid', 'Every host account with PostgreSQL\'s uid or primary gid is locked and has a nologin shell.'],
  'dir-modes': ['Data and pod directories', 'The storage directory is 0700 or tighter and the kubelet pod directory is 0750 or tighter, both root:root without an ACL.'],
  'k3s-secrets': ['k3s credentials and encryption', 'Existing k3s credential files are 0600 or tighter and the server directory is 0700 or tighter, all root:root without an ACL, with secrets encryption enabled on servers.'],
  'low-ports': ['Low ports', 'The unprivileged port threshold is at least 1024 and no file under /usr or /opt carries cap_net_bind_service.'],
  'k3s-network-policy': ['Network policy controller', 'No k3s setting turns off the network policy controller.'],
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
  return name.startsWith('uid-') ? '02-host-uid' : '01-login-attempts';
}

// Where prove.sh makes each attempt, for the desired image.
function where(name) {
  if (name.startsWith('uid-')) return 'An instance pod on this node';
  return 'The rw LoadBalancer port of each node';
}

// Where the attempts were made, from the targets prove.sh records: each
// address with the ports tried on it, and a target without a port, a pod, as
// it is.
function triedOn(s, name) {
  if (s.desired) return [entry(where(name), '')];
  const ports = new Map();
  for (const { target } of s.at(['probes', name, 'raw']) ?? []) {
    const found = /^(\S+):(\d+)$/.exec(target);
    const at = found ? found[1] : target;
    if (!ports.has(at)) ports.set(at, []);
    if (found && !ports.get(at).includes(found[2])) ports.get(at).push(found[2]);
  }
  return [...ports].map(([at, list]) => entry(list.length ? `${at}: ${list.join(', ')}` : at, ''));
}

function probes(group) {
  return s => s.items(['probes'])
    .filter(row => probeGroup(String(row.value?.probe)) === group)
    .map(row => {
      const name = row.value.probe;
      return {
        cells: [[entry(name, row.state)], triedOn(s, name), entries(s.values(['probes', name, 'expected'])), results(s, ['probes', name, 'value'])],
      };
    });
}


const PROVE = [
  {
    name: '01-login-attempts',
    title: 'Login attempts from a node',
    control: 'No password login works, and a certificate logs in only as its own account.',
    desired: 'Each login attempt and the result it must get. The control attempt must log in, to show the path works.',
    tried: 'The login attempts go to every node\'s address on the rw LoadBalancer port.',
  },
  {
    name: '02-host-uid',
    title: 'Access as the host PostgreSQL uid',
    control: 'A host user with PostgreSQL\'s uid cannot reach the socket or the data of an instance.',
    desired: 'Each attempt as the uid on this node, and the result it must get.',
  },
].map(({ tried = '', ...image }) => ({
  ...image,
  sections: ['probes'],
  actual: `Each attempt that was made, where, and its result. One row stands for every address, pod or uid the attempt was made with. ${tried}`.trim(),
  noun: ['attempt', 'attempts'],
  columns: ['Attempt', 'Tried on', 'Must be', 'Result'],
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
