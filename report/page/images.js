// Every evidence image: its file name, its words, its columns and how its rows
// come from one side of a pair (see side() in compare.js).
//
// A row is {sort, cells}. Each cell is a list of values {text, state}; an empty
// cell reads "None". The first cells name the row; their state marks the whole
// row as extra or missing. Rows are sorted by sort on both sides, so a pair
// keeps one row order. An image with inline: true writes the values of a
// cell on one line, separated by commas.

const KEY = 'Red: a value the desired image does not have. Red and struck through: a desired value missing here.';
const NETWORK_SCOPE = 'This table covers ports 8000 and 9187. Database logins are shown in the login images.';
const PLATFORM_DESIRED = 'The platform components that may hold these rights. Any other account must hold none of them.';
const PLATFORM_ACTUAL = 'Every Kubernetes account that holds one of these rights, as the API server answers for it.';
const SECRETS_NOTE = 'A namespace alone means every Secret in it.';
const OBJECTS_NOTE = 'The objects are the cluster\'s CNPG objects, Endpoints, EndpointSlices and NetworkPolicies; All means every kind of them.';

const yes = state => [{ text: 'Yes', state }];
const no = [{ text: 'No', state: '' }];
const yesNo = state => (state === null ? no : yes(state));
const text = value => (typeof value === 'string' ? value : JSON.stringify(value));
const entry = (value, state) => ({ text: text(value), state });
const entries = list => list.map(item => entry(item.value, item.state));

function byText(a, b) {
  return a.text < b.text ? -1 : a.text > b.text ? 1 : 0;
}

// Rows sorted by their sort key, numbers before text.
function sorted(rows) {
  return rows.sort((a, b) => {
    const x = a.sort;
    const y = b.sort;
    if (typeof x === 'number' && typeof y === 'number') return x - y;
    return String(x) < String(y) ? -1 : String(x) > String(y) ? 1 : 0;
  });
}

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
    const rights = [];
    for (const [key, label] of RIGHTS) {
      const state = s.member(['postgres', key], name);
      if (state !== null) rights.push({ text: label, state });
    }
    return {
      sort: name,
      cells: [
        [entry(name, role.state)],
        yesNo(s.member(['postgres', 'can_log_in'], name)),
        reaches.sort(byText),
        owns.sort(byText),
        yesNo(s.member(['postgres', 'superusers'], name)),
        yesNo(s.member(['postgres', 'can_create_roles'], name)),
        yesNo(s.member(['postgres', 'can_create_databases'], name)),
        rights,
        yesNo(s.member(['postgres', 'have_password'], name)),
        password.sort(byText),
      ],
    };
  });
}

function certificateNames(s) {
  const found = new Map();
  for (const { key: db } of s.keys(['databases'])) {
    for (const { key: role } of s.keys(['databases', db, 'logins'])) {
      for (const cn of s.items(['databases', db, 'logins', role, 'common_names'])) {
        const id = JSON.stringify([cn.value, role]);
        if (!found.has(id)) found.set(id, { cn: cn.value, role, databases: [] });
        found.get(id).databases.push(entry(db, cn.state));
      }
    }
  }
  return [...found.values()].map(({ cn, role, databases }) => {
    const state = allState(databases.map(d => d.state));
    return { sort: `${cn}\n${role}`, cells: [[entry(cn, state)], [entry(role, state)], databases.sort(byText)] };
  });
}

function loginRules(s) {
  const rows = [];
  const add = (file, order, item) => {
    const line = item.value;
    const number = line !== null && typeof line === 'object' && 'number' in line ? line.number : null;
    const words = line !== null && typeof line === 'object' && 'line' in line ? line.line : line;
    rows.push({
      // A desired line comes before the actual line that took its number.
      sort: `${order}\n${String(number ?? '').padStart(6, '0')}\n${item.state === 'missing' ? 0 : 1}\n${text(words)}`,
      cells: [[entry(file, item.state)], number === null ? [] : [entry(String(number), item.state)], [entry(words, item.state)]],
    });
  };
  [['pg_hba', 1], ['pg_ident', 2]].forEach(([file, order]) => {
    const path = ['details', file];
    // When the instances disagree, the lines come as one list per instance.
    if (Array.isArray(s.at(path)) || s.at(path) === undefined) {
      s.items(path).forEach(item => add(file, order, item));
    } else {
      s.keys(path).forEach(({ key }) => s.items([...path, key]).forEach(item => add(`${file} on ${key}`, order, item)));
      // The one desired list the per-instance lists replace.
      for (const { value, state } of s.values(path)) {
        if (state === 'missing' && Array.isArray(value)) value.forEach(line => add(file, order, { value: line, state }));
      }
    }
    s.items(['details', `${file}_not_understood`]).forEach(item => add(`${file}, not understood`, order + 2, item));
  });
  return rows;
}

function clientCa(s) {
  const secret = entries(s.values(['client_ca', 'secret']));
  const certificates = s.items(['client_ca', 'certificates']);
  if (!certificates.length) return [{ sort: '', cells: [secret, [], []] }];
  return certificates.map(({ value, state }) => ({
    sort: text(value.name),
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
    sort: pod.key,
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
        sort: `${pod.key}\n${source.key}`,
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

function containerIsolation(s) {
  const sharing = s.items(['pods_sharing_host_uids']);
  const pods = s.desired ? ['*'] : s.items(['details', 'instances']).map(i => i.value);
  for (const pod of sharing) if (!pods.includes(pod.value)) pods.push(pod.value);
  return pods.map(pod => {
    const shares = sharing.filter(p => p.value === pod).map(p => p.state);
    return { sort: pod, cells: [[entry(instance(pod), '')], shares.length ? [{ text: 'No', state: anyState(shares) }] : yes('')] };
  });
}

function operatorSecrets(s) {
  return [
    ['CNPG operator', 'operator_reads_secrets_in'],
    ['Backup plugin', 'plugin_reads_secrets_in'],
  ].map(([who, key], i) => ({ sort: i, cells: [[entry(who, '')], entries(s.items(['kubernetes', key])).sort(byText)] }));
}

function versions(s) {
  return s.keys(['software']).map(({ key }) => ({ sort: key, cells: [[entry(key, '')], entries(s.values(['software', key]))] }));
}

// --- Kubernetes rights, one row per account ---

// An account as [name, namespace]: a ServiceAccount by its name and
// namespace, a group or user by its name.
function account(subject) {
  const sa = /^system:serviceaccount:([^:]+):(.+)$/.exec(subject);
  if (sa) return [sa[2], sa[1]];
  if (subject.startsWith('group:')) return [`${subject.slice(6)} (group)`, ''];
  return [subject, ''];
}

// Rows for the accounts that hold any right of columns. Each column gives, for
// one subject, the values of its cell.
function rightsTable(s, subjectsFrom, columns) {
  const subjects = new Set();
  for (const path of subjectsFrom(s)) for (const item of s.items(path)) subjects.add(item.value);
  const rows = [];
  for (const subject of subjects) {
    const cells = columns.map(column => column(subject));
    const held = cells.flat().filter(v => v.text !== 'No');
    if (!held.length) continue;
    const [name, ns] = account(subject);
    const state = allState(held.map(v => v.state));
    rows.push({ sort: `${ns}\n${name}`, cells: [[entry(name, state)], ns ? [entry(ns, state)] : [], ...cells] });
  }
  return rows;
}

const k8s = (...path) => ['kubernetes', ...path];
const namespaces = s => s.keys(k8s('namespaces')).map(n => n.key);

function inNamespaces(s, right) {
  return subject => {
    const out = [];
    for (const ns of namespaces(s)) {
      const state = s.member(k8s('namespaces', ns, right), subject);
      if (state !== null) out.push(entry(ns, state));
    }
    return out;
  };
}

// The Secrets of each namespace that subject can read or change. A namespace
// alone stands for every Secret in it: a "*" in the desired document, one of
// allKeys, or a right on each key the namespace has.
function secrets(s, right, allKeys) {
  return subject => {
    const out = [];
    for (const ns of namespaces(s)) {
      const path = k8s('namespaces', ns, right);
      const held = new Map();
      for (const { key } of s.keys(path)) {
        const state = s.member([...path, key], subject);
        if (state !== null) held.set(key, state);
      }
      const keys = s.keys(path).map(k => k.key).filter(k => k !== '*' && !allKeys.includes(k));
      const every = ['*', ...allKeys].some(k => held.has(k)) || (keys.length > 0 && keys.every(k => held.has(k)));
      if (every) out.push({ text: ns, state: anyState([...held.values()]) });
      else for (const key of keys) if (held.has(key)) out.push(entry(`${ns}: ${key === 'all (create)' ? 'new Secrets' : key}`, held.get(key)));
    }
    return out;
  };
}

// The CNPG and network objects subject can change; "All" when it can change
// every kind.
function changeObjects(s) {
  return subject => {
    const out = [];
    for (const ns of namespaces(s)) {
      const kinds = s.keys(k8s('namespaces', ns, 'change'));
      const held = [];
      for (const { key } of kinds) {
        const state = s.member(k8s('namespaces', ns, 'change', key), subject);
        if (state !== null) held.push(entry(key, state));
      }
      if (held.length && held.length === kinds.length) out.push({ text: 'All', state: anyState(held.map(h => h.state)) });
      else out.push(...held);
    }
    return out.sort(byText);
  };
}

const holds = (s, key) => subject => yesNo(s.member(k8s(key), subject));

// The paths whose subjects become rows.
function namespaced(s, rights) {
  const paths = [];
  for (const ns of namespaces(s)) {
    for (const right of rights) {
      const path = k8s('namespaces', ns, right);
      const value = s.at(path);
      if (value === undefined || Array.isArray(value)) paths.push(path);
      if (value === undefined || isObject(value)) for (const { key } of s.keys(path)) paths.push([...path, key]);
    }
  }
  return paths;
}

function platformPods(s) {
  return rightsTable(s, () => namespaced(s, ['exec_into_pods', 'change_pods', 'run_pods']), [
    inNamespaces(s, 'exec_into_pods'),
    inNamespaces(s, 'change_pods'),
    inNamespaces(s, 'run_pods'),
  ]);
}

function platformSecrets(s) {
  return rightsTable(s, () => namespaced(s, ['read_secret', 'write_secret', 'create_pg_tokens']), [
    secrets(s, 'read_secret', ['all (list)', 'all (watch)']),
    secrets(s, 'write_secret', []),
    inNamespaces(s, 'create_pg_tokens'),
  ]);
}

function platformSetup(s) {
  return rightsTable(
    s,
    () => [...namespaced(s, ['change']), k8s('change_webhooks'), k8s('bind_or_escalate_roles'), k8s('impersonate')],
    [changeObjects(s), holds(s, 'change_webhooks'), holds(s, 'bind_or_escalate_roles'), holds(s, 'impersonate')],
  );
}

function platformNodes(s) {
  const rows = rightsTable(
    s,
    () => [k8s('can_open_node_ports'), k8s('proxy_to_nodes'), k8s('request_certificates')],
    [holds(s, 'can_open_node_ports'), holds(s, 'proxy_to_nodes'), holds(s, 'request_certificates'), () => no],
  );
  for (const pod of s.items(['host_network_pods_that_can_bind_low_ports'])) {
    const [ns, name] = String(pod.value).includes('/') ? String(pod.value).split('/', 2) : ['', String(pod.value)];
    rows.push({
      sort: `${ns}\n${name}`,
      cells: [[entry(`pod ${name}`, pod.state)], ns ? [entry(ns, pod.state)] : [], no, no, no, yes(pod.state)],
    });
  }
  return rows;
}

const ACCOUNT_COLUMNS = ['Account', 'Namespace'];

const EVIDENCE = [
  {
    name: '01-accounts',
    sections: ['postgres', 'databases'],
    title: 'Database accounts and their rights',
    control: 'Each database account has only the rights it needs, and no other account exists.',
    desired: 'The database accounts of desired.yaml and of CNPG, with the databases they reach and the rights they hold.',
    actual: 'Every database account in the primary\'s catalog, with the databases its login rules let it reach and the rights it holds.',
    noun: ['database account', 'database accounts'],
    columns: ['Account', 'Logs in', 'Reaches', 'Owns', 'Superuser', 'Create roles', 'Create databases', 'Other rights', 'Password stored', 'Password login'],
    names: 1,
    rows: accounts,
  },
  {
    name: '02-certificate-names',
    sections: ['databases'],
    title: 'Certificate names and the accounts they log in as',
    control: 'A client certificate name maps to one account, and that account reaches one database.',
    desired: 'The certificate names of desired.yaml and CNPG\'s replication name, with the account and databases each may log in to.',
    actual: 'Every certificate name the login rules map to an account, with the databases it reaches.',
    noun: ['certificate name', 'certificate names'],
    columns: ['Certificate name', 'Account', 'Databases'],
    names: 1,
    rows: certificateNames,
  },
  {
    name: '03-login-rules',
    sections: ['details'],
    title: 'Login rules',
    control: 'PostgreSQL has only the approved login rules, in the approved order.',
    desired: 'The pg_hba and pg_ident lines of CNPG and the sample chart, numbered in the order PostgreSQL matches them.',
    actual: 'The pg_hba and pg_ident lines every instance has loaded, numbered in the order PostgreSQL matches them. The first matching pg_hba line decides a login.',
    noun: ['line', 'lines'],
    columns: ['File', 'Number', 'Line'],
    names: 1,
    rows: loginRules,
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
  },
  {
    name: '06-network',
    sections: ['network_policy'],
    title: 'Network access to the instances',
    control: 'From other namespaces, only the CNPG operator reaches the instances on 8000, and only the OTel collectors on 9187.',
    desired: `The sources the NetworkPolicies may admit to each instance. ${NETWORK_SCOPE}`,
    actual: `Per instance, every source the NetworkPolicies admit, and the ports it may connect to. ${NETWORK_SCOPE}`,
    columns: ['Instance', 'Source', 'Ports'],
    names: 2,
    rows: network,
  },
  {
    name: '07-container-isolation',
    sections: ['pods_sharing_host_uids'],
    title: 'Container isolation',
    control: 'Each instance runs in its own user namespace, so its uid 26 is no user on the host.',
    desired: 'Every instance pod sets hostUsers: false.',
    actual: 'Every instance pod, and whether it sets hostUsers: false.',
    noun: ['instance', 'instances'],
    columns: ['Instance', 'Own user namespace'],
    names: 1,
    rows: containerIsolation,
  },
  {
    name: '08-operator-secrets',
    sections: ['kubernetes'],
    title: 'Where the operator and the plugin read Secrets',
    control: 'The CNPG operator and the backup plugin read Secrets only in the operator\'s and the cluster\'s namespaces.',
    desired: 'The namespaces where each may read Secrets.',
    actual: 'Every namespace where each can get, list or watch Secrets.',
    columns: ['Component', 'Namespaces'],
    names: 1,
    rows: operatorSecrets,
  },
  {
    name: '09-platform-pods',
    sections: ['kubernetes'],
    title: 'Platform access: containers and pods',
    control: 'Only approved platform components can enter the instance containers, change their pods or start pods next to them.',
    desired: PLATFORM_DESIRED,
    actual: PLATFORM_ACTUAL,
    noun: ['account', 'accounts'],
    inline: true,
    columns: [...ACCOUNT_COLUMNS, 'Enter containers', 'Change pods', 'Start pods'],
    names: 2,
    rows: platformPods,
  },
  {
    name: '10-platform-secrets',
    sections: ['kubernetes'],
    title: 'Platform access: Secrets',
    control: 'Only approved platform components can read or change the cluster\'s Secrets or create tokens for its account.',
    desired: `${PLATFORM_DESIRED} ${SECRETS_NOTE}`,
    actual: `${PLATFORM_ACTUAL} ${SECRETS_NOTE}`,
    noun: ['account', 'accounts'],
    inline: true,
    columns: [...ACCOUNT_COLUMNS, 'Read Secrets', 'Change Secrets', 'Create tokens'],
    names: 2,
    rows: platformSecrets,
  },
  {
    name: '11-platform-setup',
    sections: ['kubernetes'],
    title: 'Platform access: cluster setup',
    control: 'Only approved platform components can change the CNPG objects, the webhooks or role bindings, or act as another account.',
    desired: `${PLATFORM_DESIRED} ${OBJECTS_NOTE}`,
    actual: `${PLATFORM_ACTUAL} ${OBJECTS_NOTE}`,
    noun: ['account', 'accounts'],
    inline: true,
    columns: [...ACCOUNT_COLUMNS, 'Change objects', 'Change webhooks', 'Grant rights', 'Impersonate'],
    names: 2,
    rows: platformSetup,
  },
  {
    name: '12-platform-nodes-certificates',
    sections: ['kubernetes', 'host_network_pods_that_can_bind_low_ports'],
    title: 'Platform access: nodes and certificates',
    control: 'Only approved platform components can open ports on the nodes, reach the node agents or request certificates. No host-network pod can bind a port below 1024.',
    desired: PLATFORM_DESIRED,
    actual: `${PLATFORM_ACTUAL} Host-network pods that can bind a port below 1024 are listed as pods.`,
    noun: ['account or pod', 'accounts and pods'],
    columns: [...ACCOUNT_COLUMNS, 'Open node ports', 'Node agents', 'Request certificates', 'Bind low ports'],
    names: 2,
    rows: platformNodes,
  },
  {
    name: '13-versions',
    sections: ['software'],
    actualOnly: true,
    title: 'Versions',
    control: 'The software versions the evidence was read from. They have no desired value.',
    actual: 'The Kubernetes, CNPG operator, backup plugin and PostgreSQL versions.',
    columns: ['Software', 'Version'],
    names: 1,
    rows: versions,
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

function hostCheckImage(id) {
  if (!Object.hasOwn(CHECKS, id)) throw new Error(`unknown host-check check ${JSON.stringify(id)}`);
  const [title, control] = CHECKS[id];
  return {
    name: id,
    sections: ['checks'],
    title,
    control,
    desired: 'The value the check has on a node where it passes.',
    actual: 'The value the check read on this node.',
    columns: ['Check', 'Value'],
    names: 1,
    raw: ['checks', id, 'raw'],
    rows: s => {
      const row = s.items(['checks']).find(r => r.value?.id === id);
      if (!row) return [];
      return [{ sort: id, cells: [[entry(id, row.state)], entries(s.values(['checks', id, 'value']))] }];
    },
  };
}

// --- prove.sh ---

function probeGroup(name) {
  if (name.startsWith('uid-')) return '03-host-uid';
  if (name.includes('other-namespace')) return '02-other-namespace';
  return '01-login-attempts';
}

function probes(group) {
  return s => s.items(['probes'])
    .filter(row => probeGroup(String(row.value?.probe)) === group)
    .map(row => {
      const name = row.value.probe;
      return {
        sort: name,
        cells: [[entry(name, row.state)], entries(s.values(['probes', name, 'expected'])), entries(s.values(['probes', name, 'value']))],
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
}));

// The images of a source. host-check has one per check, from both documents.
function imagesOf(source, docs) {
  if (source === 'evidence') return EVIDENCE;
  if (source === 'prove') return PROVE;
  if (source === 'host-check') {
    const ids = [];
    for (const doc of docs) for (const check of doc.checks ?? []) if (!ids.includes(check.id)) ids.push(check.id);
    return ids.map(hostCheckImage);
  }
  throw new Error(`unknown source ${JSON.stringify(source)}`);
}
