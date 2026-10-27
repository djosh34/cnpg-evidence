# Per database: which role logs in, and how. Built from pg_hba, pg_ident and
# the catalog. PostgreSQL uses the first pg_hba line that matches a
# connection, so a line after one that matches every address never applies.
#
# Input: {instances: {<pod>: {pg_hba, pg_ident}}, catalog: {roles, databases}}
# Output: {databases, details}

def understood_hba:
  .error == null
  and (.type | IN("local", "host", "hostssl", "hostnossl", "hostnogssenc"))
  and (.method | IN("reject", "trust", "peer", "cert", "password", "md5", "scram-sha-256"))
  and all(.databases[], .users[]; startswith("/") | not)
  and all(.options[]; test("^(map=|clientcert=|clientname=CN$)"));

def understood_ident:
  .error == null and (.system_user | startswith("/") | not);

def includes($name): any(.[]; . == $name);

def in_group($role): startswith("+") and (.[1:] as $group | $role.member_of | includes($group));

# The three kinds of connection: the pod's unix socket, TCP with TLS, TCP without.
def kinds: "socket", "tls", "plain";

def matches_kind($kind):
  if $kind == "socket" then .type == "local"
  elif $kind == "tls" then .type | IN("host", "hostssl", "hostnogssenc")
  else .type | IN("host", "hostnossl", "hostnogssenc")
  end;

# "all" does not match physical replication, only the keyword "replication" does.
def matches_database($database; $role):
  if $database == "replication" then
    .databases | includes("replication")
  else
    any(.databases[];
      . == "all"
      or . == $database
      or (. == "sameuser" and $database == $role.name)
      or (IN("samerole", "samegroup") and ($role.member_of | includes($database))))
  end;

def matches_role($role):
  any(.users[]; . == "all" or . == $role.name or in_group($role));

def every_address: .type == "local" or .address == "all";

# The lines that can decide one connection: each matching line, up to and
# including the first that matches every address.
def deciding($kind; $database; $role):
  reduce .[] as $line ({lines: [], done: false};
    if .done then .
    elif ($line | matches_kind($kind) and matches_database($database; $role) and matches_role($role)) then
      .lines += [$line] | .done = ($line | every_address)
    else . end)
  | .lines[];

def map_option:
  [.options[] | select(startswith("map=")) | ltrimstr("map=")] | .[0];

# The system users (peer) or certificate common names (cert) that become the role.
def mapped_names($idents; $map; $role):
  if $map == null then
    [$role.name]
  else
    [$idents[]
     | select(.map == $map)
     | select(.role == "all" or .role == $role.name or (.role | in_group($role)))
     | .system_user]
  end;

def login($idents; $kind; $role):
  map_option as $map
  | if .method == "trust" then {no_authentication: true}
    elif .method | IN("password", "md5", "scram-sha-256") then {password: true}
    elif .method == "peer" then {os_users: mapped_names($idents; $map; $role)}
    elif .method == "cert" and $kind == "tls" then {common_names: mapped_names($idents; $map; $role)}
    else {}
    end;

def combined:
  {
    common_names: ([.[].common_names // empty | .[]] | unique),
    os_users: ([.[].os_users // empty | .[]] | unique),
    password: any(.[]; .password == true),
    no_authentication: any(.[]; .no_authentication == true)
  }
  | with_entries(select(.value != [] and .value != false));

def logins($instances; $roles; $database):
  [$roles[] as $role
   | [$instances[] as $instance
      | kinds as $kind
      | $instance.pg_hba
      | deciding($kind; $database; $role)
      | login($instance.pg_ident; $kind; $role)]
   | combined
   | select(. != {})
   | {key: $role.name, value: .}]
  | from_entries;

# One list when every instance has the same lines, else one list per instance.
def per_instance_when_different:
  if (to_entries | map(.value) | unique | length) <= 1 then (to_entries | .[0].value // [])
  else . end;

.catalog.roles as $roles
| (.instances | map_values({
    pg_hba: [.pg_hba[] | select(understood_hba)],
    pg_ident: [.pg_ident[] | select(understood_ident)]
  })) as $instances
| {
    databases: (
      [.catalog.databases[]
       | {key: .name, value: (
           if .allows_connections then {owner, connect, logins: logins($instances; $roles; .name)}
           else {owner, allows_connections: false}
           end)}]
      + [{key: "replication", value: {logins: logins($instances; $roles; "replication")}}]
      | from_entries
    ),
    details: {
      pg_hba: (.instances | map_values([.pg_hba[] | {number, line}]) | per_instance_when_different),
      pg_ident: (.instances | map_values([.pg_ident[] | {number, line}]) | per_instance_when_different),
      pg_hba_not_understood: ([.instances[].pg_hba[] | select(understood_hba | not) | .line] | unique),
      pg_ident_not_understood: ([.instances[].pg_ident[] | select(understood_ident | not) | .line] | unique)
    }
  }
