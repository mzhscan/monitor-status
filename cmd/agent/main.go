// 星黎监控 agent —— 轻量 HTTP server
//
// 每台被监控机器跑一个 agent，对外暴露 /health + /api/report。Flutter
// 客户端直连 agent（不再有中央 backend）。配置全部走环境变量，二进制
// 在所有平台上通用。
//
// 必填 env:
//   AGENT_NAME     —— agent 名字，例如 "my-server"
//   AGENT_TOKEN    —— 共享密钥，app 连过来时放在 X-Agent-Token header
//
// 可选 env:
//   AGENT_PORT     —— 监听端口，默认 9101
//   USE_TLS        —— "true" 启 HTTPS（默认 true）
//   CERT_FILE      —— 显式证书路径（覆盖下面的所有自动查找）
//   KEY_FILE       —— 显式私钥路径
//   XUI_DB_PATH    —— 3x-ui sqlite 路径，默认 /etc/x-ui/x-ui.db
//   TRAFFIC_72H_FILE —— 72h 流量历史 JSON 文件
//   COLLECT_INTERVAL —— 采集间隔（秒），默认 2
//
// 证书自动查找顺序（USE_TLS=true 时）:
//   1. CERT_FILE / KEY_FILE 显式指定
//   2. trim OS 自动加载（/usr/trim/etc/network_gateway_cert.conf）
//   3. 3x-ui 部署时生成的证书 (/root/cert/{ip,domain}/)
//   4. 都不行 → 自动生成自签证书到 /opt/server-monitor/certs/

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/mzhscan/monitor-status/pkg/collector"
)

// ===== 配置 =====

type Config struct {
	AgentName       string
	AgentToken      string
	Port            string
	UseTLS          bool
	CertFile        string
	KeyFile         string
	XUIDBPath       string
	Traffic72hFile  string
	CollectInterval time.Duration
}

func loadConfig() Config {
	c := Config{
		AgentName:       getenv("AGENT_NAME", "agent"),
		AgentToken:      os.Getenv("AGENT_TOKEN"),
		Port:            getenv("AGENT_PORT", "9101"),
		UseTLS:          getenv("USE_TLS", "true") == "true", // 默认启 HTTPS
		XUIDBPath:       getenv("XUI_DB_PATH", "/etc/x-ui/x-ui.db"),
		Traffic72hFile:  getenv("TRAFFIC_72H_FILE", "/opt/server-monitor/data/traffic_72h.json"),
		CollectInterval: time.Duration(getenvInt("COLLECT_INTERVAL", 2)) * time.Second,
	}
	if c.AgentToken == "" {
		log.Fatal("❌ 缺少 AGENT_TOKEN 环境变量")
	}
	if c.UseTLS {
		if err := c.resolveCert(); err != nil {
			log.Fatalf("❌ HTTPS 证书准备失败: %v", err)
		}
	}
	return c
}

// resolveCert picks the right cert+key for this host. Priority:
//   1. explicit CERT_FILE / KEY_FILE
//   2. trim OS cert (network_gateway_cert.conf)
//   3. 3x-ui cert at /root/cert/{ip,domain}/
//   4. self-signed at /opt/server-monitor/certs/
// Steps 2-4 are auto — install-agent.sh sets CERT_FILE explicitly.
func (c *Config) resolveCert() error {
	if cf := os.Getenv("CERT_FILE"); cf != "" {
		c.CertFile = cf
		c.KeyFile = getenv("KEY_FILE", "")
		if c.KeyFile == "" {
			return fmt.Errorf("CERT_FILE 设了但 KEY_FILE 没设")
		}
		log.Printf("🔒 使用显式证书: %s", c.CertFile)
		return nil
	}
	// trim OS (用 TLS_HOST 决定查哪个 host)
	if host := os.Getenv("TLS_HOST"); host != "" {
		if cert, key, ok := loadTrimCert(host); ok {
			c.CertFile, c.KeyFile = cert, key
			log.Printf("🔒 使用 trim OS 证书 (host=%s)", host)
			return nil
		}
		log.Printf("⚠️  trim cert 未找到 host=%s, 继续尝试其他来源", host)
	}
	// 3x-ui 部署自带的证书
	for _, base := range []string{"/root/cert/ip", "/root/cert/domain"} {
		cert := base + "/fullchain.pem"
		key := base + "/privkey.pem"
		if fileExists(cert) && fileExists(key) {
			c.CertFile, c.KeyFile = cert, key
			log.Printf("🔒 使用 3x-ui 证书: %s", cert)
			return nil
		}
	}
	// 都没找到 → 自动生成自签证书
	log.Printf("⚠️  没找到任何证书，自动生成自签证书...")
	dir := "/opt/server-monitor/certs"
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	c.CertFile = filepath.Join(dir, "cert.pem")
	c.KeyFile = filepath.Join(dir, "key.pem")
	if fileExists(c.CertFile) && fileExists(c.KeyFile) {
		log.Printf("🔒 使用已存在的自签证书: %s", c.CertFile)
		return nil
	}
	if err := generateSelfSignedCert(c.CertFile, c.KeyFile); err != nil {
		return fmt.Errorf("生成自签证书失败: %w", err)
	}
	log.Printf("🔒 已生成自签证书: %s", c.CertFile)
	log.Printf("⚠️  app 首次连会提示「是否信任此证书」，显示 SHA-256 指纹让用户核对")
	return nil
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func getenvInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// ===== Trim OS 证书自动加载 =====

type TrimCertEntry struct {
	Host string `json:"host"`
	Cert string `json:"cert"`
	Key  string `json:"key"`
}

func loadTrimCert(host string) (string, string, bool) {
	configPath := "/usr/trim/etc/network_gateway_cert.conf"
	data, err := os.ReadFile(configPath)
	if err != nil {
		return "", "", false
	}
	var entries []TrimCertEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		return "", "", false
	}
	for _, target := range []string{host, "fallback"} {
		for _, e := range entries {
			if e.Host == target {
				return e.Cert, e.Key, true
			}
		}
	}
	return "", "", false
}

// ===== 自签证书生成（fallback） =====

func generateSelfSignedCert(certPath, keyPath string) error {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	notBefore := time.Now()
	notAfter := notBefore.Add(10 * 365 * 24 * time.Hour) // 10 年

	template := x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			Organization: []string{"monitor-status"},
			CommonName:   "monitor-status agent",
		},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
		DNSNames:              []string{"localhost"},
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return err
	}

	certOut, err := os.OpenFile(certPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer certOut.Close()
	if err := pem.Encode(certOut, &pem.Block{Type: "CERTIFICATE", Bytes: derBytes}); err != nil {
		return err
	}

	keyBytes, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return err
	}
	keyOut, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer keyOut.Close()
	if err := pem.Encode(keyOut, &pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes}); err != nil {
		return err
	}
	return nil
}

// ===== HTTP server =====

var (
	mu         sync.RWMutex
	latestData *collector.Report
	cfgMu      sync.RWMutex
	cfg        Config
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	cfg = loadConfig()

	log.Printf("🚀 星黎监控 agent [%s] 启动", cfg.AgentName)
	log.Printf("🌐 监听端口: %s (TLS=%v)", cfg.Port, cfg.UseTLS)
	if cfg.UseTLS {
		log.Printf("🔒 证书: %s", cfg.CertFile)
		log.Printf("🔒 私钥: %s", cfg.KeyFile)
	}

	collector.Traffic72hFile = cfg.Traffic72hFile
	if err := collector.LoadTraffic72h(); err != nil {
		log.Printf("⚠️ 加载 72h 历史失败: %v", err)
	}
	go func() {
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for range t.C {
			if err := collector.SaveTraffic72h(); err != nil {
				log.Printf("⚠️ 保存 72h 历史失败: %v", err)
			}
		}
	}()
	defer func() {
		if err := collector.SaveTraffic72h(); err != nil {
			log.Printf("⚠️ 最后保存 72h 历史失败: %v", err)
		}
	}()

	go runCollectorLoop()

	mux := http.NewServeMux()
	mux.HandleFunc("/api/report", handleReport)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"status":"ok"}`))
	})

	srv := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: mux,
	}
	if cfg.UseTLS && cfg.CertFile != "" && cfg.KeyFile != "" {
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
		go func() {
			log.Printf("🔒 启动 HTTPS 监听")
			if err := srv.ListenAndServeTLS(cfg.CertFile, cfg.KeyFile); err != nil {
				log.Fatalf("❌ ListenAndServeTLS: %v", err)
			}
		}()
	} else {
		go func() {
			log.Printf("⚠️  启动 HTTP 监听（不安全！建议 USE_TLS=true）")
			if err := srv.ListenAndServe(); err != nil {
				log.Fatalf("❌ ListenAndServe: %v", err)
			}
		}()
	}
	select {}
}

func runCollectorLoop() {
	t := time.NewTicker(cfg.CollectInterval)
	defer t.Stop()
	for range t.C {
		data := collector.Collect(cfg.AgentName, cfg.XUIDBPath)
		mu.Lock()
		latestData = data
		mu.Unlock()
	}
}

func handleReport(w http.ResponseWriter, r *http.Request) {
	token := r.Header.Get("X-Agent-Token")
	if token == "" {
		http.Error(w, `{"error":"缺少 X-Agent-Token"}`, 401)
		return
	}
	cfgMu.RLock()
	want := cfg.AgentToken
	cfgMu.RUnlock()
	if subtleConstEq(token, want) != 1 {
		http.Error(w, `{"error":"token 无效"}`, 401)
		return
	}
	mu.RLock()
	data := latestData
	mu.RUnlock()
	if data == nil {
		http.Error(w, `{"error":"数据未就绪，请稍后重试"}`, 503)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("⚠️ encode report: %v", err)
	}
}

func subtleConstEq(a, b string) int {
	if len(a) != len(b) {
		return 0
	}
	var v byte
	for i := 0; i < len(a); i++ {
		v |= a[i] ^ b[i]
	}
	if v == 0 {
		return 1
	}
	return 0
}
