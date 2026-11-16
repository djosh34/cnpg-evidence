package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	clientv3 "go.etcd.io/etcd/client/v3"
	"go.uber.org/zap"
)

// The rotation of the k3s CAs, as docs.k3s.io says for the CAs k3s made
// itself: k3s's own script makes new CAs, each cross-signed by the old one,
// "k3s certificate rotate-ca" stores them in etcd, and k3s restarts on every
// node, which then makes its certificates from them.

// Where k3s keeps its server files on a node, and where node-init.sh writes
// the process ID of k3s.
const (
	k3sServerDir = "/var/lib/rancher/k3s/server"
	k3sPIDFile   = "/run/k3s.pid"
)

// rotateScript is k3s's contrib/util/rotate-default-ca-certs.sh of the
// pinned version, which the e2e image has.
const rotateScript = "/opt/cnpg-evidence/k3s/rotate-default-ca-certs.sh"

// The CAs rotate-ca replaces, by their file name under server/tls: the
// Kubernetes server and client CAs, the API aggregation CA, and etcd's
// server and peer CAs.
var k3sCAs = []string{"server", "client", "request-header", "etcd/server", "etcd/peer"}

// storeNewCAs: the script makes the new CAs from those of the first node, in
// the e2e container, which has the bash and openssl it needs. They go to
// that node, and "k3s certificate rotate-ca" there stores them in etcd. The
// scenario keeps the new CAs, to check later lines against them alone.
func storeNewCAs(ctx context.Context, s *scenario, _ args) error {
	node := nodeName(0)
	dir := filepath.Join(workDir, "ca-rotation")
	if err := os.MkdirAll(filepath.Join(dir, "server"), 0o700); err != nil {
		return err
	}
	// The script reads the CAs with their keys, and the tokens, which it
	// prints with the new CA's hash.
	for _, file := range []string{"tls", "token", "agent-token"} {
		_, err := command(ctx, "docker", "cp", node+":"+k3sServerDir+"/"+file, filepath.Join(dir, "server", file))
		if err != nil {
			return err
		}
	}
	if _, err := command(ctx, "env", "DATA_DIR="+dir, "bash", rotateScript); err != nil {
		return err
	}
	staged := filepath.Join(dir, "server", "rotate-ca")
	pools, err := newCAPools(filepath.Join(staged, "tls"))
	if err != nil {
		return err
	}
	if _, err := command(ctx, "docker", "cp", staged, node+":"+k3sServerDir+"/rotate-ca"); err != nil {
		return err
	}
	out, err := command(ctx, "docker", "exec", node, "k3s", "certificate", "rotate-ca", "--path="+k3sServerDir+"/rotate-ca")
	if err != nil {
		return err
	}
	s.newCAs, s.detail = pools, out
	return nil
}

// newCAPools are the new CAs of the script's output, each with its new root
// as the only root, so that only a certificate a new CA issued verifies.
func newCAPools(dir string) (map[string]x509.VerifyOptions, error) {
	pools := map[string]x509.VerifyOptions{}
	for _, name := range k3sCAs {
		opts := x509.VerifyOptions{
			Roots: x509.NewCertPool(), Intermediates: x509.NewCertPool(),
			KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
		}
		for file, pool := range map[string]*x509.CertPool{"-root-ssigned.pem": opts.Roots, "-ca.pem": opts.Intermediates} {
			data, err := os.ReadFile(filepath.Join(dir, name+file))
			if err != nil {
				return nil, err
			}
			if !pool.AppendCertsFromPEM(data) {
				return nil, fmt.Errorf("no certificate in %s%s", name, file)
			}
		}
		pools[name] = opts
	}
	return pools, nil
}

// restartK3s: k3s on the node gets SIGTERM, as from systemctl restart k3s,
// and node-init.sh starts it again 5 s after it exits. The line ends once
// the new k3s runs.
func restartK3s(ctx context.Context, _ *scenario, a args) error {
	node, err := numberedNode(a.ns[0])
	if err != nil {
		return err
	}
	old, err := command(ctx, "docker", "exec", node, "sh", "-c", `read -r pid <`+k3sPIDFile+` && kill "$pid" && echo "$pid"`)
	if err != nil {
		return err
	}
	logf("k3s on %s stopped", node)
	return poll(ctx, time.Now().Add(2*time.Minute), func(ctx context.Context) error {
		pid, err := command(ctx, "docker", "exec", node, "sh", "-c", `read -r pid <`+k3sPIDFile+` && echo "$pid"`)
		if err == nil && pid == old {
			err = fmt.Errorf("k3s on %s did not start again", node)
		}
		return err
	})
}

// numberedNode is node n, counted from 1.
func numberedNode(n int) (string, error) {
	if n < 1 || n > nodeCount {
		return "", fmt.Errorf("no node %d", n)
	}
	return nodeName(n - 1), nil
}

// onNewCAs: what the node serves and uses comes from the new CAs. Its API
// server and kubelet serve a certificate of the new server CA, etcd's
// client and peer ports one of the new etcd server and peer CAs. The
// node's own admin kubeconfig has a client certificate of the new client
// CA, and the node's API server takes it. The API server's proxy
// certificate is of the new request-header CA, and a request through it to
// metrics-server works. A request through the API server to the node's
// kubelet works, which needs each to take the other's new certificate.
func onNewCAs(ctx context.Context, s *scenario, a args) error {
	if s.newCAs == nil {
		return errors.New("no new k3s CAs were stored")
	}
	node, err := numberedNode(a.ns[0])
	if err != nil {
		return err
	}
	ip := nodeIP(a.ns[0] - 1)
	for _, l := range []struct{ what, port, ca string }{
		{"the API server", "6443", "server"},
		{"the kubelet", "10250", "server"},
		{"etcd", "2379", "etcd/server"},
		{"etcd's peer port", "2380", "etcd/peer"},
	} {
		cert, err := servedCert(ctx, net.JoinHostPort(ip, l.port))
		if err == nil {
			err = verifyNew(s.newCAs, l.ca, cert)
		}
		if err != nil {
			return fmt.Errorf("%s of %s: %w", l.what, node, err)
		}
	}
	config, admin, err := nodeKubeconfig(ctx, node, ip)
	if err == nil {
		err = verifyNew(s.newCAs, "client", admin)
	}
	if err != nil {
		return fmt.Errorf("the admin kubeconfig of %s: %w", node, err)
	}
	proxy, err := nodeFile(ctx, node, k3sServerDir+"/tls/client-auth-proxy.crt")
	if err == nil {
		err = verifyNew(s.newCAs, "request-header", proxy)
	}
	if err != nil {
		return fmt.Errorf("the API server's proxy certificate of %s: %w", node, err)
	}
	for _, path := range []string{"/apis/metrics.k8s.io/v1beta1/nodes", "/api/v1/nodes/" + node + "/proxy/healthz"} {
		if _, err := kubectl(ctx, "--kubeconfig", config, "get", "--raw", path); err != nil {
			return err
		}
	}
	return nil
}

// servedCert is the certificate a TLS port serves. The check of it is
// verifyNew's, against the new CAs alone.
func servedCert(ctx context.Context, addr string) (*x509.Certificate, error) {
	var cert *x509.Certificate
	dialer := &tls.Dialer{
		NetDialer: &net.Dialer{Timeout: 10 * time.Second},
		Config: &tls.Config{
			InsecureSkipVerify: true,
			VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
				if len(raw) == 0 {
					return errors.New("no certificate")
				}
				var err error
				cert, err = x509.ParseCertificate(raw[0])
				return err
			},
		},
	}
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		// etcd ends the handshake when no client certificate comes, after
		// it sent its own.
		if cert != nil {
			return cert, nil
		}
		return nil, err
	}
	return cert, conn.Close()
}

// verifyNew checks that the new CA of that name issued the certificate.
func verifyNew(pools map[string]x509.VerifyOptions, ca string, cert *x509.Certificate) error {
	if _, err := cert.Verify(pools[ca]); err != nil {
		return fmt.Errorf("%q, issued by %q, is not of the new %s CA: %w", cert.Subject.CommonName, cert.Issuer.CommonName, ca, err)
	}
	return nil
}

// firstCert is the first certificate of PEM data.
func firstCert(data []byte) (*x509.Certificate, error) {
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("no certificate first in the PEM data")
	}
	return x509.ParseCertificate(block.Bytes)
}

// nodeFile is the certificate in a file of the node.
func nodeFile(ctx context.Context, node, path string) (*x509.Certificate, error) {
	data, err := copyFromNode(ctx, node, path)
	if err != nil {
		return nil, err
	}
	return firstCert(data)
}

// copyFromNode is the content of a file of the node.
func copyFromNode(ctx context.Context, node, path string) ([]byte, error) {
	local := filepath.Join(workDir, node+"-"+filepath.Base(path))
	if _, err := command(ctx, "docker", "cp", node+":"+path, local); err != nil {
		return nil, err
	}
	return os.ReadFile(local)
}

var clientCertData = regexp.MustCompile(`client-certificate-data: (\S+)`)

// nodeKubeconfig is a copy of the admin kubeconfig k3s wrote on the node,
// which reaches that node's API server, and its client certificate.
func nodeKubeconfig(ctx context.Context, node, ip string) (string, *x509.Certificate, error) {
	data, err := copyFromNode(ctx, node, "/etc/rancher/k3s/k3s.yaml")
	if err != nil {
		return "", nil, err
	}
	m := clientCertData.FindSubmatch(data)
	if m == nil {
		return "", nil, errors.New("no client-certificate-data")
	}
	certPEM, err := base64.StdEncoding.DecodeString(string(m[1]))
	if err != nil {
		return "", nil, err
	}
	cert, err := firstCert(certPEM)
	if err != nil {
		return "", nil, err
	}
	config := filepath.Join(workDir, "kubeconfig-"+node)
	data = []byte(strings.ReplaceAll(string(data), "https://127.0.0.1:6443", "https://"+ip+":6443"))
	return config, cert, os.WriteFile(config, data, 0o600)
}

// etcdHealthy: etcd has three members, none a learner, and each member
// answers its status without errors and knows a leader. It asks over gRPC
// on each node's client port, with the etcd client certificate of the first
// node.
func etcdHealthy(ctx context.Context, s *scenario, _ args) error {
	node := nodeName(0)
	certPEM, err := copyFromNode(ctx, node, k3sServerDir+"/tls/etcd/client.crt")
	if err != nil {
		return err
	}
	keyPEM, err := copyFromNode(ctx, node, k3sServerDir+"/tls/etcd/client.key")
	if err != nil {
		return err
	}
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return err
	}
	endpoints := make([]string, nodeCount)
	for i := range endpoints {
		endpoints[i] = net.JoinHostPort(nodeIP(i), "2379")
	}
	client, err := clientv3.New(clientv3.Config{
		Endpoints: endpoints, DialTimeout: 10 * time.Second, Logger: zap.NewNop(),
		// Which CA etcd's certificate is of is onNewCAs's check.
		TLS: &tls.Config{Certificates: []tls.Certificate{pair}, InsecureSkipVerify: true},
	})
	if err != nil {
		return err
	}
	err = etcdMembersHealthy(ctx, client, endpoints, s)
	return errors.Join(err, client.Close())
}

func etcdMembersHealthy(ctx context.Context, client *clientv3.Client, endpoints []string, s *scenario) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	list, err := client.MemberList(ctx)
	if err != nil {
		return err
	}
	var names []string
	for _, m := range list.Members {
		if m.IsLearner {
			return fmt.Errorf("etcd member %s is a learner", m.Name)
		}
		names = append(names, m.Name)
	}
	if len(names) != nodeCount {
		return fmt.Errorf("etcd has %d members: %s", len(names), strings.Join(names, ", "))
	}
	for _, endpoint := range endpoints {
		status, err := client.Status(ctx, endpoint)
		if err != nil {
			return fmt.Errorf("etcd at %s: %w", endpoint, err)
		}
		if len(status.Errors) > 0 || status.Leader == 0 {
			return fmt.Errorf("etcd at %s: leader %x, errors %v", endpoint, status.Leader, status.Errors)
		}
	}
	s.detail = "members " + strings.Join(names, ", ")
	return nil
}

// everyNodeReady: every node is Ready.
func everyNodeReady(ctx context.Context, _ *scenario, _ args) error {
	for i := range nodeCount {
		if err := nodeReady(ctx, nodeName(i)); err != nil {
			return err
		}
	}
	return nil
}
