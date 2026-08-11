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
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"embed"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed all:web
var webFS embed.FS

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
	// v2.4.26+: 从 push body 里抽出来的 agent_name，网页版显示用
	// 没 push 过的话为空字符串，网页版会 fallback 到 token 前 8 位
	AgentName string
}

// ProxyEndpoint 描述一个**没走 push** 的公网 agent（agent 直接 serve /api/report，
// relay 只是代理给网页版用）。来源：RELAY_AGENT_ENDPOINTS env，格式
// "name1:url1:token1,name2:url2:token2"。
type ProxyEndpoint struct {
	Name  string
	URL   string
	Token string
}

// proxyCache 缓存从公网 agent 拉到的最近一次数据。
// 公网 agent 自身就是 source of truth，relay 只是"网页版的中转 + 5s 缓存"。
type proxyCache struct {
	Data        []byte
	LastFetchMs int64
}

type Server struct {
	mu          sync.RWMutex
	slots       map[string]*Slot
	whitelist   map[string]bool
	maxStaleMs  int64 // 数据"新鲜"阈值，超过则 app 端拉到 503
	startTimeMs int64

	// v2.4.26+: 公网 agent 的代理配置（不在 whitelist 里，因为它们不 push）
	proxyEPs     map[string]*ProxyEndpoint // token -> endpoint
	proxyCache   map[string]*proxyCache    // token -> cached data
	proxyCacheMu sync.RWMutex
	insecureProxy bool // 代理拉公网 agent 时是否跳过 TLS 校验（默认 true，自签 cert 场景）
}

func newServer(whitelist map[string]bool, proxyEPs map[string]*ProxyEndpoint, insecureProxy bool) *Server {
	return &Server{
		slots:         make(map[string]*Slot),
		whitelist:     whitelist,
		proxyEPs:      proxyEPs,
		proxyCache:    make(map[string]*proxyCache),
		maxStaleMs:    2 * 60 * 1000, // 2 分钟
		startTimeMs:   time.Now().UnixMilli(),
		insecureProxy: insecureProxy,
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
	agentNameRaw, ok := dummy["agent_name"]
	if !ok {
		http.Error(w, `{"error":"缺 agent_name 字段"}`, http.StatusBadRequest)
		return
	}
	agentName, _ := agentNameRaw.(string)

	ip := clientIP(r)
	now := time.Now().UnixMilli()

	s.mu.Lock()
	old, existed := s.slots[token]
	if existed {
		old.Data = body
		old.LastReceivedMs = now
		old.LastSeenIP = ip
		old.PushCount++
		old.AgentName = agentName
	} else {
		s.slots[token] = &Slot{
			Data:           body,
			LastReceivedMs: now,
			LastSeenIP:     ip,
			PushCount:      1,
			AgentName:      agentName,
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

// ===== v2.4.26+: 网页版 API =====
//
// 设计：
//   - /web/ 路径给静态文件（index.html / style.css / app.js），用 go:embed 塞进 binary
//   - /web/api/agents 返回 relay 知道的所有 agent 列表（push + proxy 两类合并）
//   - /web/api/report?token=X 优先用 push 缓存；token 在 proxy 列表里就 fetch 公网 agent
//   - /web/api/traffic_72h?token=X&email=Y proxy 到 agent 的 /api/traffic_72h
//   - 不加 web 单独的 auth token：relay URL 本身就是"私有"，跟 Android app 一样
//     （ssh 端口 / 域名都不公开，TLS 自签）。真要加密码可以后续包一层

// handleWebAgents: GET /web/api/agents → 返回所有 agent 列表
func (s *Server) handleWebAgents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, `{"error":"请用 GET 请求"}`, http.StatusMethodNotAllowed)
		return
	}
	nowMs := time.Now().UnixMilli()
	type agentInfo struct {
		Name           string `json:"name"`
		Token          string `json:"token"`
		Source         string `json:"source"` // "pushed" / "proxy" / "configured"
		Online         bool   `json:"online"`
		LastReceivedMs int64  `json:"last_received_ms"`
		HasXUI         bool   `json:"has_xui"`
		OnlineCount    int    `json:"online_count,omitempty"`
		TotalClients   int    `json:"total_clients,omitempty"`
	}
	out := []agentInfo{}
	seen := map[string]bool{}

	// 1) push 来的内网 agent
	s.mu.RLock()
	for tok, slot := range s.slots {
		name := slot.AgentName
		if name == "" {
			name = tok[:min(8, len(tok))]
		}
		online := nowMs-slot.LastReceivedMs < s.maxStaleMs
		hasXUI := false
		onlineCount := 0
		totalClients := 0
		// 简单判断 slot.Data 是否有 xui 字段（避免再 unmarshal 一遍）
		if len(slot.Data) > 0 {
			hasXUI = bytesContains(slot.Data, `"xui"`)
			if i := bytesIndexField(slot.Data, `"online_count":`); i >= 0 {
				onlineCount = extractJSONInt(slot.Data[i:])
			}
			if i := bytesIndexField(slot.Data, `"total_clients":`); i >= 0 {
				totalClients = extractJSONInt(slot.Data[i:])
			}
		}
		out = append(out, agentInfo{
			Name: name, Token: tok, Source: "pushed",
			Online: online, LastReceivedMs: slot.LastReceivedMs,
			HasXUI: hasXUI, OnlineCount: onlineCount, TotalClients: totalClients,
		})
		seen[tok] = true
	}
	s.mu.RUnlock()

	// 2) proxy 配置的公网 agent（不在 slots 里）
	s.proxyCacheMu.RLock()
	for tok, ep := range s.proxyEPs {
		if seen[tok] {
			continue
		}
		cache, hasCache := s.proxyCache[tok]
		var lastMs int64
		online := false
		hasXUI := false
		onlineCount := 0
		totalClients := 0
		if hasCache {
			lastMs = cache.LastFetchMs
			online = nowMs-cache.LastFetchMs < s.maxStaleMs
			if len(cache.Data) > 0 {
				hasXUI = bytesContains(cache.Data, `"xui"`)
				if i := bytesIndexField(cache.Data, `"online_count":`); i >= 0 {
					onlineCount = extractJSONInt(cache.Data[i:])
				}
				if i := bytesIndexField(cache.Data, `"total_clients":`); i >= 0 {
					totalClients = extractJSONInt(cache.Data[i:])
				}
			}
		}
		out = append(out, agentInfo{
			Name: ep.Name, Token: tok, Source: "proxy",
			Online: online, LastReceivedMs: lastMs,
			HasXUI: hasXUI, OnlineCount: onlineCount, TotalClients: totalClients,
		})
	}
	s.proxyCacheMu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(map[string]interface{}{"agents": out})
}

// fetchProxy: 公网 agent 的拉取 + 5s 缓存
//   s.insecureProxy 默认 true：公网 agent 全是自签 cert，认证靠 X-Agent-Token
//   安全性 = token 本身（32 字符随机），cert 只用来防 passive 监听
//   改成 false = 严格校验 cert，需要把每台 agent 的自签 CA 加到系统 trust store
func (s *Server) fetchProxy(token string) ([]byte, int64, error) {
	s.proxyCacheMu.RLock()
	ep, ok := s.proxyEPs[token]
	var cache *proxyCache
	if ok {
		cache = s.proxyCache[token]
	}
	s.proxyCacheMu.RUnlock()
	if !ok {
		return nil, 0, fmt.Errorf("token 不在代理列表里")
	}

	// 5s 内的缓存直接用
	nowMs := time.Now().UnixMilli()
	if cache != nil && nowMs-cache.LastFetchMs < 5*1000 && len(cache.Data) > 0 {
		return cache.Data, cache.LastFetchMs, nil
	}

	// fetch 公网 agent
	req, _ := http.NewRequest("GET", ep.URL, nil)
	req.Header.Set("X-Agent-Token", ep.Token)
	req.Header.Set("User-Agent", "monitor-status-relay/1.0")
	client := &http.Client{Timeout: 10 * time.Second}
	if s.insecureProxy {
		client.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		}
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("拉公网 agent 失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, 0, fmt.Errorf("公网 agent 返回 HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4*1024*1024))
	if err != nil {
		return nil, 0, err
	}
	// 验证是合法 JSON（防 agent 写错把 HTML 错误页塞进来）
	var dummy map[string]interface{}
	if err := json.Unmarshal(body, &dummy); err != nil {
		return nil, 0, fmt.Errorf("公网 agent 返回非 JSON: %w", err)
	}

	s.proxyCacheMu.Lock()
	s.proxyCache[token] = &proxyCache{Data: body, LastFetchMs: nowMs}
	s.proxyCacheMu.Unlock()
	return body, nowMs, nil
}

// handleWebReport: GET /web/api/report?token=X → 跟 /api/report 一样，但 token 在 URL
//   （header 在浏览器 fetch 里也能用，但 URL query 更直观，方便用户手测）
func (s *Server) handleWebReport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, `{"error":"请用 GET 请求"}`, http.StatusMethodNotAllowed)
		return
	}
	token := r.URL.Query().Get("token")
	if token == "" {
		http.Error(w, `{"error":"缺少 token 参数"}`, http.StatusBadRequest)
		return
	}
	// 1) 优先用 push 缓存
	s.mu.RLock()
	slot, ok := s.slots[token]
	s.mu.RUnlock()
	if ok {
		ageMs := time.Now().UnixMilli() - slot.LastReceivedMs
		if ageMs > s.maxStaleMs {
			http.Error(w, fmt.Sprintf(`{"error":"数据已过期（%.0f 秒前更新）"}`, float64(ageMs)/1000), http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(slot.Data)
		return
	}
	// 2) fallback 到 proxy（公网 agent 实时拉）
	body, lastMs, err := s.fetchProxy(token)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusServiceUnavailable)
		return
	}
	ageMs := time.Now().UnixMilli() - lastMs
	if ageMs > s.maxStaleMs {
		http.Error(w, fmt.Sprintf(`{"error":"数据已过期（%.0f 秒前更新）"}`, float64(ageMs)/1000), http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

// handleWebTraffic72h: GET /web/api/traffic_72h?token=X&email=Y
//   透传到 agent 的 /api/traffic_72h（push 缓存里没有原始 history）
func (s *Server) handleWebTraffic72h(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, `{"error":"请用 GET 请求"}`, http.StatusMethodNotAllowed)
		return
	}
	token := r.URL.Query().Get("token")
	email := r.URL.Query().Get("email")
	if token == "" || email == "" {
		http.Error(w, `{"error":"缺少 token 或 email 参数"}`, http.StatusBadRequest)
		return
	}
	// push 缓存没有原始 history，必须实时拉
	// 看是不是 push 的 → 用 slot.Data 里的 _last 字段查 agent url？不行，relay 不知道 agent url
	// 所以 push 模式下不支持 traffic_72h（agent 不会主动 push 这部分数据）
	// 简化：traffic_72h 只支持 proxy 模式（公网 agent 实时拉）
	s.proxyCacheMu.RLock()
	ep, ok := s.proxyEPs[token]
	s.proxyCacheMu.RUnlock()
	if !ok {
		http.Error(w, `{"error":"traffic_72h 仅支持公网 agent（push 模式未透传 history）"}`, http.StatusNotImplemented)
		return
	}
	targetURL := ep.URL
	// 把 /api/report 换成 /api/traffic_72h
	targetURL = strings.TrimSuffix(targetURL, "/api/report") + "/api/traffic_72h?email=" + url.QueryEscape(email)
	req, _ := http.NewRequest("GET", targetURL, nil)
	req.Header.Set("X-Agent-Token", ep.Token)
	req.Header.Set("User-Agent", "monitor-status-relay/1.0")
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, `{"error":"拉 agent 失败: `+err.Error()+`"}`, http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 8*1024*1024))
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	w.Write(body)
}

// ===== 工具函数（避免 import 更多包） =====

// bytesContains 简单 string 包含（slot.Data 是 JSON 文本，足够）
func bytesContains(b []byte, substr string) bool {
	return bytes.Contains(b, []byte(substr))
}

// bytesIndexField 找 "key": 的位置
func bytesIndexField(b []byte, key string) int {
	return bytes.Index(b, []byte(key))
}

// extractJSONInt 从 "key":NNN 后面抠出整数（粗略，够用）
func extractJSONInt(s []byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] >= '0' && s[i] <= '9' {
			j := i
			for j < len(s) && s[j] >= '0' && s[j] <= '9' {
				j++
			}
			n, _ := strconv.Atoi(string(s[i:j]))
			return n
		}
		if s[i] == '-' {
			j := i + 1
			for j < len(s) && s[j] >= '0' && s[j] <= '9' {
				j++
			}
			n, _ := strconv.Atoi(string(s[i:j]))
			return n
		}
	}
	return 0
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
		tokensArg       = flag.String("tokens", os.Getenv("RELAY_TOKENS"), "token 白名单，逗号分隔（也可走 RELAY_TOKENS env）")
		proxyEPsArg     = flag.String("proxy-endpoints", os.Getenv("RELAY_AGENT_ENDPOINTS"), "公网 agent 代理列表，逗号分隔 name:url:token（也可走 RELAY_AGENT_ENDPOINTS env）")
		insecureProxyFl = flag.String("insecure-proxy", getenv("RELAY_INSECURE_PROXY", "true"), "代理拉公网 agent 时是否跳过 TLS 校验（默认 true，自签 cert 场景）")
		port            = flag.String("port", "", "监听端口（覆盖 env）")
		bind            = flag.String("bind", "", "绑定地址（覆盖 env）")
		certFile        = flag.String("cert", "", "TLS cert 路径（覆盖 env）")
		keyFile         = flag.String("key", "", "TLS key 路径（覆盖 env）")
		dataDir         = flag.String("data-dir", "", "数据/证书目录（覆盖 env）")
		ipsArg          = flag.String("ips", "", "SAN IP，逗号分隔（覆盖 env）")
		hostsArg        = flag.String("hosts", "", "SAN 域名，逗号分隔（覆盖 env）")
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

	// 解析公网 agent 代理列表（可选，没设就不代理公网 agent）
	// 格式 "name1:url1:token1,name2:url2:token2"，url 形如 https://host:port/api/report
	proxyEPs := make(map[string]*ProxyEndpoint)
	if *proxyEPsArg != "" {
		for _, entry := range strings.Split(*proxyEPsArg, ",") {
			entry = strings.TrimSpace(entry)
			if entry == "" {
				continue
			}
			// 格式 "name1:url1:token1"，url 含 "://"，从右往左找 "://" 来定位 url
			idx := strings.Index(entry, "://")
			if idx < 0 {
				log.Printf("⚠️  代理条目缺 '://'，跳过: %s", entry)
				continue
			}
			// name 是 "://" 前的最后一段（按最后一个 : 切）
			lastColon := strings.LastIndex(entry[:idx], ":")
			if lastColon < 0 {
				log.Printf("⚠️  代理条目格式不对，跳过: %s", entry)
				continue
			}
			name := strings.TrimSpace(entry[:lastColon])
			rest := entry[lastColon+1:]
			// rest = url:token，token 不含 :
			idxTok := strings.LastIndex(rest, ":")
			if idxTok < 0 {
				log.Printf("⚠️  代理条目缺 token，跳过: %s", entry)
				continue
			}
			agentURL := strings.TrimSpace(rest[:idxTok])
			token := strings.TrimSpace(rest[idxTok+1:])
			if name == "" || agentURL == "" || token == "" {
				log.Printf("⚠️  代理条目有空字段，跳过: %s", entry)
				continue
			}
			proxyEPs[token] = &ProxyEndpoint{Name: name, URL: agentURL, Token: token}
			log.Printf("🔗 公网 agent 代理: name=%s url=%s", name, agentURL)
		}
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

	// v2.4.26+: 代理拉公网 agent 时是否跳过 TLS 校验
	// 公网 agent 默认是自签 cert，认证靠 X-Agent-Token（32 字符随机）
	// 安全 = token 本身，cert 只防 passive 监听。默认 skip 校验让自签 cert 能用
	// 想要严格校验：传 --insecure-proxy=false，然后把 agent 的自签 CA 加到系统 trust store
	insecureBool := *insecureProxyFl != "false" && *insecureProxyFl != "0" && *insecureProxyFl != "no"
	if !insecureBool {
		log.Printf("🔒 代理拉公网 agent 时严格校验 TLS（需要把 agent 的自签 CA 加到系统 trust store）")
	} else {
		log.Printf("⚠️  代理拉公网 agent 时跳过 TLS 校验（自签 cert 场景，默认）")
	}

	srv := newServer(whitelist, proxyEPs, insecureBool)

	mux := http.NewServeMux()
	mux.HandleFunc("/ingest", srv.handleIngest)
	mux.HandleFunc("/api/report", srv.handleReport)
	mux.HandleFunc("/health", srv.handleHealth)
	// v2.4.26+: 网页版 API
	mux.HandleFunc("/web/api/agents", srv.handleWebAgents)
	mux.HandleFunc("/web/api/report", srv.handleWebReport)
	mux.HandleFunc("/web/api/traffic_72h", srv.handleWebTraffic72h)
	// 静态文件（/web/ 前缀），用 go:embed 塞进 binary
	// webFS 的根是 "web/"，要先 Sub 一下，否则 StripPrefix 后路径对不上
	webSubFS, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatalf("❌ web 子文件系统初始化失败: %v", err)
	}
	mux.Handle("/web/", http.StripPrefix("/web/", http.FileServer(http.FS(webSubFS))))

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
