package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// The services outside k3s that the nodes need: DNS, the store and the
// company CA.
const (
	dnsIP  = "10.77.0.2"
	s3IP   = "10.77.0.20"
	acmeIP = "10.77.0.30"

	s3Name   = "s3.example.test"
	acmeName = "acme.example.test"

	corednsImage = "coredns/coredns:1.15.0@sha256:0a9d8c8ddf34347eb59aad9a8784f0710de88d6d112726d11d271f9bc6daca26"
	openbaoImage = "openbao/openbao:2.7.2@sha256:5046911075e137e154ce49ab051502f4ec7cf367d484ae4a4dce665d9b90561f"
	s3Image      = "versity/versitygw:v1.10.0@sha256:89cad13cc981986ee284cbafea4613f9533ce6fd5f37a2c96c4c4fb8adb3a316"

	// The store's bucket and keys, as the chart's values and the Secret
	// backup-creds give them.
	s3Bucket = "example-bucket"
	s3Access = "example-access-key"
	s3Secret = "example-secret-key"
)

// The ACME directory of the company CA.
var acmeDirectory = "https://" + acmeName + "/v1/pki/acme/directory"

// hosts is the DNS container's hosts file: every name of the e2e test.
func hosts() string {
	lines := []string{
		s3IP + " " + s3Name, acmeIP + " " + acmeName, clientIP + " " + clientName,
		otelIP + " " + otelName, prometheusIP + " " + prometheusName,
		alertmanagerIP + " " + alertmanagerName, grafanaIP + " " + grafanaName,
		gatewayIP + " " + receiverName,
	}
	for i := range nodeCount {
		lines = append(lines, nodeIP(i)+" "+nodeHost(i))
	}
	return strings.Join(lines, "\n") + "\n"
}

const corefile = `.:53 {
    hosts /etc/coredns/hosts {
        fallthrough
    }
    forward . /etc/resolv.conf
    errors
}
`

func startDNS(ctx context.Context) error {
	return container{
		name: "dns", ip: dnsIP, image: corednsImage, args: []string{"-conf", "/etc/coredns/Corefile"},
		files: map[string]string{"/etc/coredns/Corefile": corefile, "/etc/coredns/hosts": hosts()},
	}.run(ctx)
}

// The store: versitygw with TLS under its own name, with a certificate of
// the company CA. Its posix backend keeps each bucket as a directory, so the
// bucket is one before it starts.
func startStore(ctx context.Context, root *ca) error {
	cert, key, err := root.serverCert(s3Name)
	if err != nil {
		return err
	}
	return container{
		name: "s3", ip: s3IP, image: s3Image,
		opts: []string{"--entrypoint", "/usr/local/bin/versitygw"},
		args: []string{"--access", s3Access, "--secret", s3Secret, "--port", ":443",
			"--cert", "/tls/tls.crt", "--key", "/tls/tls.key", "posix", "/data"},
		files: map[string]string{"/tls/tls.crt": string(cert), "/tls/tls.key": string(key)},
		dirs:  []string{"/data/" + s3Bucket},
	}.run(ctx)
}

// The store breaks in one of two ways. Stopped, it refuses connections: its
// address belongs to a container that listens on no port. Paused, it takes
// connections and never answers.
const storeGone = "s3-gone"

func stopStore(ctx context.Context) error {
	if _, err := command(ctx, "docker", "stop", "-t", "0", "s3"); err != nil {
		return err
	}
	return container{
		name: storeGone, ip: s3IP, image: k3sImage, opts: []string{"--entrypoint", "/bin/sleep"}, args: []string{"86400"},
	}.run(ctx)
}

func pauseStore(ctx context.Context) error {
	_, err := command(ctx, "docker", "pause", "s3")
	return err
}

// restoreStore brings back a store that stopStore stopped or pauseStore
// paused.
func restoreStore(ctx context.Context, stopped bool) error {
	if !stopped {
		_, err := command(ctx, "docker", "unpause", "s3")
		return err
	}
	if _, err := command(ctx, "docker", "rm", "-f", storeGone); err != nil {
		return err
	}
	_, err := command(ctx, "docker", "start", "s3")
	return err
}

// The company CA: OpenBao's PKI with the run's root, serving ACME on 443 with
// EAB required, http-01 checked through the e2e test's DNS, and only the
// approved names: the nodes and the client. Port 8200 serves the API to the
// run without TLS, on the e2e network only.
const openbaoConfig = `storage "raft" {
  path    = "/openbao/file"
  node_id = "acme"
}
cluster_addr = "http://127.0.0.1:8201"
api_addr     = "https://acme.example.test"
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}
listener "tcp" {
  address       = "0.0.0.0:443"
  tls_cert_file = "/bao/tls.crt"
  tls_key_file  = "/bao/tls.key"
}
`

// openbao is the API of the ACME server's OpenBao, for the e2e test.
type openbao struct {
	http  *http.Client
	token string
}

func startACME(ctx context.Context, root *ca) (*openbao, error) {
	cert, key, err := root.serverCert(acmeName)
	if err != nil {
		return nil, err
	}
	err = container{
		name: "acme", ip: acmeIP, image: openbaoImage, args: []string{"server", "-config=/bao/bao.hcl"},
		files: map[string]string{"/bao/bao.hcl": openbaoConfig, "/bao/tls.crt": string(cert), "/bao/tls.key": string(key)},
	}.run(ctx)
	if err != nil {
		return nil, err
	}
	// Init can take longer than 10 s, and a second init fails, so it runs
	// once, after OpenBao answers.
	bao := &openbao{http: &http.Client{Timeout: 2 * time.Minute}}
	err = poll(ctx, time.Now().Add(60*time.Second), func(ctx context.Context) error {
		return bao.call(ctx, http.MethodGet, "sys/init", nil, nil)
	})
	if err != nil {
		return nil, fmt.Errorf("OpenBao answering: %w", err)
	}
	var init struct {
		Keys  []string `json:"keys_base64"`
		Token string   `json:"root_token"`
	}
	err = bao.call(ctx, http.MethodPut, "sys/init", map[string]any{"secret_shares": 1, "secret_threshold": 1}, &init)
	if err != nil {
		return nil, fmt.Errorf("OpenBao init: %w", err)
	}
	if len(init.Keys) != 1 {
		return nil, fmt.Errorf("OpenBao init gave %d keys", len(init.Keys))
	}
	bao.token = init.Token
	if err := bao.call(ctx, http.MethodPut, "sys/unseal", map[string]any{"key": init.Keys[0]}, nil); err != nil {
		return nil, err
	}
	err = poll(ctx, time.Now().Add(60*time.Second), func(ctx context.Context) error {
		return bao.call(ctx, http.MethodGet, "sys/health", nil, nil)
	})
	if err != nil {
		return nil, fmt.Errorf("OpenBao active: %w", err)
	}
	approved := []string{clientName}
	for i := range nodeCount {
		approved = append(approved, nodeHost(i))
	}
	steps := []struct {
		path string
		body map[string]any
	}{
		{"sys/mounts/pki", map[string]any{"type": "pki", "config": map[string]any{
			"max_lease_ttl":               "87600h",
			"passthrough_request_headers": []string{"If-Modified-Since"},
			"allowed_response_headers":    []string{"Last-Modified", "Location", "Replay-Nonce", "Link"},
		}}},
		{"pki/config/ca", map[string]any{"pem_bundle": string(root.keyPEM) + string(root.certPEM)}},
		{"pki/config/cluster", map[string]any{
			"path":     "https://" + acmeName + "/v1/pki",
			"aia_path": "https://" + acmeName + "/v1/pki",
		}},
		{"pki/roles/approved", map[string]any{
			"allowed_domains":    approved,
			"allow_bare_domains": true, "allow_subdomains": false, "allow_wildcard_certificates": false,
			"allow_localhost": false, "server_flag": true, "client_flag": true,
			"key_type": "any", "ttl": "2160h", "max_ttl": "2160h",
		}},
		{"pki/config/acme", map[string]any{
			"enabled": true, "allowed_roles": []string{"approved"}, "default_directory_policy": "role:approved",
			"eab_policy": "always-required", "dns_resolver": dnsIP + ":53", "allow_role_ext_key_usage": true,
		}},
	}
	for _, step := range steps {
		if err := bao.call(ctx, http.MethodPost, step.path, step.body, nil); err != nil {
			return nil, err
		}
	}
	return bao, nil
}

// eab is a new EAB key, good for one ACME account.
type eab struct{ id, key string }

func (b *openbao) newEAB(ctx context.Context) (eab, error) {
	var resp struct {
		Data struct {
			ID  string `json:"id"`
			Key string `json:"key"`
		} `json:"data"`
	}
	err := b.call(ctx, http.MethodPost, "pki/acme/new-eab", map[string]any{}, &resp)
	return eab{id: resp.Data.ID, key: resp.Data.Key}, err
}

func (b *openbao) call(ctx context.Context, method, path string, body, out any) error {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://"+acmeIP+":8200/v1/"+path, reader)
	if err != nil {
		return err
	}
	if b.token != "" {
		req.Header.Set("X-Vault-Token", b.token)
	}
	if err := callJSON(b.http, req, out); err != nil {
		return fmt.Errorf("OpenBao: %w", err)
	}
	return nil
}
