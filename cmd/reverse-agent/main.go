// 星黎监控 reverse-agent —— 内网机器的"主动上报"客户端
//
// 给没公网 IP 的内网机器用。直连复用 pkg/collector.Collect()（跟 cmd/agent
// 同一份代码），周期性把 collect 出来的 Report JSON POST 到 relay 的 /ingest。
// relay 收到后存内存，app 来 GET /api/report 时按 token 路由返回。
//
// 工作方式（v2.4.24+）：
//   - 启动时立即 push 一次（warmup）
//   - 然后每 --interval 秒 push 一次
//   - 失败重试：1s → 2s → 4s → 8s → 16s → 30s（cap 30s）
//   - 启动时 GET relay /health 检查可达
//
// 必填 env/flag:
//   --relay-url   relay 的 URL（如 https://doogeee.cn:9100）
//   --token       X-Relay-Token 值（必须跟 relay 白名单里的某个 token 一致）
//   --name        agent 名字（如 "内网-nas"）
//
// 可选 env/flag:
//   --xui-db        3x-ui sqlite 路径（默认 /etc/x-ui/x-ui.db，留空跳过 3xui section）
//   --interval      push 间隔（默认 5s，跟 app poll 周期对齐）
//   --no-tls-verify 跳过 cert 校验（**不推荐**，仅调试用）

package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/mzhscan/monitor-status/pkg/collector"
)

// ===== Config =====

var cfg struct {
	RelayURL     string
	RelayToken   string
	AgentName    string
	XUIDBPath    string
	PushInterval time.Duration
	NoTLSVerify  bool
}

func main() {
	flag.StringVar(&cfg.RelayURL, "relay-url", getenv("RELAY_URL", ""), "relay URL (如 https://doogeee.cn:9100)")
	flag.StringVar(&cfg.RelayToken, "token", getenv("RELAY_TOKEN", ""), "X-Relay-Token 值")
	flag.StringVar(&cfg.AgentName, "name", getenv("AGENT_NAME", ""), "agent 显示名")
	flag.StringVar(&cfg.XUIDBPath, "xui-db", getenv("XUI_DB_PATH", "/etc/x-ui/x-ui.db"), "3x-ui sqlite 路径，留空跳过")
	flag.DurationVar(&cfg.PushInterval, "interval", 5*time.Second, "push 间隔")
	flag.BoolVar(&cfg.NoTLSVerify, "no-tls-verify", false, "跳过 cert 校验（仅调试）")
	flag.Parse()

	if cfg.RelayURL == "" || cfg.RelayToken == "" || cfg.AgentName == "" {
		log.Fatal("❌ 必须提供 --relay-url / --token / --name（也可走 env）")
	}
	if cfg.AgentName == "" {
		cfg.AgentName = "reverse-agent"
	}

	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Printf("🚀 星黎监控 reverse-agent [%s] 启动", cfg.AgentName)
	log.Printf("📡 推送目标: %s (interval=%s)", cfg.RelayURL, cfg.PushInterval)

	client := newHTTPClient()

	// 启动时先 ping 一下 relay /health
	if err := pingRelay(client); err != nil {
		log.Printf("⚠️  relay 不可达: %v (启动后继续 push 尝试)", err)
	} else {
		log.Printf("✅ relay /health ok")
	}

	// 立即 push 一次（warmup，让 app 一连就能拉到数据）
	backoff := time.Second
	for {
		if err := pushOnce(client); err == nil {
			backoff = time.Second
			break
		} else {
			log.Printf("⚠️  首次 push 失败: %v (%.0fs 后重试)", err, backoff.Seconds())
			time.Sleep(backoff)
			backoff = nextBackoff(backoff)
		}
	}

	// 周期 push
	t := time.NewTicker(cfg.PushInterval)
	defer t.Stop()
	for range t.C {
		if err := pushOnce(client); err != nil {
			log.Printf("⚠️  push 失败: %v", err)
		}
	}
}

func newHTTPClient() *http.Client {
	tr := &http.Transport{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: cfg.NoTLSVerify, // 默认严格校验，--no-tls-verify 才跳过
			MinVersion:         tls.VersionTLS12,
		},
	}
	return &http.Client{
		Timeout:   15 * time.Second,
		Transport: tr,
	}
}

func pingRelay(client *http.Client) error {
	resp, err := client.Get(cfg.RelayURL + "/health")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}

func pushOnce(client *http.Client) error {
	// 复用现有 collector，跟 cmd/agent 100% 同样的 Report struct
	rpt := collector.Collect(cfg.AgentName, cfg.XUIDBPath)
	body, err := json.Marshal(rpt)
	if err != nil {
		return fmt.Errorf("encode: %w", err)
	}

	req, err := http.NewRequest(http.MethodPost, cfg.RelayURL+"/ingest", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("X-Relay-Token", cfg.RelayToken)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "monitor-status reverse-agent/"+cfg.AgentName)

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
	if resp.StatusCode != 200 {
		return fmt.Errorf("status %d: %s", resp.StatusCode, string(respBody))
	}
	log.Printf("✅ push ok (%d bytes, clients=%d)", len(body), clientCount(rpt))
	return nil
}

func nextBackoff(cur time.Duration) time.Duration {
	next := cur * 2
	if next > 30*time.Second {
		return 30 * time.Second
	}
	return next
}

func clientCount(rpt *collector.Report) int {
	if rpt.XUI == nil {
		return 0
	}
	clients, _ := rpt.XUI["clients"].([]map[string]interface{})
	return len(clients)
}

// 防止 import 未使用警告（x509 在某些 build tag 下被链入）
var _ = x509.NewCertPool

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
