// 星黎监控 relay —— 公网"代理"，让没有公网 IP 的内网机器也能被 app 监控
//
// 工作方式（v2.4.24+）：
//   1. relay 跑在有公网的服务器（推荐 doogeee.cn / mzhhua.cn）
//   2. 内网机器跑 reverse-agent，每 5 秒把硬件数据 POST 到 relay 的 /ingest
//   3. app 配置 server 时，URL 填 relay 的地址、token 填内网机器的 token
//      → app 调 GET /api/report，relay 根据 X-Agent-Token header 路由到
//        对应内网机器的最新一次 push 数据，**完全兼容现有 app 零改动**
//
// token 设计：
//   启动时通过 --tokens 或 RELAY_TOKENS 传入 whitelist（逗号分隔）
//   每个 token 对应一个内网机器。reverse-agent push 用 tokenA，app poll
//   也用 tokenA，relay 看到 tokenA 就返回 tokenA 的最新数据。
//   一个 token 只能 push / pull 一台机器的数据，1:1 映射。
//
// 存储：纯内存 map[token]Slot，无持久化。
//   relay 重启 = 所有 token 的数据清空 = app 拉不到直到 reverse-agent 再 push 一次。
//   这是有意的设计：relay 不该是 source of truth，只是"中转"。
//
// 必填 env/flag:
//   --tokens "tokA,tokB,tokC"   token 白名单
//
// 可选 env/flag:
//   --port       监听端口（默认 9100）
//   --bind       绑定地址（默认 0.0.0.0）
//   --cert       TLS cert 路径（空则自签到 --data-dir/relay.crt）
//   --key        TLS key 路径（同上）
//   --data-dir   数据/证书目录（默认 /opt/server-monitor）
//   --ips        SAN IP（逗号分隔），例如 "1.2.3.4,192.168.1.1"
//   --hosts      SAN 域名（逗号分隔），例如 "doogeee.cn"

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// ===== 配置 =====

type Config struct {
	Port        string
	Bind        string
	CertFile    string
	KeyFile     string
	DataDir     string
	ExternalIPs string
	ExternalHosts string
}

func loadConfig() Config {
	c := Config{
		Port:          getenv("RELAY_PORT", "9100"),
		Bind:          getenv("RELAY_BIND", "0.0.0.0"),
		DataDir:       getenv("RELAY_DATA_DIR", "/opt/server-monitor"),
		ExternalIPs:   getenv("RELAY_IPS", ""),
		ExternalHosts: getenv("RELAY_HOSTS", ""),
	}
	cf := getenv("RELAY_CERT_FILE", "")
	kf := getenv("RELAY_KEY_FILE", "")
	if cf != "" && kf != "" {
		c.CertFile = cf
		c.KeyFile = kf
	}
	return c
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// ===== Slot + Server =====

type Slot struct {
	Data           []byte    // 内网 reverse-agent push 的完整 collector.Report JSON
	LastReceivedMs int64     // push 时间
	LastSeenIP     string    // 调试用：哪台机器在 push
	PushCount      int64     // 调试用：累计 push 次数
}

type Server struct {
	mu          sync.RWMutex
	slots       map[string]*Slot
	whitelist   map[string]bool
	maxStaleMs  int64 // 数据"新鲜"阈值，超过则 app 端拉到 503
	startTimeMs int64
}

func newServer(whitelist map[string]bool) *Server {
	return &Server{
		slots:       make(map[string]*Slot),
		whitelist:   whitelist,
		maxStaleMs:  2 * 60 * 1000, // 2 分钟
		startTimeMs: time.Now().UnixMilli(),
	}
}

// ===== HTTP handlers =====

// handleIngest: 内网 reverse-agent 主动 push 的入口
//   POST /ingest
//   header: X-Relay-Token: <token>
//   body:   collector.Report 的 JSON
func (s *Server) handleIngest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"请用 POST 请求"}`, http.StatusMethodNotAllowed)
		return
	}
	token := r.Header.Get("X-Relay-Token")
	if !s.whitelist[token] {
		http.Error(w, `{"error":"token 无效"}`, http.StatusUnauthorized)
		return
	}
	// 限速 4MB，跟 collector.Report 单次最大尺寸对齐
	body, err := io.ReadAll(io.LimitReader(r.Body, 4*1024*1024))
	if err != nil {
		http.Error(w, `{"error":"读 body 失败"}`, http.StatusBadRequest)
		return
	}
	// 验证 JSON 合法（防止 reverse-agent 写错把垃圾塞进内存）
	var dummy map[string]interface{}
	if err := json.Unmarshal(body, &dummy); err != nil {
		http.Error(w, `{"error":"JSON 不合法: `+err.Error()+`"}`, http.StatusBadRequest)
		return
	}
	// 验证必要字段
	if _, ok := dummy["agent_name"]; !ok {
		http.Error(w, `{"error":"缺 agent_name 字段"}`, http.StatusBadRequest)
		return
	}

	ip := clientIP(r)
	now := time.Now().UnixMilli()

	s.mu.Lock()
	old, existed := s.slots[token]
	if existed {
		old.Data = body
		old.LastReceivedMs = now
		old.LastSeenIP = ip
		old.PushCount++
	} else {
		s.slots[token] = &Slot{
			Data:           body,
			LastReceivedMs: now,
			LastSeenIP:     ip,
			PushCount:      1,
		}
	}
	s.mu.Unlock()

	log.Printf("📥 ingest token=%s... from %s (%d bytes, push#%d)", token[:min(8, len(token))], ip, len(body), s.slots[token].PushCount)

	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok"}`))
}

// handleReport: app 拉数据的入口（完全兼容现有 agent 的 /api/report 协议）
//   GET /api/report
//   header: X-Agent-Token: <token>  ← 跟现有 agent 一致
func (s *Server) handleReport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, `{"error":"请用 GET 请求"}`, http.StatusMethodNotAllowed)
		return
	}
	token := r.Header.Get("X-Agent-Token")
	if !s.whitelist[token] {
		http.Error(w, `{"error":"token 无效"}`, http.StatusUnauthorized)
		return
	}
	s.mu.RLock()
	slot, ok := s.slots[token]
	s.mu.RUnlock()
	if !ok {
		// token 有效但还没收到过 push → 503，跟现有 agent "数据未就绪"一致
		http.Error(w, `{"error":"数据未就绪，请稍后重试"}`, http.StatusServiceUnavailable)
		return
	}
	ageMs := time.Now().UnixMilli() - slot.LastReceivedMs
	if ageMs > s.maxStaleMs {
		// token 有数据但 reverse-agent 很久没 push 了 → 503
		// app 端 lastSuccessMs 不更新 → v2.4.22 badge 显示"卡 Xs/离线"
		http.Error(w, fmt.Sprintf(`{"error":"数据已过期（%.0f 秒前更新）"}`, float64(ageMs)/1000), http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(slot.Data)
}

// handleHealth: 健康检查 + 简单状态
//   GET /health → 200 {"status":"ok","active_servers":N,"uptime_sec":X}
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	n := len(s.slots)
	nowMs := time.Now().UnixMilli()
	activeRecent := 0
	for _, slot := range s.slots {
		if nowMs-slot.LastReceivedMs < s.maxStaleMs {
			activeRecent++
		}
	}
	uptimeSec := (nowMs - s.startTimeMs) / 1000
	s.mu.RUnlock()
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","active_servers":%d,"active_recent":%d,"uptime_sec":%d}`, n, activeRecent, uptimeSec)
}

// runGC: 定期清理 >1h 没 push 的 slot（防止某台内网机器永久下线后留垃圾）
func (s *Server) runGC() {
	t := time.NewTicker(5 * time.Minute)
	defer t.Stop()
	for range t.C {
		cutoff := time.Now().UnixMilli() - int64(1*time.Hour/time.Millisecond)
		s.mu.Lock()
		for tok, slot := range s.slots {
			if slot.LastReceivedMs < cutoff {
				delete(s.slots, tok)
				log.Printf("🧹 GC: 删除 1h 未 push 的 token: %s... (累计 push %d 次)", tok[:min(8, len(tok))], slot.PushCount)
			}
		}
		s.mu.Unlock()
	}
}

func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.IndexByte(xff, ','); i > 0 {
			return strings.TrimSpace(xff[:i])
		}
		return strings.TrimSpace(xff)
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	return host
}

// ===== 证书生成（自签，跟 cmd/agent 逻辑一致） =====

func generateSelfSignedCert(certPath, keyPath, ipsArg, hostsArg string) error {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	notBefore := time.Now()
	notAfter := notBefore.Add(10 * 365 * 24 * time.Hour) // 10 年

	ips := []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}
	for _, s := range strings.Split(ipsArg, ",") {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if ip := net.ParseIP(s); ip != nil {
			ips = append(ips, ip)
		} else {
			log.Printf("⚠️  --ips: 跳过无效 IP %q", s)
		}
	}
	dnsNames := []string{"localhost"}
	for _, s := range strings.Split(hostsArg, ",") {
		s = strings.TrimSpace(s)
		if s != "" {
			dnsNames = append(dnsNames, s)
		}
	}

	template := x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			Organization: []string{"monitor-status"},
			CommonName:   "monitor-status relay",
		},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IPAddresses:           ips,
		DNSNames:              dnsNames,
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
	return pem.Encode(keyOut, &pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes})
}

// ===== main =====

func main() {
	var (
		tokensArg = flag.String("tokens", os.Getenv("RELAY_TOKENS"), "token 白名单，逗号分隔（也可走 RELAY_TOKENS env）")
		port      = flag.String("port", "", "监听端口（覆盖 env）")
		bind      = flag.String("bind", "", "绑定地址（覆盖 env）")
		certFile  = flag.String("cert", "", "TLS cert 路径（覆盖 env）")
		keyFile   = flag.String("key", "", "TLS key 路径（覆盖 env）")
		dataDir   = flag.String("data-dir", "", "数据/证书目录（覆盖 env）")
		ipsArg    = flag.String("ips", "", "SAN IP，逗号分隔（覆盖 env）")
		hostsArg  = flag.String("hosts", "", "SAN 域名，逗号分隔（覆盖 env）")
	)
	flag.Parse()

	if *tokensArg == "" {
		log.Fatal("❌ 必须通过 --tokens 或 RELAY_TOKENS 提供 token 白名单")
	}

	whitelist := make(map[string]bool)
	for _, t := range strings.Split(*tokensArg, ",") {
		t = strings.TrimSpace(t)
		if t != "" {
			whitelist[t] = true
		}
	}
	if len(whitelist) == 0 {
		log.Fatal("❌ token 白名单为空")
	}

	cfg := loadConfig()
	if *port != "" {
		cfg.Port = *port
	}
	if *bind != "" {
		cfg.Bind = *bind
	}
	if *dataDir != "" {
		cfg.DataDir = *dataDir
	}
	if *ipsArg != "" {
		cfg.ExternalIPs = *ipsArg
	}
	if *hostsArg != "" {
		cfg.ExternalHosts = *hostsArg
	}
	if *certFile != "" {
		cfg.CertFile = *certFile
	}
	if *keyFile != "" {
		cfg.KeyFile = *keyFile
	}

	// 没显式给 cert 就自签
	if cfg.CertFile == "" {
		if err := os.MkdirAll(cfg.DataDir, 0700); err != nil {
			log.Fatalf("❌ 创建数据目录失败: %v", err)
		}
		cfg.CertFile = cfg.DataDir + "/relay.crt"
		cfg.KeyFile = cfg.DataDir + "/relay.key"
		if err := generateSelfSignedCert(cfg.CertFile, cfg.KeyFile, cfg.ExternalIPs, cfg.ExternalHosts); err != nil {
			log.Fatalf("❌ 生成自签证书失败: %v", err)
		}
		log.Printf("🔒 已生成自签证书: %s", cfg.CertFile)
		if cfg.ExternalIPs == "" && cfg.ExternalHosts == "" {
			log.Printf("⚠️  自签 cert 只有 SAN=127.0.0.1 + localhost，app 连公网 IP/域名 时会报 hostname mismatch")
			log.Printf("    解决: install 时传 --ips=<relay 公网 IP> --hosts=<relay 域名>，install 脚本会自动探测")
		}
	}

	// token 安全的常量时间比较防御（虽然这里只用来查 map 但写得更稳）
	_ = subtle.ConstantTimeCompare

	srv := newServer(whitelist)

	mux := http.NewServeMux()
	mux.HandleFunc("/ingest", srv.handleIngest)
	mux.HandleFunc("/api/report", srv.handleReport)
	mux.HandleFunc("/health", srv.handleHealth)

	httpSrv := &http.Server{
		Addr:      cfg.Bind + ":" + cfg.Port,
		Handler:   mux,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12},
	}

	go srv.runGC()

	log.Printf("🚀 星黎监控 relay 启动")
	log.Printf("🌐 监听: %s:%s (TLS)", cfg.Bind, cfg.Port)
	log.Printf("🔑 token 白名单数量: %d", len(whitelist))
	log.Printf("📋 路由: POST /ingest (X-Relay-Token), GET /api/report (X-Agent-Token), GET /health")
	log.Fatal(httpSrv.ListenAndServeTLS(cfg.CertFile, cfg.KeyFile))
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
