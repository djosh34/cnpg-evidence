#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../lib/test.sh"

# A cut-down desired evidence document and an actual one that matches it.
desired=$(cat <<'JSON'
{"kind": "desired", "source": "evidence", "cluster": {"name": "pg", "namespace": "databases"},
 "postgres": {"superusers": ["postgres"], "roles": ["orders", "postgres"]},
 "tls": {"*": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}},
 "kubernetes": {"impersonate": {"allowed": ["group:system:masters", "kube-apiserver"]},
                "not_served": {"allowed": ["ingressroutes.traefik.io"]},
                "namespaces": {"databases": {"read_secret": {"*": {"allowed": ["group:system:masters"]}}}}},
 "details": {"pg_hba": [{"number": 1, "line": "hostssl orders orders all cert"}, {"number": 2, "line": "host all all all reject"}]}}
JSON
)
actual=$(cat <<'JSON'
{"kind": "actual", "source": "evidence", "collected_at": "2026-01-02T03:04:05Z", "cluster": {"name": "pg", "namespace": "databases"},
 "status": "fail", "violations": ["rule 4: role app exists"],
 "postgres": {"superusers": ["postgres"], "roles": ["postgres", "orders"]},
 "tls": {"pg-1": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}, "pg-4": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}},
 "kubernetes": {"impersonate": ["group:system:masters"],
                "namespaces": {"databases": {"read_secret": {"all (list)": ["group:system:masters"], "client-ca": []}}}},
 "software": {"postgresql": "18.1"},
 "details": {"primary": "pg-4", "instances": ["pg-1", "pg-4"],
             "pg_hba": [{"number": 1, "line": "hostssl orders orders all cert"}, {"number": 2, "line": "host all all all reject"}]}}
JSON
)

# compare NAME EXPECTED DESIRED_FILTER ACTUAL_FILTER: the differences after
# changing each document with a jq filter.
compare() {
  same "$1" "$2" "$(bash "$here/compare.sh" <(jq "$3" <<<"$desired") <(jq "$4" <<<"$actual"))"
}

compare "a matching pair: identity, collection, verdict, versions, primary and instances skipped, order and allowed sets ignored" \
  '[]' . .
compare "an extra role with no rights is an extra row" '[{"path": ["postgres", "roles"], "extra": "unexpected_nologin"}]' \
  . '.postgres.roles += ["unexpected_nologin"]'
compare "a missing role is a missing row" '[{"path": ["postgres", "roles"], "missing": "orders"}]' \
  . '.postgres.roles -= ["orders"]'
compare "a moved pg_hba line is one missing and one extra row per number" \
  '[{"path": ["details", "pg_hba"], "extra": {"number": 1, "line": "host all all all reject"}},
    {"path": ["details", "pg_hba"], "extra": {"number": 2, "line": "hostssl orders orders all cert"}},
    {"path": ["details", "pg_hba"], "missing": {"number": 1, "line": "hostssl orders orders all cert"}},
    {"path": ["details", "pg_hba"], "missing": {"number": 2, "line": "host all all all reject"}}]' \
  . '.details.pg_hba |= (map(.line) | reverse | to_entries | map({number: (.key + 1), line: .value}))'
compare "a member outside an allowed set is extra" '[{"path": ["kubernetes", "impersonate"], "extra": "mallory"}]' \
  . '.kubernetes.impersonate += ["mallory"]'
compare "an allowed set that is present is no difference" '[]' . '.kubernetes.not_served = ["ingressroutes.traefik.io"]'
compare "* covers every Secret" '[{"path": ["kubernetes", "namespaces", "databases", "read_secret", "client-ca"], "extra": "mallory"}]' \
  . '.kubernetes.namespaces.databases.read_secret["client-ca"] = ["mallory"]'
compare "a differing scalar is extra and missing at its path" \
  '[{"path": ["tls", "pg-4", "postgresql"], "extra": "TLSv1.2"}, {"path": ["tls", "pg-4", "postgresql"], "missing": "TLSv1.3"}]' \
  . '.tls["pg-4"].postgresql = "TLSv1.2"'
compare "a key only one side has" \
  '[{"path": ["postgres", "superusers"], "missing": ["postgres"]}, {"path": ["tls", "pg-1", "ciphers"], "extra": "all"}]' \
  . '.tls["pg-1"].ciphers = "all" | del(.postgres.superusers)'
compare "a map without * has no room for other keys" '[{"path": ["postgres", "can_log_in"], "extra": ["orders"]}]' \
  . '.postgres.can_log_in = ["orders"]'
compare "a section only the desired document has is missing" '[{"path": ["tls"], "missing": {"*": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}}}]' \
  . 'del(.tls)'
compare "a section the desired document lacks is skipped" '[]' 'del(.tls)' .

host_desired='{"kind": "desired", "source": "host-check", "checks": [{"id": "selinux", "ok": true, "value": "enforcing, enable_selinux true"},
  {"id": "low-ports", "ok": true, "value": "none"}]}'
host_actual='{"kind": "actual", "source": "host-check", "node": "node-a", "collected": {"selinux": "disabled"},
  "checks": [{"id": "low-ports", "ok": true, "value": "none", "raw": "ip_unprivileged_port_start = 1024"},
             {"id": "selinux", "ok": false, "value": "disabled; enable_selinux unset", "raw": "/sys/fs/selinux/enforce missing"}]}'
same "rows with an id are compared key by key, raw skipped" \
  '[{"path": ["checks", "selinux", "ok"], "extra": false}, {"path": ["checks", "selinux", "ok"], "missing": true},
    {"path": ["checks", "selinux", "value"], "extra": "disabled; enable_selinux unset"}, {"path": ["checks", "selinux", "value"], "missing": "enforcing, enable_selinux true"}]' \
  "$(bash "$here/compare.sh" <(echo "$host_desired") <(echo "$host_actual"))"

prove_desired='{"kind": "desired", "source": "prove", "namespace": "databases", "probes": [{"probe": "password-tls", "expected": "refused", "value": "denied", "ok": true}]}'
prove_actual='{"kind": "actual", "source": "prove", "namespace": "databases", "probes": [
  {"probe": "password-tls", "expected": "refused", "value": "denied", "ok": true, "raw": [{"target": "192.0.2.1:5432", "value": "denied", "actual": "FATAL"}]},
  {"probe": "uid-probes", "expected": "an instance", "value": "not found", "ok": false, "raw": [{"target": "node-a", "value": "not found", "actual": "none"}]}]}'
same "an actual-only row with a probe name is extra, without raw" \
  '[{"path": ["probes"], "extra": {"probe": "uid-probes", "expected": "an instance", "value": "not found", "ok": false}}]' \
  "$(bash "$here/compare.sh" <(echo "$prove_desired") <(echo "$prove_actual"))"

# fails NAME DESIRED ACTUAL: exit 2 and nothing on stdout.
fails() {
  local code=0 out
  out=$(bash "$here/compare.sh" <(echo "$2") <(echo "$3") 2>/dev/null) || code=$?
  same_text "$1: exit code" 2 "$code"
  same_text "$1: nothing on stdout" "" "$out"
}
fails "two actual documents" "$actual" "$actual"
fails "documents of two sources" "$desired" "$host_actual"
fails "a file that is not JSON" "$desired" "kind: actual"
code=0
bash "$here/compare.sh" <(echo "$desired") >/dev/null 2>&1 || code=$?
same_text "one file: usage" 2 "$code"

finish
