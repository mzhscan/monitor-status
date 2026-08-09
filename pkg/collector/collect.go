// Top-level Collect() glues together the per-subsystem collectors and
// returns a *Report the agent can ship to the backend.

package collector

import (
	"log"
	"time"
)

// Report is the JSON-serialised snapshot returned by /api/report. The
// fields mirror the Flutter client's AgentData model — keep them in sync
// when adding new sections.
type Report struct {
	AgentName string                   `json:"agent_name"`
	Timestamp int64                    `json:"timestamp"`
	Hardware  map[string]interface{}   `json:"hardware"`
	XUI       map[string]interface{}   `json:"xui,omitempty"`
	Services  []map[string]interface{} `json:"services,omitempty"`
}

// ServiceNames is the default list of systemd services we report on.
var ServiceNames = []string{
	"x-ui",
	"server-monitor-backend",
	"ssh",
	"nginx",
}

// Collect gathers one snapshot of hardware + xui + services for the given
// agent. xuiDBPath is the path to 3x-ui's SQLite file; pass "" to skip the
// 3xui section (e.g. on a non-VPS host that doesn't run 3x-ui).
func Collect(agentName, xuiDBPath string) *Report {
	r := &Report{
		AgentName: agentName,
		Timestamp: time.Now().Unix(),
		Hardware:  CollectHardware(),
	}

	if xuiDBPath != "" && FileExists(xuiDBPath) {
		xui, err := CollectXUI(xuiDBPath)
		if err != nil {
			// 之前 err 被静默吞掉，app 端只看到 "没 xui 字段" 不知道为啥。
			// 现在把错误塞到 xui._error，app 详情页能直接看到具体原因。
			log.Printf("⚠️  xui 采集失败: %v", err)
			r.XUI = map[string]interface{}{
				"_error": err.Error(),
			}
		} else {
			if clients, ok := xui["clients"].([]map[string]interface{}); ok {
				for _, c := range clients {
					email, _ := c["email"].(string)
					up := toInt64(c["up_bytes"])
					dn := toInt64(c["down_bytes"])
					if email != "" {
						RecordTraffic(email, up, dn)
					}
				}
			}
			r.XUI = xui
		}
	}

	r.Services = CollectServices(ServiceNames)
	return r
}

func toInt64(v interface{}) int64 {
	switch x := v.(type) {
	case int64:
		return x
	case int:
		return int64(x)
	case float64:
		return int64(x)
	}
	return 0
}
