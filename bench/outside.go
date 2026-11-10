package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"time"

	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/api/types/network"
	"github.com/testcontainers/testcontainers-go"
	tcnetwork "github.com/testcontainers/testcontainers-go/network"
)

// What runs outside k3s in production runs here as a container next to the
// nodes, on one network, at fixed addresses that the DNS container names.
const (
	subnet = "10.77.0.0/24"
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

// hosts is the DNS container's hosts file: every name of the bench.
func hosts() string {
	lines := []string{s3IP + " " + s3Name, acmeIP + " " + acmeName, clientIP + " " + clientName}
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

func newNetwork(ctx context.Context) (*testcontainers.DockerNetwork, error) {
	return tcnetwork.New(ctx, tcnetwork.WithIPAM(&network.IPAM{Config: []network.IPAMConfig{{Subnet: netip.MustParsePrefix(subnet)}}}))
}

// on puts a container on the bench network at ip, with the DNS container as
// its resolver and name as its host name.
func on(nw *testcontainers.DockerNetwork, ip, name string) func(*testcontainers.ContainerRequest) {
	return func(req *testcontainers.ContainerRequest) {
		req.Networks = []string{nw.Name}
		req.EndpointSettingsModifier = func(m map[string]*network.EndpointSettings) {
			m[nw.Name].IPAMConfig = &network.EndpointIPAMConfig{IPv4Address: netip.MustParseAddr(ip)}
		}
		hostConfig := req.HostConfigModifier
		req.HostConfigModifier = func(hc *container.HostConfig) {
			hc.DNS = []netip.Addr{netip.MustParseAddr(dnsIP)}
			if hostConfig != nil {
				hostConfig(hc)
			}
		}
		req.ConfigModifier = func(c *container.Config) { c.Hostname = name }
	}
}

func start(ctx context.Context, req testcontainers.ContainerRequest, opts ...func(*testcontainers.ContainerRequest)) (*testcontainers.DockerContainer, error) {
	for _, opt := range opts {
		opt(&req)
	}
	c, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{ContainerRequest: req, Started: true})
	if err != nil {
		return nil, fmt.Errorf("starting %s: %w", req.Name, err)
	}
	dc, ok := c.(*testcontainers.DockerContainer)
	if !ok {
		return nil, fmt.Errorf("%s: not a docker container", req.Name)
	}
	return dc, nil
}

func startDNS(ctx context.Context, nw *testcontainers.DockerNetwork) error {
	_, err := start(ctx, testcontainers.ContainerRequest{
		Name:  "dns",
		Image: corednsImage,
		Cmd:   []string{"-conf", "/etc/coredns/Corefile"},
		Files: []testcontainers.ContainerFile{
			file("/etc/coredns/Corefile", corefile),
			file("/etc/coredns/hosts", hosts()),
		},
	}, on(nw, dnsIP, "dns"))
	return err
}

// The store: versitygw with TLS under its own name, with a certificate of
// the company CA.
func startStore(ctx context.Context, nw *testcontainers.DockerNetwork, root *ca) error {
	cert, key, err := root.serverCert(s3Name)
	if err != nil {
		return err
	}
	_, err = start(ctx, testcontainers.ContainerRequest{
		Name:       "s3",
		Image:      s3Image,
		Entrypoint: []string{"/usr/local/bin/versitygw"},
		Cmd: []string{"--access", s3Access, "--secret", s3Secret, "--port", ":443",
			"--cert", "/tls/tls.crt", "--key", "/tls/tls.key", "posix", "/data"},
		Files: []testcontainers.ContainerFile{
			file("/tls/tls.crt", string(cert)),
			file("/tls/tls.key", string(key)),
		},
	}, on(nw, s3IP, s3Name))
	if err != nil {
		return err
	}
	return poll(ctx, time.Now().Add(60*time.Second), func(ctx context.Context) error {
		return createBucket(ctx, httpsTo(s3IP, root))
	})
}

// createBucket makes the bucket with one S3 PUT, signed with AWS Signature
// Version 4.
func createBucket(ctx context.Context, client *http.Client) error {
	const region, service = "us-east-1", "s3"
	now := time.Now().UTC()
	day, stamp := now.Format("20060102"), now.Format("20060102T150405Z")
	payload := sha256Hex("")
	canonical := strings.Join([]string{
		http.MethodPut, "/" + s3Bucket, "",
		"host:" + s3Name, "x-amz-content-sha256:" + payload, "x-amz-date:" + stamp, "",
		"host;x-amz-content-sha256;x-amz-date", payload,
	}, "\n")
	scope := strings.Join([]string{day, region, service, "aws4_request"}, "/")
	toSign := strings.Join([]string{"AWS4-HMAC-SHA256", stamp, scope, sha256Hex(canonical)}, "\n")
	key := []byte("AWS4" + s3Secret)
	var err error
	for _, part := range []string{day, region, service, "aws4_request", toSign} {
		if key, err = hmacSHA256(key, part); err != nil {
			return err
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, "https://"+s3Name+"/"+s3Bucket, nil)
	if err != nil {
		return err
	}
	req.Header.Set("X-Amz-Content-Sha256", payload)
	req.Header.Set("X-Amz-Date", stamp)
	req.Header.Set("Authorization", fmt.Sprintf(
		"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=%x",
		s3Access, scope, key))
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	body, err := io.ReadAll(resp.Body)
	if err := closeWith(err, resp.Body); err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("creating bucket %s: %s: %s", s3Bucket, resp.Status, body)
	}
	return nil
}

func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func hmacSHA256(key []byte, data string) ([]byte, error) {
	h := hmac.New(sha256.New, key)
	_, err := h.Write([]byte(data))
	return h.Sum(nil), err
}

// httpsTo is a client that reaches every name at ip, and trusts only the
// company CA.
func httpsTo(ip string, root *ca) *http.Client {
	roots := x509.NewCertPool()
	roots.AddCert(root.cert)
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	return &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12},
			DialContext: func(ctx context.Context, netw, addr string) (net.Conn, error) {
				_, port, err := net.SplitHostPort(addr)
				if err != nil {
					return nil, err
				}
				return dialer.DialContext(ctx, netw, net.JoinHostPort(ip, port))
			},
		},
	}
}

// The company CA: OpenBao's PKI with the run's root, serving ACME on 443 with
// EAB required, http-01 checked through the bench's DNS, and only the
// approved names: the nodes and the client. Port 8200 serves the API to the
// bench without TLS, on the bench network only.
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

// openbao is the API of the ACME server's OpenBao, for the bench.
type openbao struct {
	http  *http.Client
	token string
}

func startACME(ctx context.Context, nw *testcontainers.DockerNetwork, root *ca) (*openbao, error) {
	cert, key, err := root.serverCert(acmeName)
	if err != nil {
		return nil, err
	}
	_, err = start(ctx, testcontainers.ContainerRequest{
		Name:  "acme",
		Image: openbaoImage,
		Cmd:   []string{"server", "-config=/bao/bao.hcl"},
		Files: []testcontainers.ContainerFile{
			file("/bao/bao.hcl", openbaoConfig),
			file("/bao/tls.crt", string(cert)),
			file("/bao/tls.key", string(key)),
		},
	}, on(nw, acmeIP, acmeName))
	if err != nil {
		return nil, err
	}
	bao := &openbao{http: &http.Client{Timeout: 10 * time.Second}}
	var init struct {
		Keys  []string `json:"keys_base64"`
		Token string   `json:"root_token"`
	}
	err = poll(ctx, time.Now().Add(60*time.Second), func(ctx context.Context) error {
		return bao.call(ctx, http.MethodPut, "sys/init", map[string]any{"secret_shares": 1, "secret_threshold": 1}, &init)
	})
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
	resp, err := b.http.Do(req)
	if err != nil {
		return err
	}
	data, err := io.ReadAll(resp.Body)
	if err := closeWith(err, resp.Body); err != nil {
		return err
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("OpenBao %s %s: %s: %s", method, path, resp.Status, bytes.TrimSpace(data))
	}
	if out == nil || len(data) == 0 {
		return nil
	}
	return json.Unmarshal(data, out)
}
