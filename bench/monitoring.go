package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/testcontainers/testcontainers-go"
)

// The monitoring outside k3s, as containers next to the nodes: the upstream
// OTel service with the one URL the collectors in k3s send to, Prometheus
// as the rule evaluator with monitoring/rules.yaml, Alertmanager with
// monitoring/alertmanager.yaml, and Grafana with monitoring/dashboard.json.
// The bench itself plays the receiver of alertmanager.yaml.
const (
	otelIP         = "10.77.0.50"
	prometheusIP   = "10.77.0.51"
	alertmanagerIP = "10.77.0.52"
	grafanaIP      = "10.77.0.53"

	otelName         = "otel.example.test"
	prometheusName   = "prometheus.example.test"
	alertmanagerName = "alertmanager.example.test"
	grafanaName      = "grafana.example.test"
	// The host of the receiver's URL in alertmanager.yaml.
	receiverName = "alerts.example.com"

	otelImage         = "otel/opentelemetry-collector-contrib:0.163.2@sha256:7f22d2a6748110ffb6a59bc0df448bccbf501cdb667d610ede4c61d3863d5849"
	prometheusImage   = "prom/prometheus:v3.7.3@sha256:49214755b6153f90a597adcbff0252cc61069f8ab69ce8411285cd4a560e8038"
	alertmanagerImage = "prom/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a"
	grafanaImage      = "grafana/grafana:12.4.12@sha256:83be3e511ede559bee80e2215bb1987cb1246075461cb961beb515b0341e7aea"

	// Grafana's data source, which the dashboard's data source variable picks.
	grafanaSource   = "prometheus"
	grafanaPassword = "example-password"
)

// The upstream OTel service: OTLP over gRPC with mTLS, the client
// certificate from the company CA, handed to Prometheus by remote write
// with every metric name as the scrape gave it.
const upstreamConfig = `extensions:
  health_check:
    endpoint: 0.0.0.0:13133
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        tls:
          cert_file: /tls/tls.crt
          key_file: /tls/tls.key
          client_ca_file: /tls/ca.crt
exporters:
  prometheus_remote_write:
    endpoint: http://` + prometheusName + `:9090/api/v1/write
    translation_strategy: UnderscoreEscapingWithoutSuffixes
    tls:
      insecure: true
    # One sender, so the samples of a series arrive in order.
    remote_write_queue:
      num_consumers: 1
service:
  extensions: [health_check]
  pipelines:
    metrics:
      receivers: [otlp]
      exporters: [prometheus_remote_write]
`

const prometheusConfig = `global:
  evaluation_interval: 15s
rule_files: [/etc/prometheus/rules.yaml]
alerting:
  alertmanagers:
    - static_configs: [{targets: ["` + alertmanagerName + `:9093"]}]
`

const grafanaSources = `apiVersion: 1
datasources:
  - name: Prometheus
    uid: ` + grafanaSource + `
    type: prometheus
    url: http://` + prometheusName + `:9090
    isDefault: true
`

const grafanaDashboards = `apiVersion: 1
providers:
  - name: bench
    type: file
    options:
      path: /etc/grafana/dashboards
`

// startMonitoring starts the receiver and the four containers, and returns
// once each answers.
func startMonitoring(ctx context.Context, nw *testcontainers.DockerNetwork, root *ca) (*monitoring, error) {
	dir := filepath.Join(benchDir, "monitoring")
	read := func(name string) (string, error) {
		data, err := os.ReadFile(filepath.Join(dir, name))
		return string(data), err
	}
	rules, err := read("rules.yaml")
	if err != nil {
		return nil, err
	}
	routes, err := read("alertmanager.yaml")
	if err != nil {
		return nil, err
	}
	dashboard, err := read("dashboard.json")
	if err != nil {
		return nil, err
	}
	m := &monitoring{http: &http.Client{Timeout: 20 * time.Second}}
	var uid struct {
		UID string `json:"uid"`
	}
	if err := json.Unmarshal([]byte(dashboard), &uid); err != nil {
		return nil, fmt.Errorf("monitoring/dashboard.json: %w", err)
	}
	if uid.UID == "" {
		return nil, errors.New("monitoring/dashboard.json has no uid")
	}
	m.dashboard = uid.UID
	if err := m.receive(root); err != nil {
		return nil, err
	}
	cert, key, err := root.serverCert(otelName)
	if err != nil {
		return nil, err
	}
	_, err = start(ctx, testcontainers.ContainerRequest{
		Name:  "otel",
		Image: otelImage,
		Cmd:   []string{"--config=/etc/otel/config.yaml"},
		Files: []testcontainers.ContainerFile{
			file("/etc/otel/config.yaml", upstreamConfig),
			file("/tls/tls.crt", string(cert)),
			file("/tls/tls.key", string(key)),
			file("/tls/ca.crt", string(root.certPEM)),
		},
	}, on(nw, otelIP, otelName))
	if err != nil {
		return nil, err
	}
	_, err = start(ctx, testcontainers.ContainerRequest{
		Name:  "prometheus",
		Image: prometheusImage,
		Cmd: []string{"--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.path=/prometheus",
			"--web.enable-remote-write-receiver"},
		Files: []testcontainers.ContainerFile{
			file("/etc/prometheus/prometheus.yml", prometheusConfig),
			file("/etc/prometheus/rules.yaml", rules),
		},
	}, on(nw, prometheusIP, prometheusName))
	if err != nil {
		return nil, err
	}
	// Alertmanager trusts the company CA, which signs the receiver's
	// certificate.
	_, err = start(ctx, testcontainers.ContainerRequest{
		Name:  "alertmanager",
		Image: alertmanagerImage,
		Cmd: []string{"--config.file=/etc/alertmanager/alertmanager.yml", "--storage.path=/alertmanager",
			"--cluster.listen-address="},
		Files: []testcontainers.ContainerFile{
			file("/etc/alertmanager/alertmanager.yml", routes),
			file("/etc/ssl/certs/ca-certificates.crt", string(root.certPEM)),
		},
	}, on(nw, alertmanagerIP, alertmanagerName))
	if err != nil {
		return nil, err
	}
	_, err = start(ctx, testcontainers.ContainerRequest{
		Name:  "grafana",
		Image: grafanaImage,
		Env:   map[string]string{"GF_SECURITY_ADMIN_PASSWORD": grafanaPassword},
		Files: []testcontainers.ContainerFile{
			file("/etc/grafana/provisioning/datasources/bench.yaml", grafanaSources),
			file("/etc/grafana/provisioning/dashboards/bench.yaml", grafanaDashboards),
			file("/etc/grafana/dashboards/dashboard.json", dashboard),
		},
	}, on(nw, grafanaIP, grafanaName))
	if err != nil {
		return nil, err
	}
	err = poll(ctx, time.Now().Add(2*time.Minute), func(ctx context.Context) error {
		return errors.Join(
			m.get(ctx, "http://"+otelIP+":13133/", nil),
			m.get(ctx, "http://"+prometheusIP+":9090/-/ready", nil),
			m.get(ctx, "http://"+alertmanagerIP+":9093/-/ready", nil),
			m.get(ctx, "http://"+grafanaIP+":3000/api/health", nil),
		)
	})
	if err != nil {
		return nil, fmt.Errorf("the monitoring containers: %w", err)
	}
	return m, nil
}

// monitoring is the bench's view of the monitoring: Prometheus's,
// Alertmanager's and Grafana's APIs, and the notifications the receiver got.
type monitoring struct {
	http      *http.Client
	dashboard string // the uid of the dashboard

	mu            sync.Mutex
	notifications []notification
}

// One alert of a notification Alertmanager sent the receiver.
type notification struct {
	at             time.Time
	alertname, pod string
	status         string // firing or resolved
}

// receive serves the receiver of alertmanager.yaml, https://alerts.example.com/hook,
// on the bench network's gateway, with a certificate of the company CA.
func (m *monitoring) receive(root *ca) error {
	cert, key, err := root.serverCert(receiverName)
	if err != nil {
		return err
	}
	pair, err := tls.X509KeyPair(cert, key)
	if err != nil {
		return err
	}
	listener, err := tls.Listen("tcp", net.JoinHostPort(gatewayIP, "443"),
		&tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS12})
	if err != nil {
		return err
	}
	server := &http.Server{ReadHeaderTimeout: 10 * time.Second, Handler: http.HandlerFunc(m.notified)}
	go func() {
		// It serves until the bench ends.
		if err := server.Serve(listener); err != nil {
			say(os.Stderr, "bench: the receiver: %v\n", err)
		}
	}()
	return nil
}

// notified keeps the alerts of one webhook notification of Alertmanager.
func (m *monitoring) notified(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Alerts []struct {
			Status string            `json:"status"`
			Labels map[string]string `json:"labels"`
		} `json:"alerts"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, a := range body.Alerts {
		m.notifications = append(m.notifications, notification{
			at: time.Now(), alertname: a.Labels["alertname"], pod: a.Labels["pod"], status: a.Status,
		})
	}
}

// sent: the receiver got alert name for pod as firing since from.
func (m *monitoring) sent(name, pod string, from time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, n := range m.notifications {
		if n.alertname == name && n.pod == pod && n.status == "firing" && !n.at.Before(from) {
			return nil
		}
	}
	return fmt.Errorf("the receiver got no notification of %s firing for %s", name, pod)
}

// get fetches url and decodes its JSON into out, when out is not nil.
func (m *monitoring) get(ctx context.Context, url string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	if strings.Contains(url, ":3000/") {
		req.SetBasicAuth("admin", grafanaPassword)
	}
	return m.do(req, out)
}

func (m *monitoring) do(req *http.Request, out any) error {
	resp, err := m.http.Do(req)
	if err != nil {
		return err
	}
	data, err := io.ReadAll(resp.Body)
	if err := closeWith(err, resp.Body); err != nil {
		return err
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("%s %s: %s: %s", req.Method, req.URL, resp.Status, strings.TrimSpace(string(data)))
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(data, out)
}

// A series of a Prometheus query result.
type series struct {
	Metric map[string]string `json:"metric"`
	Value  [2]any            `json:"value"`
}

// query runs a PromQL query at Prometheus, or through Grafana's data source
// when grafana is true.
func (m *monitoring) query(ctx context.Context, promql string, grafana bool) ([]series, error) {
	base := "http://" + prometheusIP + ":9090"
	if grafana {
		base = "http://" + grafanaIP + ":3000/api/datasources/proxy/uid/" + grafanaSource
	}
	var resp struct {
		Status string `json:"status"`
		Data   struct {
			Result []series `json:"result"`
		} `json:"data"`
	}
	if err := m.get(ctx, base+"/api/v1/query?query="+url.QueryEscape(promql), &resp); err != nil {
		return nil, err
	}
	if resp.Status != "success" {
		return nil, fmt.Errorf("query %s: status %q", promql, resp.Status)
	}
	return resp.Data.Result, nil
}

// pods are the values of the pod label of a query's result.
func (m *monitoring) pods(ctx context.Context, promql string) (map[string]bool, error) {
	result, err := m.query(ctx, promql, false)
	if err != nil {
		return nil, err
	}
	pods := map[string]bool{}
	for _, s := range result {
		pods[s.Metric["pod"]] = true
	}
	return pods, nil
}

// firing are the alerts that fire now, and fired those that fired since
// from, each as "<alertname> <pod>".
func (m *monitoring) firing(ctx context.Context) (map[string]bool, error) {
	return m.alerts(ctx, `ALERTS{alertstate="firing"}`)
}

func (m *monitoring) fired(ctx context.Context, from time.Time) (map[string]bool, error) {
	window := int(time.Since(from).Seconds()) + 1
	return m.alerts(ctx, fmt.Sprintf(`max by (alertname, pod) (max_over_time(ALERTS{alertstate="firing"}[%ds]))`, window))
}

func (m *monitoring) alerts(ctx context.Context, promql string) (map[string]bool, error) {
	result, err := m.query(ctx, promql, false)
	if err != nil {
		return nil, err
	}
	alerts := map[string]bool{}
	for _, s := range result {
		alerts[alertKey(s.Metric["alertname"], s.Metric["pod"])] = true
	}
	return alerts, nil
}

func alertKey(name, pod string) string {
	if pod == "" {
		pod = "-"
	}
	return name + " " + pod
}

// amState is the state Alertmanager holds alert name for pod in: active,
// suppressed, or "" when it has none.
func (m *monitoring) amState(ctx context.Context, name, pod string) (string, error) {
	var alerts []struct {
		Labels map[string]string `json:"labels"`
		Status struct {
			State string `json:"state"`
		} `json:"status"`
	}
	if err := m.get(ctx, "http://"+alertmanagerIP+":9093/api/v2/alerts", &alerts); err != nil {
		return "", err
	}
	for _, a := range alerts {
		if a.Labels["alertname"] == name && a.Labels["pod"] == pod {
			return a.Status.State, nil
		}
	}
	return "", nil
}

// amSend sends Alertmanager the critical alert name for pod of the
// database, for 2 min, as the rule evaluator would.
func (m *monitoring) amSend(ctx context.Context, name, pod string) error {
	body, err := json.Marshal([]map[string]any{{
		"labels": map[string]string{
			"alertname": name, "severity": "critical", "namespace": namespace, "cluster": clusterName, "pod": pod,
		},
		"endsAt": time.Now().Add(2 * time.Minute).UTC().Format(time.RFC3339),
	}})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://"+alertmanagerIP+":9093/api/v2/alerts", strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	return m.do(req, nil)
}

// dashboardHasData: Grafana has the dashboard, and each of its panels gets
// data through Grafana's data source: at least one value that is not NaN,
// with the dashboard's variables set to the database.
func (m *monitoring) dashboardHasData(ctx context.Context) error {
	type panel struct {
		Title   string `json:"title"`
		Targets []struct {
			Expr string `json:"expr"`
		} `json:"targets"`
		Panels []json.RawMessage `json:"panels"`
	}
	var resp struct {
		Dashboard struct {
			Panels []panel `json:"panels"`
		} `json:"dashboard"`
	}
	if err := m.get(ctx, "http://"+grafanaIP+":3000/api/dashboards/uid/"+m.dashboard, &resp); err != nil {
		return err
	}
	var panels []panel
	for _, p := range resp.Dashboard.Panels {
		panels = append(panels, p)
		for _, raw := range p.Panels {
			var inner panel
			if err := json.Unmarshal(raw, &inner); err != nil {
				return err
			}
			panels = append(panels, inner)
		}
	}
	vars := strings.NewReplacer("$namespace", namespace, "$cluster", clusterName, "$__rate_interval", "1m")
	checked := 0
	for _, p := range panels {
		if len(p.Targets) == 0 {
			continue
		}
		values := 0
		for _, t := range p.Targets {
			result, err := m.query(ctx, vars.Replace(t.Expr), true)
			if err != nil {
				return fmt.Errorf("panel %s: %w", p.Title, err)
			}
			for _, s := range result {
				if v, ok := s.Value[1].(string); ok && v != "NaN" {
					values++
				}
			}
		}
		if values == 0 {
			return fmt.Errorf("dashboard panel %s has no data", p.Title)
		}
		checked++
	}
	if checked == 0 {
		return errors.New("the dashboard has no panel with a query")
	}
	return nil
}

// everySource: Prometheus has the metrics of every source the rules read:
// for each instance the four compliance checks and its data disk, the
// chart's two certificates and a backup the plugin reports; and no alert
// fires.
func (m *monitoring) everySource(ctx context.Context) error {
	wants := []struct {
		promql string
		n      int
	}{
		{`count by (pod) (cnpg_compliance_violations{cluster="` + clusterName + `"}) == 4`, nodeCount},
		{`cnpg_sample:data_disk_used_ratio{cluster="` + clusterName + `"}`, nodeCount},
		{`cnpg_sample:certificate_expiration_timestamp_seconds{cluster="` + clusterName + `"}`, 2},
		{`max(barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{cluster="` + clusterName + `"}) > 0`, 1},
		{`ALERTS{alertstate="firing"}`, 0},
	}
	for _, want := range wants {
		result, err := m.query(ctx, want.promql, false)
		if err != nil {
			return err
		}
		if len(result) != want.n {
			return fmt.Errorf("%d series of %s, not %d", len(result), want.promql, want.n)
		}
	}
	return nil
}

// none: the query has no result.
func (m *monitoring) none(ctx context.Context, promql string) error {
	result, err := m.query(ctx, promql, false)
	if err != nil {
		return err
	}
	if len(result) > 0 {
		return fmt.Errorf("%s has %d results", promql, len(result))
	}
	return nil
}

// history is when each alert was pending and firing since from, as
// Prometheus recorded it, for the state of a failed run.
func (m *monitoring) history(ctx context.Context, from time.Time) string {
	q := url.Values{}
	q.Set("query", "ALERTS")
	q.Set("start", strconv.FormatInt(from.Unix(), 10))
	q.Set("end", strconv.FormatInt(time.Now().Unix(), 10))
	q.Set("step", "15")
	var resp struct {
		Data struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
				Values [][2]any          `json:"values"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := m.get(ctx, "http://"+prometheusIP+":9090/api/v1/query_range?"+q.Encode(), &resp); err != nil {
		return "The alerts: " + err.Error() + "\n"
	}
	out := "The alerts since the cluster was built, from Prometheus (UTC):\n"
	for _, r := range resp.Data.Result {
		times := make([]string, 0, 2)
		for _, i := range []int{0, len(r.Values) - 1} {
			if t, ok := r.Values[i][0].(float64); ok {
				times = append(times, time.Unix(int64(t), 0).UTC().Format(time.TimeOnly))
			}
		}
		out += fmt.Sprintf("  %s %s: %s\n", alertKey(r.Metric["alertname"], r.Metric["pod"]), r.Metric["alertstate"], strings.Join(times, " to "))
	}
	return out
}
