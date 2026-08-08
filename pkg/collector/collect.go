// Top-level Collect() glues together the per-subsystem collectors and
// returns a *Report the agent can ship to the backend.

package collector

import "time"

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
		if xui, err := CollectXUI(xuiDBPath); err == nil {
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
