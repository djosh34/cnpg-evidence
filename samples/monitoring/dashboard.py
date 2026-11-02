# Writes dashboard.json, the Grafana dashboard of the sample's cluster, from
# this file and the critical alerts of rules.yaml. Needs python3 and yq.
#
# Usage:
#   python3 samples/monitoring/dashboard.py                    writes dashboard.json
#   python3 samples/monitoring/dashboard.py --out <file>       writes the dashboard to <file>
#   python3 samples/monitoring/dashboard.py --healthy-test <file>
#       writes a promtool test that checks, at every input step of every case
#       of rules.test.yaml, that Healthy counts the firing critical alerts and
#       that each red tile is red only while its critical alert fires
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
# soon, red a critical alert fires.
PRIMARY = "purple"
REPLICA = "text"
OK = "green"
OK_FILL = "dark-green"
WARN = "orange"
BAD = "red"
QUIET = "text"

DS = {"type": "prometheus", "uid": "${datasource}"}

# CNPG series carry the namespace, cluster and node the scrape adds
# (docs/monitoring.md). The cnpg_sample:* series are recorded by rules.yaml,
# and ALERTS by the rule evaluator, so the data source must hold both.
S = 'namespace="$namespace", cluster="$cluster"'
# Node metrics from cAdvisor. Change these if the collector setup differs.
NODE_CPU = 'sum by (node) (rate(container_cpu_usage_seconds_total{id="/"}[$__rate_interval])) / max by (node) (machine_cpu_cores)'
NODE_MEM = 'max by (node) (container_memory_working_set_bytes{id="/"}) / max by (node) (machine_memory_bytes)'
DATA_DISK = f"cnpg_sample:data_disk_used_ratio{{{S}}}"
CERTS = f"cnpg_sample:certificate_expiration_timestamp_seconds{{{S}}}"


def firing(alerts, severity="critical"):
    """The firing alerts of this database whose name matches alerts."""
    return f'ALERTS{{alertstate="firing", alertname=~"{alerts}", severity="{severity}", {S}}}'


# Pod to node: the node of each instance's exporter now, else the last one
# seen in the day, so an instance on a lost node keeps its node's name.
POD_NODE = (
    f"(max by (namespace, pod, node) (cnpg_collector_up{{{S}}}) * 0 + 1"
    " or on (namespace, pod) topk by (namespace, pod) (1, max by (namespace, pod, node)"
    f" (last_over_time(cnpg_collector_up{{{S}}}[1d])) * 0 + 1))"
)


def by_node(expr):
    """Adds the node label."""
    return f"({expr}) * on (namespace, pod) group_left (node) {POD_NODE}"


# Who is primary: PostgreSQL, not in recovery.
RR = f"max by (namespace, pod) (cnpg_pg_replication_in_recovery{{{S}}})"
WW = f"max by (namespace, pod) (cnpg_pg_replication_is_wal_receiver_up{{{S}}})"
# Instance state, from the metrics:
#  2 primary   1 replica streaming   0 replica not streaming   -1 exporter up, PostgreSQL down
STATE0 = (
    f"((1 - {RR}) * 2 + {RR} * {WW})"
    f" or on (namespace, pod) (max by (namespace, pod) (cnpg_collector_up{{{S}}}) == 0) - 1"
)
# Before it, in this order: -2 down, while CNPGReplicaDown fires for the
# instance, also when its metrics are gone; -5 writes blocked, while
# CNPGWritesBlocked fires; -6 fenced.
DOWN = f'max by (namespace, pod) ({firing("CNPGReplicaDown")}) * 0 - 2'
WRITES_BLOCKED = f'max by (namespace, pod) ({firing("CNPGWritesBlocked")}) * 0 - 5'
FENCED = f"(max by (namespace, pod) (cnpg_collector_fencing_on{{{S}}}) == 1) * 0 - 6"
STATE = f"({DOWN}) or on (namespace, pod) ({WRITES_BLOCKED}) or on (namespace, pod) ({FENCED}) or on (namespace, pod) ({STATE0})"
STATE_MAP = {
    "2": ("Primary", PRIMARY),
    "1": ("Replica", OK),
    "0": ("Not streaming", WARN),
    "-1": ("PostgreSQL down", WARN),
    "-6": ("Fenced", WARN),
    "-5": ("Writes blocked", BAD),
    "-2": ("Down", BAD),
}
STATE_RED = f"(({STATE}) == -2 or ({STATE}) == -5)"


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


# ---- Healthy: the firing critical alerts of rules.yaml.

def critical_alerts(rules):
    names = sorted({rule["alert"] for group in rules["groups"] for rule in group["rules"]
                    if rule.get("labels", {}).get("severity") == "critical"})
    if not names:
        sys.exit("dashboard.py: rules.yaml has no critical alerts")
    return names


HEALTHY = f"count({firing('.+')}) or vector(0)"


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


def alert_stat(title, desc, value, alerts, gp, missing, legend="", **kwargs):
    """A stat tile that shows value, red exactly while one of the critical alerts fires.

    Query A returns the value while one fires and is drawn red, query B while
    none fires and is coloured by the thresholds, which never reach red. With
    no value the tile shows the text missing.
    """
    value = f"({value}) or on () vector(NaN)"
    targets = [tgt(f"({value}) and on () (count({firing(alerts)}) > 0)", legend, instant=True, ref="A"),
               tgt(f"({value}) unless on () count({firing(alerts)})", legend, instant=True, ref="B")]
    panel = stat(title, desc, targets, gp, mappings=[nan(missing, WARN)] + kwargs.pop("mappings", []), **kwargs)
    panel["fieldConfig"]["overrides"].append(
        {"matcher": {"id": "byFrameRefID", "options": "A"},
         "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": BAD}}, {"id": "mappings", "value": [nan(missing)]}]})
    RED.append((title, targets[0]["expr"], alerts))
    return panel


def nan(text, color=None):
    result = {"text": text, "index": 0}
    if color:
        result["color"] = color
    return {"type": "special", "options": {"match": "nan", "result": result}}


# The red tiles: (title, the query that is red, the alerts it shows).
RED = []


def dashboard(rules):
    _id[0] = 0
    RED.clear()
    alert_names = critical_alerts(rules)
    panels = []
    y = 0
    H5 = 5
    # ---- The strip: the only filled tiles on the page. Red means a critical
    # alert fires; orange that a value passed a warning threshold.
    panels.append(stat(
        "Healthy",
        "The number of critical alerts of rules.yaml that fire for this database: " + ", ".join(alert_names) + ". "
        "An alert fires once its condition has held for its waiting time; each pod, volume, certificate or check counts once.",
        [tgt(HEALTHY, instant=True)], gp(0, y, 4, H5),
        thr=thresholds((None, OK_FILL), (1, BAD)),
        mappings=[{"type": "value", "options": {"0": {"text": "Yes", "index": 0}, "1": {"text": "1 problem", "index": 1},
                   **{str(n): {"text": f"{n} problems", "index": n} for n in range(2, 30)}}}],
        text_size={"valueSize": 34}))
    RED.append(("Healthy", f"({HEALTHY}) > 0", ".+"))
    panels.append(stat(
        "Instances",
        "Each instance by the node it runs on. Primary: PostgreSQL accepts writes. Not streaming: a replica that does not "
        "stream from the primary. Down, in red: CNPGReplicaDown fires for it, also when its node is lost. Writes blocked, in red: "
        "CNPGWritesBlocked fires, commits on the primary wait for a synchronous standby; reads still work.",
        [tgt(f"sort_desc({by_node(STATE)})", "{{node}}", instant=True)], gp(4, y, 8, H5),
        thr=thresholds((None, WARN)), text_mode="value_and_name", orientation="vertical", mappings=state_mappings(OK_FILL),
        text_size={"titleSize": 14, "valueSize": 24}))
    RED.append(("Instances", STATE_RED, "CNPGReplicaDown|CNPGWritesBlocked"))
    panels.append(alert_stat(
        "Replica lag", "Largest delay of any replica's reads, in seconds: 0 when it has replayed all the WAL its primary reported. "
        "Orange over 1 s; red while CNPGReplicaLag fires, after 2 min over 15 s. Missing: no replica reports it.",
        f"max(cnpg_replica_lag_seconds{{{S}}})", "CNPGReplicaLag", gp(12, y, 3, H5), unit="s", decimals=1,
        thr=thresholds((None, OK_FILL), (1, WARN)), missing="Missing", text_size={"valueSize": 30}))
    panels.append(alert_stat(
        "Rule checks", "Role and mapping violations the compliance query finds. Red while CNPGComplianceViolation or "
        "CNPGMetricsMissing fires; missing means the checks stopped reporting.",
        f"sum(max by (rule, check) (cnpg_compliance_violations{{{S}}}))", "CNPGComplianceViolation|CNPGMetricsMissing",
        gp(15, y, 3, H5), thr=thresholds((None, OK_FILL), (1, WARN)), missing="Missing",
        mappings=[{"type": "value", "options": {"0": {"text": "All pass", "index": 1}}}], text_size={"valueSize": 24}))
    panels.append(alert_stat(
        "Certificates",
        "Days until the first of the chart's server and replication certificates expires. "
        "Orange under 14 days; red while CNPGCertificateExpiring is critical, under 3 days.",
        f"min(({CERTS} - time()) / 86400)", "CNPGCertificateExpiring", gp(18, y, 3, H5), unit="suffix: days", decimals=0,
        thr=thresholds((None, WARN), (14, OK_FILL)), missing="Missing", text_size={"valueSize": 30}))
    panels.append(alert_stat(
        "Data disks", "The fullest disk that holds an instance's data, by node. Orange over 70 %; red while CNPGDataDiskFull "
        "is critical, over 80 %, before Kubernetes evicts pods at about 85 %.",
        f"topk(1, {DATA_DISK})", "CNPGDataDiskFull", gp(21, y, 3, H5), legend="{{node}}", unit="percentunit", decimals=0,
        thr=thresholds((None, OK_FILL), (0.7, WARN)), text_mode="value_and_name", missing="Missing",
        text_size={"titleSize": 12, "valueSize": 30}))
    y += H5

    # ---- Leader and replicas over time, right under the strip.
    panels.append({
        "id": nid(), "type": "state-timeline", "title": "Leader and replicas",
        "description": "State of each instance over time. Purple is the leader (primary); a purple band moving to another node is a failover or switchover.",
        "datasource": DS, "gridPos": gp(0, y, 24, 7), "transparent": True,
        "targets": [tgt(by_node(STATE), "{{node}}")],
        "fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": WARN},
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
        "Replica lag", "How far behind each replica's reads are, in seconds: 0 when it has replayed all the WAL its primary "
        "reported, else the age of the last transaction it replayed. The dashed lines are 1 s and the alert's 15 s.",
        [tgt(by_node(f"max by (namespace, pod) (cnpg_replica_lag_seconds{{{S}}})"), "{{node}}")],
        gp(0, y, 12, 8), unit="s", fixed=REPLICA, thr=thresholds((None, "transparent"), (1, WARN), (15, BAD)), thr_style="dashed"))
    panels.append(ts(
        "Bytes not yet replayed", "WAL the primary has sent that each replica has not replayed yet.",
        [tgt(by_node(f'label_replace(max by (namespace, application_name) (cnpg_pg_stat_replication_replay_diff_bytes{{{S}}}), '
                     f'"pod", "$1", "application_name", "(.+)")'), "{{node}}")],
        gp(12, y, 12, 8), unit="bytes", fixed=REPLICA))
    y += 8

    # ---- Rule checks
    panels.append(row("Rule checks", y))
    y += 1
    panels.append({
        "id": nid(), "type": "table", "title": "Rule checks",
        "description": "Each role and mapping check from the compliance query and how many violations it finds.",
        "datasource": DS, "gridPos": gp(0, y, 24, 6), "transparent": True,
        "targets": [tgt(f"max by (rule, check) (cnpg_compliance_violations{{{S}}})", instant=True, fmt="table")],
        "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True},
                                                           "renameByName": {"rule": "Rule", "check": "Check", "Value": "Violations"},
                                                           "indexByName": {"rule": 0, "check": 1, "Value": 2}}}],
        "fieldConfig": {"defaults": {"custom": {"align": "left", "cellOptions": {"type": "auto"}}, "color": {"mode": "thresholds"},
                                     "thresholds": thresholds((None, "text"), (1, WARN))},
                        "overrides": [{"matcher": {"id": "byName", "options": "Violations"},
                                       "properties": [{"id": "custom.cellOptions", "value": {"type": "color-text"}},
                                                      {"id": "custom.width", "value": 110}]}]},
        "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}}})
    y += 6

    # ---- Nodes
    panels.append(row("Nodes", y))
    y += 1
    panels.append(ts("CPU", "Share of each node's CPU in use.", [tgt(NODE_CPU, "{{node}}")],
                     gp(0, y, 8, 7), unit="percentunit", soft_max=1, thr=thresholds((None, "transparent"), (0.9, WARN)), thr_style="dashed"))
    panels.append(ts("Memory", "Share of each node's memory in use (working set).", [tgt(NODE_MEM, "{{node}}")],
                     gp(8, y, 8, 7), unit="percentunit", soft_max=1, thr=thresholds((None, "transparent"), (0.9, WARN)), thr_style="dashed"))
    panels.append(bars("Data disks", "The disk each instance keeps its data on, by node: the kubelet's stats of its data volume. "
                       "Orange over 70 %; CNPGDataDiskFull is critical over 80 %.",
                       tgt(f"sort_desc({DATA_DISK})", "{{node}}", instant=True), gp(16, y, 8, 7), "percentunit", 1,
                       thresholds((None, OK), (0.7, WARN))))
    y += 7

    # ---- Detail, collapsed
    detail = [
        ts("Time since last WAL archived", "On the primary. Grows when archiving to the object store fails.",
           [tgt(by_node(f"max by (namespace, pod) (cnpg_pg_stat_archiver_seconds_since_last_archival{{{S}}}) and {PRIMARY_ONLY}"), "{{node}}")],
           gp(0, y + 1, 12, 7), unit="s", fixed=PRIMARY),
        ts("Transaction ID age", "Oldest unfrozen transaction ID per database. Wraparound trouble starts near 2 billion.",
           [tgt(f"max by (datname) (cnpg_pg_database_xid_age{{{S}}})", "{{datname}}")], gp(12, y + 1, 12, 7)),
        alert_stat("Last backup", "Age of the newest completed base backup (Barman Cloud plugin). Orange after 26 h, the daily "
                   "schedule plus 2 h; red while CNPGBackupFailing fires.",
                   BACKUP_AGE, "CNPGBackupFailing", gp(0, y + 8, 4, 5), unit="s", decimals=0, thr=thresholds((None, OK), (93600, WARN)),
                   missing="None", text_size={"valueSize": 28}),
        ts("WAL archive failures", "Failed WAL archive attempts per minute on the primary.",
           [tgt(by_node(f"max by (namespace, pod) (rate(cnpg_pg_stat_archiver_failed_count{{{S}}}[$__rate_interval]) * 60) and {PRIMARY_ONLY}"),
                "{{node}}")],
           gp(4, y + 8, 20, 5), fixed=WARN),
    ]
    panels.append(row("Backups, WAL and vacuum", y, collapsed=True, panels=detail))

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


def seconds(duration):
    """Seconds of a Prometheus duration such as 90s, 5m or 28h."""
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    parts = re.fullmatch(r"(?:\d+[smhd])+", duration) and re.findall(r"(\d+)([smhd])", duration)
    if not parts:
        sys.exit(f"dashboard.py: cannot read the duration {duration}")
    return sum(int(n) * units[u] for n, u in parts)


def healthy_test(rules, tests, rules_dir):
    """A promtool test: on every case of rules.test.yaml, at every input step up to its last check,
    also inside the alerts' waiting times, Healthy equals the number of firing critical alerts, and
    each red tile is red exactly while one of its critical alerts fires."""
    dashboard(rules)
    database = next((r.get("labels") for g in rules["groups"] for r in g["rules"] if r.get("record") == "cnpg_sample:database"), None)
    if not database or set(database) != {"namespace", "cluster"}:
        sys.exit("dashboard.py: rules.yaml has no cnpg_sample:database rule with a namespace and cluster label")

    def here(expr):
        return expr.replace("$namespace", database["namespace"]).replace("$cluster", database["cluster"])

    # Without the database's labels, so an alert that lacks them is missed by Healthy and fails the test.
    checks = [f'({here(HEALTHY)}) - (count(ALERTS{{alertstate="firing", severity="critical"}}) or vector(0))']
    checks += [f"((count({here(red)}) or vector(0)) > bool 0) - ((count({here(firing(alerts))}) or vector(0)) > bool 0)"
               for _, red, alerts in RED]
    cases = []
    for test in tests["tests"]:
        step = seconds(test.get("interval", tests.get("evaluation_interval", "1m")))
        last = max(seconds(t["eval_time"]) for t in test.get("alert_rule_test", []) + test.get("promql_expr_test", []))
        case = {k: v for k, v in test.items() if k not in ("alert_rule_test", "promql_expr_test")}
        case["promql_expr_test"] = [
            {"expr": check, "eval_time": f"{t}s", "exp_samples": [{"labels": "{}", "value": 0}]}
            for t in range(0, last + 1, step) for check in checks]
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
