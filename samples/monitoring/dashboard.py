# Writes dashboard.json, the Grafana dashboard of the sample's cluster, from
# this file and the critical alerts of rules.yaml. Needs python3 and yq.
#
# Usage:
#   python3 samples/monitoring/dashboard.py                    writes dashboard.json
#   python3 samples/monitoring/dashboard.py --out <file>       writes the dashboard to <file>
#   python3 samples/monitoring/dashboard.py --healthy-test <file>
#       writes a promtool test that checks, on every case of rules.test.yaml,
#       that the Healthy tile counts what the critical alerts see
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load_yaml(path):
    out = subprocess.run(["yq", "-o=json", ".", path], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


# Colours: Grafana's named colours, so both themes get their own shade. Colour
# means state: purple is the primary, "text" a replica, green fine, orange look
# soon, red act.
PRIMARY = "purple"
REPLICA = "text"
OK = "green"
OK_FILL = "dark-green"
WARN = "orange"
BAD = "red"
QUIET = "text"

DS = {"type": "prometheus", "uid": "${datasource}"}

# CNPG series carry the namespace and cluster the scrape adds
# (docs/monitoring.md). cAdvisor series name the pod <cluster>-<serial>.
# Nodes and certificates: all of them, as the Kubernetes cluster holds just
# this PostgreSQL cluster.
S = 'namespace="$namespace", cluster="$cluster"'
PODS = 'namespace="$namespace", pod=~"$cluster-[0-9]+"'
CERTS = "(certmanager_certificate_expiration_timestamp_seconds > 0)"
# Node metrics from cAdvisor. Change these if the collector setup differs.
NODE_CPU = 'sum by (node) (rate(container_cpu_usage_seconds_total{id="/"}[$__rate_interval])) / max by (node) (machine_cpu_cores)'
NODE_MEM = 'max by (node) (container_memory_working_set_bytes{id="/"}) / max by (node) (machine_memory_bytes)'
DISK_DEV = 'id="/", device=~"/dev/(sd|vd|hd|xvd|nvme|mapper|md|dm-).*"'
NODE_DISKS = f"max by (node, device) (container_fs_usage_bytes{{{DISK_DEV}}} / container_fs_limit_bytes{{{DISK_DEV}}})"

# Pod to node from cAdvisor: the postgres container's series carry the pod and
# the node the scrape adds. The node last seen within the hour, so an
# instance on a lost node keeps its node's name.
POD_NODE = (
    "(topk by (namespace, pod) (1, max by (namespace, pod, node) (max_over_time(timestamp("
    f'container_memory_working_set_bytes{{{PODS}, container="postgres"}})[1h:1m]))) * 0 + 1)'
)


def by_node(expr):
    """Adds the node label; an instance with no node seen in the hour is "unknown node", never its pod name."""
    return (
        f"(({expr}) * on (namespace, pod) group_left (node) {POD_NODE})"
        f' or on (namespace, pod) label_replace({expr}, "node", "unknown node", "", "")'
    )


# Who is primary: PostgreSQL (not in recovery) and CNPG's primary lease
# (kube_lease_owner from kube-state-metrics).
RR = f"max by (namespace, pod) (cnpg_pg_replication_in_recovery{{{S}}})"
WW = f"max by (namespace, pod) (cnpg_pg_replication_is_wal_receiver_up{{{S}}})"
LEASE = (
    "label_replace(max by (namespace, lease_holder) "
    '(kube_lease_owner{namespace="$namespace", lease="$cluster", owner_kind="Cluster"}), '
    '"pod", "$1", "lease_holder", "(.+)")'
)
# Lease holder 1, other instances 0; with no lease data at all, PostgreSQL alone decides.
H = (
    f"((max by (namespace, pod) ({LEASE}) * 0 + 1)"
    f" or on (namespace, pod) ({RR} * 0 and on () count({LEASE}))"
    f" or on (namespace, pod) (1 - {RR}))"
)
# Instance state:
#  2 primary (lease and not in recovery)   1 replica streaming   0 replica not streaming
# -3 not in recovery without the lease     -4 lease held but still in recovery (promotion under way)
# -5 writes blocked                        -6 fenced
# -1 exporter up, PostgreSQL down          -2 not reporting
STATE0 = (
    f"((1 - {RR}) * {H} * 2 + {RR} * (1 - {H}) * {WW} - (1 - {RR}) * (1 - {H}) * 3 - {RR} * {H} * 4)"
    f" or on (namespace, pod) (max by (namespace, pod) (cnpg_collector_up{{{S}}}) == 0) - 1"
    f" or on (namespace, pod) (max by (namespace, pod) (max_over_time(cnpg_collector_up{{{S}}}[1h])) * 0 - 2)"
)
# Writes blocked: the primary has fewer standbys connected than the number of
# synchronous standbys it needs. cnpg_collector_sync_replicas{value="observed"}
# is the number in synchronous_standby_names, not a count of standbys.
WRITES_BLOCKED = (
    f"(max by (namespace, pod) (cnpg_pg_replication_streaming_replicas{{{S}}})"
    f' < max by (namespace, pod) (cnpg_collector_sync_replicas{{{S}, value="expected"}}))'
)
STATE1 = f"((({STATE0}) == 2 and on (namespace, pod) {WRITES_BLOCKED}) * 0 - 5) or on (namespace, pod) ({STATE0})"
STATE = f"((max by (namespace, pod) (cnpg_collector_fencing_on{{{S}}}) == 1) * 0 - 6) or on (namespace, pod) ({STATE1})"
STATE_MAP = {
    "2": ("Primary", PRIMARY),
    "1": ("Replica", OK),
    "0": ("Not streaming", BAD),
    "-5": ("Writes blocked", BAD),
    "-3": ("Primary without lease", BAD),
    "-4": ("Promoting", WARN),
    "-6": ("Fenced", WARN),
    "-1": ("PostgreSQL down", BAD),
    "-2": ("Not reporting", BAD),
}


def state_mappings(replica_color):
    options = {
        k: {"text": t, "color": (replica_color if k == "1" else c), "index": i}
        for i, (k, (t, c)) in enumerate(STATE_MAP.items())
    }
    return [{"type": "value", "options": options}]


# The role label ("primary" or "replica") joined onto per-pod series, from the same state.
ROLE = (
    f'(label_replace(({STATE0}) == 2, "role", "primary", "", "") * 0 + 1)'
    f' or on (namespace, pod) (label_replace(({STATE0}) != 2, "role", "replica", "", "") * 0 + 1)'
)


def named(expr):
    return by_node(f"({expr}) * on (namespace, pod) group_left (role) ({ROLE})")


PRIMARY_ONLY = f"on (namespace, pod) (({STATE0}) == 2)"
BACKUP_AGE = f"time() - max(barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{{{S}}} > 0)"


# ---- Healthy: the critical alerts of rules.yaml, counted now.

RECORDED = re.compile(r"\b[a-z_]+:[a-z_]+\b")


def critical_alerts(rules):
    """Returns the critical alerts' names and expressions, with the recording rules they read written out.

    The databases rule becomes the dashboard's namespace and cluster, so the
    tile counts the selected cluster, whatever rules.yaml lists.
    """
    records = {}
    alerts = []
    for group in rules["groups"]:
        for rule in group["rules"]:
            if "record" in rule:
                records[rule["record"]] = rule
            elif rule.get("labels", {}).get("severity") == "critical":
                alerts.append((rule["alert"], rule["expr"]))

    def expand(expr):
        def one(match):
            rule = records.get(match.group(0))
            if rule is None:
                sys.exit(f"dashboard.py: {match.group(0)} is not recorded in rules.yaml")
            labels = rule.get("labels", {})
            if labels and set(labels) != {"namespace", "cluster"}:
                sys.exit(f"dashboard.py: {rule['record']} has labels other than namespace and cluster")
            if labels:
                return 'label_replace(label_replace(vector(1), "namespace", "$namespace", "", ""), "cluster", "$cluster", "", "")'
            return f"({expand(rule['expr'].strip())})"

        return RECORDED.sub(one, expr)

    return [(name, " ".join(expand(expr).split())) for name, expr in alerts]


def healthy(rules):
    alerts = critical_alerts(rules)
    if not alerts:
        sys.exit("dashboard.py: rules.yaml has no critical alerts")
    return " + ".join(f"(count({expr}) or vector(0))" for _, expr in alerts), [name for name, _ in alerts]


# ---- Panels

_id = [0]


def nid():
    _id[0] += 1
    return _id[0]


def tgt(expr, legend="", instant=False, fmt="time_series", ref="A"):
    return {"datasource": DS, "expr": expr, "legendFormat": legend, "refId": ref, "range": not instant, "instant": instant, "format": fmt}


def thresholds(*steps):
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in steps]}


def role_overrides():
    return [
        {"matcher": {"id": "byRegexp", "options": ".*primary.*"},
         "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": PRIMARY}}, {"id": "custom.lineWidth", "value": 2}]},
        {"matcher": {"id": "byRegexp", "options": ".*replica.*"},
         "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": REPLICA}}, {"id": "custom.lineWidth", "value": 1}]},
    ]


def ts(title, desc, targets, gp, unit="short", overrides=None, thr=None, thr_style="off", decimals=None, soft_max=None, fixed=None):
    custom = {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 0, "showPoints": "never", "spanNulls": False,
              "axisSoftMin": 0, "axisBorderShow": False, "gradientMode": "none", "lineInterpolation": "linear",
              "thresholdsStyle": {"mode": thr_style}, "axisPlacement": "auto", "axisLabel": ""}
    if soft_max is not None:
        custom["axisSoftMax"] = soft_max
    d = {"unit": unit, "custom": custom, "color": {"mode": "fixed", "fixedColor": fixed} if fixed else {"mode": "palette-classic"},
         "thresholds": thr or thresholds((None, "transparent"))}
    if decimals is not None:
        d["decimals"] = decimals
    return {"id": nid(), "type": "timeseries", "title": title, "description": desc, "datasource": DS, "gridPos": gp, "transparent": True,
            "targets": targets, "fieldConfig": {"defaults": d, "overrides": overrides or []},
            "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                        "tooltip": {"mode": "multi", "sort": "desc"}}}


def stat(title, desc, targets, gp, unit="short", thr=None, mappings=None, color_mode="background_solid", text_mode="auto",
         decimals=None, no_value=None, transparent=False, orientation="auto", text_size=None):
    d = {"unit": unit, "thresholds": thr or thresholds((None, OK)), "mappings": mappings or [], "color": {"mode": "thresholds"}}
    if decimals is not None:
        d["decimals"] = decimals
    if no_value is not None:
        d["noValue"] = no_value
    opts = {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "colorMode": color_mode, "graphMode": "none",
            "textMode": text_mode, "justifyMode": "center", "orientation": orientation, "wideLayout": True, "showPercentChange": False}
    if text_size:
        opts["text"] = text_size
    return {"id": nid(), "type": "stat", "title": title, "description": desc, "datasource": DS, "gridPos": gp, "transparent": transparent,
            "targets": targets, "fieldConfig": {"defaults": d, "overrides": []}, "options": opts}


def bars(title, desc, target, gp, unit, mx, thr, decimals=0):
    return {"id": nid(), "type": "bargauge", "title": title, "description": desc, "datasource": DS, "gridPos": gp, "transparent": True,
            "targets": [target],
            "fieldConfig": {"defaults": {"unit": unit, "decimals": decimals, "min": 0, "max": mx, "color": {"mode": "thresholds"}, "thresholds": thr},
                            "overrides": []},
            "options": {"orientation": "horizontal", "displayMode": "basic", "valueMode": "color", "namePlacement": "left", "showUnfilled": True,
                        "sizing": "manual", "minVizHeight": 16, "maxVizHeight": 22, "minVizWidth": 8,
                        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "legend": {"showLegend": False}}}


def row(title, y, collapsed=False, panels=None):
    return {"id": nid(), "type": "row", "title": title, "collapsed": collapsed, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": panels or []}


def gp(x, y, w, h):
    return {"x": x, "y": y, "w": w, "h": h}


def dashboard(rules):
    _id[0] = 0
    problems, alert_names = healthy(rules)
    panels = []
    y = 0
    H5 = 5
    # ---- The strip: the only filled tiles on the page.
    panels.append(stat(
        "Healthy",
        "Counts the problems the critical alerts of rules.yaml see now, without their waiting time; "
        "each pod, volume, certificate or check counts once: " + ", ".join(alert_names) + ".",
        [tgt(problems, instant=True)], gp(0, y, 4, H5),
        thr=thresholds((None, OK_FILL), (1, BAD)),
        mappings=[{"type": "value", "options": {"0": {"text": "Yes", "index": 0}, "1": {"text": "1 problem", "index": 1},
                   **{str(n): {"text": f"{n} problems", "index": n} for n in range(2, 30)}}}],
        text_size={"valueSize": 34}))
    panels.append(stat(
        "Instances",
        "Each instance by the node it runs on. Primary: PostgreSQL accepts writes and holds CNPG's primary lease; both must agree. "
        "Writes blocked: the primary has fewer standbys connected than the synchronous standbys it needs, so every write waits; reads still work. "
        "A connected standby does not prove that it confirms commits.",
        [tgt(f"sort_desc({by_node(STATE)})", "{{node}}", instant=True)], gp(4, y, 8, H5),
        thr=thresholds((None, BAD)), text_mode="value_and_name", orientation="vertical", mappings=state_mappings(OK_FILL),
        text_size={"titleSize": 14, "valueSize": 24}))
    panels.append(stat(
        "Replica lag", "Largest replay delay of any replica, in seconds. 0 when caught up. Orange over 1 s, red over 15 s.",
        [tgt(f"max(cnpg_pg_replication_lag{{{S}}})", instant=True)], gp(12, y, 3, H5), unit="s", decimals=1,
        thr=thresholds((None, OK_FILL), (1, WARN), (15, BAD)), text_size={"valueSize": 30}))
    panels.append(stat(
        "Rule checks", "Role and mapping checks (CNPG custom query). Violations found; missing means the checks stopped reporting.",
        [tgt(f"sum(max by (rule, check) (cnpg_compliance_violations{{{S}}}))", instant=True)], gp(15, y, 3, H5),
        thr=thresholds((None, OK_FILL), (1, BAD)), no_value="Missing",
        mappings=[{"type": "value", "options": {"0": {"text": "All pass", "index": 0}}},
                  {"type": "special", "options": {"match": "null", "result": {"text": "Missing", "color": BAD, "index": 1}}}],
        text_size={"valueSize": 24}))
    panels.append(stat(
        "Certificates",
        "Days until the first cert-manager certificate expires. Certificates made without cert-manager are not counted. "
        "Orange under 14 days, red under 3.",
        [tgt(f"min(({CERTS} - time()) / 86400)", instant=True)], gp(18, y, 3, H5), unit="suffix: days", decimals=0,
        thr=thresholds((None, BAD), (3, WARN), (14, OK_FILL)), text_size={"valueSize": 30}))
    panels.append(stat(
        "Disks", "The fullest disk of any node. Every disk is listed under Nodes. Orange over 80 %, red over 90 %.",
        [tgt(f"topk(1, {NODE_DISKS})", "{{node}} {{device}}", instant=True)], gp(21, y, 3, H5), unit="percentunit", decimals=0,
        thr=thresholds((None, OK_FILL), (0.8, WARN), (0.9, BAD)), text_mode="value_and_name", text_size={"titleSize": 12, "valueSize": 30}))
    y += H5

    # ---- Leader and replicas over time, right under the strip.
    panels.append({
        "id": nid(), "type": "state-timeline", "title": "Leader and replicas",
        "description": "State of each instance over time. Purple is the leader (primary); a purple band moving to another node is a failover or switchover.",
        "datasource": DS, "gridPos": gp(0, y, 24, 7), "transparent": True,
        "targets": [tgt(by_node(STATE), "{{node}}")],
        "fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": BAD},
                                     "custom": {"fillOpacity": 85, "lineWidth": 0}, "mappings": state_mappings(OK_FILL)}, "overrides": []},
        "options": {"showValue": "auto", "rowHeight": 0.85, "mergeValues": True, "alignValue": "left",
                    "legend": {"showLegend": False}, "tooltip": {"mode": "single"}}})
    y += 7

    # ---- Workload
    panels.append(row("Workload", y))
    y += 1
    panels.append(ts(
        "Transactions per second", "Commits and rollbacks per second, per instance.",
        [tgt(named(f"sum by (namespace, pod) (rate(cnpg_pg_stat_database_xact_commit{{{S}}}[$__rate_interval])"
                   f" + rate(cnpg_pg_stat_database_xact_rollback{{{S}}}[$__rate_interval]))"), "{{node}} {{role}}")],
        gp(0, y, 8, 8), unit="suffix: tps", overrides=role_overrides()))
    conn_over = role_overrides() + [{"matcher": {"id": "byName", "options": "max_connections"},
                                     "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": QUIET}},
                                                    {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [6, 4]}}]}]
    panels.append(ts(
        "Connections", "Open backends per instance; the dashed line is max_connections.",
        [tgt(named(f"sum by (namespace, pod) (cnpg_backends_total{{{S}}})"), "{{node}} {{role}}"),
         tgt(f'max(cnpg_pg_settings_setting{{name="max_connections", {S}}})', "max_connections", ref="B")],
        gp(8, y, 8, 8), overrides=conn_over))
    panels.append(ts(
        "Longest open transaction", "Age of the oldest running transaction per instance. Long ones block vacuum.",
        [tgt(named(f"max by (namespace, pod) (cnpg_backends_max_tx_duration_seconds{{{S}}})"), "{{node}} {{role}}")],
        gp(16, y, 8, 8), unit="s", overrides=role_overrides(),
        thr=thresholds((None, "transparent"), (300, WARN)), thr_style="dashed"))
    y += 8

    # ---- Replication
    panels.append(row("Replication", y))
    y += 1
    panels.append(ts(
        "Replica lag", "Seconds each replica is behind in replaying the primary's changes.",
        [tgt(by_node(f"max by (namespace, pod) (cnpg_pg_replication_lag{{{S}}}) and on (namespace, pod) (({STATE}) != 2)"), "{{node}}")],
        gp(0, y, 12, 8), unit="s", fixed=REPLICA, thr=thresholds((None, "transparent"), (1, WARN), (15, BAD)), thr_style="dashed"))
    panels.append(ts(
        "Bytes not yet replayed", "WAL the primary has sent that each replica has not replayed yet.",
        [tgt(by_node(f'label_replace(max by (namespace, application_name) (cnpg_pg_stat_replication_replay_diff_bytes{{{S}}}), '
                     f'"pod", "$1", "application_name", "(.+)")'), "{{node}}")],
        gp(12, y, 12, 8), unit="bytes", fixed=REPLICA))
    y += 8

    # ---- Certificates and checks
    panels.append(row("Certificates and rule checks", y))
    y += 1
    panels.append(bars(
        "Days until each cert-manager certificate expires",
        "Every Certificate that cert-manager manages in the Kubernetes cluster. Certificates made without cert-manager, "
        "such as a CA or client certificate supplied as a Secret, have no expiry metric and are not shown. Orange under 14 days, red under 3.",
        tgt(f"sort(({CERTS} - time()) / 86400)", "{{name}}  ({{namespace}})", instant=True), gp(0, y, 12, 8), "suffix: days", 90,
        thresholds((None, BAD), (3, WARN), (14, OK))))
    panels.append({
        "id": nid(), "type": "table", "title": "Rule checks",
        "description": "Each role and mapping check from the CNPG custom query and how many violations it finds.",
        "datasource": DS, "gridPos": gp(12, y, 12, 8), "transparent": True,
        "targets": [tgt(f"max by (rule, check) (cnpg_compliance_violations{{{S}}})", instant=True, fmt="table")],
        "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True},
                                                           "renameByName": {"rule": "Rule", "check": "Check", "Value": "Violations"},
                                                           "indexByName": {"rule": 0, "check": 1, "Value": 2}}}],
        "fieldConfig": {"defaults": {"custom": {"align": "left", "cellOptions": {"type": "auto"}}, "color": {"mode": "thresholds"},
                                     "thresholds": thresholds((None, "text"), (1, BAD))},
                        "overrides": [{"matcher": {"id": "byName", "options": "Violations"},
                                       "properties": [{"id": "custom.cellOptions", "value": {"type": "color-text"}},
                                                      {"id": "custom.width", "value": 110}]}]},
        "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}}})
    y += 8

    # ---- Nodes
    panels.append(row("Nodes", y))
    y += 1
    panels.append(ts("CPU", "Share of each node's CPU in use.", [tgt(NODE_CPU, "{{node}}")],
                     gp(0, y, 8, 7), unit="percentunit", soft_max=1, thr=thresholds((None, "transparent"), (0.9, WARN)), thr_style="dashed"))
    panels.append(ts("Memory", "Share of each node's memory in use (working set).", [tgt(NODE_MEM, "{{node}}")],
                     gp(8, y, 8, 7), unit="percentunit", soft_max=1, thr=thresholds((None, "transparent"), (0.9, WARN)), thr_style="dashed"))
    panels.append(bars("Disks", "Every disk of every node. Orange over 80 %, red over 90 %.",
                       tgt(f"sort_desc({NODE_DISKS})", "{{node}}  {{device}}", instant=True), gp(16, y, 8, 7), "percentunit", 1,
                       thresholds((None, OK), (0.8, WARN), (0.9, BAD))))
    y += 7

    # ---- Detail, collapsed
    detail = [
        ts("Volume use", "PGDATA volume use per instance.",
           [tgt(by_node('label_replace(max by (namespace, persistentvolumeclaim) (1 - kubelet_volume_stats_available_bytes{namespace="$namespace"}'
                        ' / kubelet_volume_stats_capacity_bytes{namespace="$namespace"}), "pod", "$1", "persistentvolumeclaim", "($cluster-[0-9]+)(-wal)?")'),
                "{{node}}")],
           gp(0, y + 1, 8, 7), unit="percentunit", soft_max=1),
        ts("Time since last WAL archived", "On the primary. Grows when archiving to the object store fails.",
           [tgt(by_node(f"max by (namespace, pod) (cnpg_pg_stat_archiver_seconds_since_last_archival{{{S}}}) and {PRIMARY_ONLY}"), "{{node}}")],
           gp(8, y + 1, 8, 7), unit="s", fixed=PRIMARY),
        ts("Transaction ID age", "Oldest unfrozen transaction ID per database. Wraparound trouble starts near 2 billion.",
           [tgt(f"max by (datname) (cnpg_pg_database_xid_age{{{S}}})", "{{datname}}")], gp(16, y + 1, 8, 7)),
        stat("Last backup", "Age of the newest completed base backup (Barman Cloud plugin). Red after 26 h, the daily schedule plus 2 h.",
             [tgt(BACKUP_AGE, instant=True)], gp(0, y + 8, 4, 5), unit="s", decimals=0, thr=thresholds((None, OK), (93600, BAD)),
             no_value="None", text_size={"valueSize": 28}),
        ts("WAL archive failures", "Failed WAL archive attempts per minute on the primary.",
           [tgt(by_node(f"max by (namespace, pod) (rate(cnpg_pg_stat_archiver_failed_count{{{S}}}[$__rate_interval]) * 60) and {PRIMARY_ONLY}"),
                "{{node}}")],
           gp(4, y + 8, 10, 5), fixed=BAD),
    ]
    panels.append(row("Storage, backups, WAL and vacuum", y, collapsed=True, panels=detail))

    return {
        "uid": "cnpg-sample", "title": "PostgreSQL cluster", "tags": ["cloudnative-pg"], "timezone": "browser", "editable": True,
        "graphTooltip": 1, "refresh": "30s", "schemaVersion": 41, "version": 1,
        "time": {"from": "now-1h", "to": "now"},
        "description": "A CloudNativePG cluster: health, primary, replication, certificates, rule checks and nodes. Written by dashboard.py.",
        "templating": {"list": [
            {"name": "datasource", "label": "Data source", "type": "datasource", "query": "prometheus", "current": {}, "hide": 0},
            {"name": "namespace", "label": "Namespace", "type": "query", "datasource": DS,
             "query": {"query": "label_values(cnpg_collector_up, namespace)", "refId": "ns"}, "refresh": 2, "sort": 1, "current": {}, "hide": 0},
            {"name": "cluster", "label": "Cluster", "type": "query", "datasource": DS,
             "query": {"query": 'label_values(cnpg_collector_up{namespace="$namespace"}, cluster)', "refId": "cl"},
             "refresh": 2, "sort": 1, "current": {}, "hide": 0},
        ]},
        "annotations": {"list": []},
        "panels": panels,
    }


def healthy_test(rules, tests, rules_dir):
    """A promtool test: on every case of rules.test.yaml, at every time it checks, the Healthy
    expression equals the number of critical alerts that are pending or firing for the database."""
    database = next(r for g in rules["groups"] for r in g["rules"] if r.get("record") == "cnpg_sample:database")["labels"]
    expr, _ = healthy(rules)
    expr = expr.replace("$namespace", database["namespace"]).replace("$cluster", database["cluster"])
    alerts = (f'count(ALERTS{{severity="critical", namespace="{database["namespace"]}", cluster="{database["cluster"]}"}})'
              " or vector(0)")
    cases = []
    for test in tests["tests"]:
        times = sorted({t["eval_time"] for t in test.get("alert_rule_test", []) + test.get("promql_expr_test", [])})
        case = {k: v for k, v in test.items() if k not in ("alert_rule_test", "promql_expr_test")}
        case["promql_expr_test"] = [
            {"expr": f"({expr}) - ({alerts})", "eval_time": t, "exp_samples": [{"labels": "{}", "value": 0}]} for t in times]
        cases.append(case)
    return {"rule_files": [os.path.join(rules_dir, "rules.yaml")], "evaluation_interval": tests.get("evaluation_interval", "1m"), "tests": cases}


def main():
    parser = argparse.ArgumentParser(description="Writes the sample's Grafana dashboard.")
    parser.add_argument("--out", default=os.path.join(HERE, "dashboard.json"), help="where to write the dashboard")
    parser.add_argument("--healthy-test", help="write the promtool test of the Healthy tile to this file instead")
    parser.add_argument("--rules-dir", default=HERE, help="the rules.yaml path the test names, as promtool sees it")
    args = parser.parse_args()

    rules = load_yaml(os.path.join(HERE, "rules.yaml"))
    if args.healthy_test:
        test = healthy_test(rules, load_yaml(os.path.join(HERE, "rules.test.yaml")), args.rules_dir)
        with open(args.healthy_test, "w") as f:
            json.dump(test, f, indent=1)
            f.write("\n")
        return
    with open(args.out, "w") as f:
        json.dump(dashboard(rules), f, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
