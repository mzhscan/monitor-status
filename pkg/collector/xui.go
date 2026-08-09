package collector

import (
	"database/sql"
	"fmt"
	"io/ioutil"
	"os"
	"time"

	_ "modernc.org/sqlite"
)

// 3xui's `last_online` is the timestamp of the most recent connection from
// the client. A client whose last connection was >5min ago is effectively
// "offline" for the dashboard, even if the row in the DB is still
// enable=1. This matches what most users expect when they look at
// "online count".
const onlineThresholdMs = 5 * 60 * 1000 // 5 minutes

type XUIData struct {
	Clients      []map[string]interface{} `json:"clients"`
	Inbounds     []map[string]interface{} `json:"inbounds,omitempty"`
	// v2.4.20: 3x-ui 写 client_traffics 频率太低（client 断开时才写一次），
	// online 期间数字不增加。inbounds.up/down 是 xray 实时更新，秒级刷新，
	// 加这个字段让 app 端能展示"vps 主机总流量（实时）"，跟陈旧的 per-client
	// 数据分开。online 时 per-client 数字会卡住，但总流量一直在涨 → user
	// 一眼就知道是 3x-ui 写入延迟，不是 agent 缓存问题。
	InboundTotal map[string]interface{} `json:"inbound_total,omitempty"`
	OnlineCount  int                      `json:"online_count"`
	TotalClients int                      `json:"total_clients"`
	TotalUpMB    float64                  `json:"total_up_mb"`
	TotalDownMB  float64                  `json:"total_down_mb"`
	// v2.4.20: agent 采集时间戳（unix seconds），app 端显示"数据于 X 采集"，
	// 让 user 知道这组数据是几分钟前 3x-ui 写进去的。
	ObservedAt int64 `json:"observed_at"`
}

// CollectXUI 从 x-ui SQLite 读取客户端和入口流量
func CollectXUI(dbPath string) (map[string]interface{}, error) {
	if !FileExists(dbPath) {
		return nil, fmt.Errorf("x-ui 数据库不存在: %s", dbPath)
	}

	// 拷贝数据库避免锁
	tmpDB := fmt.Sprintf("/tmp/xui-collect-%d.db", time.Now().UnixNano())
	defer os.Remove(tmpDB)

	data, err := ioutil.ReadFile(dbPath)
	if err != nil {
		return nil, err
	}
	if err := ioutil.WriteFile(tmpDB, data, 0644); err != nil {
		return nil, err
	}

	db, err := sql.Open("sqlite", "file:"+tmpDB+"?mode=ro&immutable=1")
	if err != nil {
		return nil, err
	}
	defer db.Close()

	result := XUIData{}

	// 客户端明细（从 client_traffics 表读，关联字段是 email）
	rows, err := db.Query(`SELECT email, enable, up, down, last_online FROM client_traffics`)
	if err != nil {
		return nil, fmt.Errorf("读 client_traffics 失败: %w", err)
	}
	for rows.Next() {
		var email string
		var enable, lastOnline int
		var up, down int64
		if err := rows.Scan(&email, &enable, &up, &down, &lastOnline); err != nil {
			continue
		}
		// "Online" = enabled AND last connection within onlineThresholdMs.
		// The old code only checked `lastOnline > 0`, which counted every
		// ever-connected client as online, leading to a misleading 6/6
		// when only some were actively connected.
		nowMs := time.Now().UnixMilli()
		isOnline := enable == 1 && lastOnline > 0 && (nowMs-int64(lastOnline)) < onlineThresholdMs
		if isOnline {
			result.OnlineCount++
		}
		result.TotalUpMB += float64(up) / 1024 / 1024
		result.TotalDownMB += float64(down) / 1024 / 1024

		// Record this snapshot for the 72h traffic history and ask
		// the tracker for the 72h deltas. If we don't have any
		// history yet (cold start), the call returns ok=false and we
		// simply omit the fields — the app will render "—".
		RecordTraffic(email, up, down)
		up72, down72, has72h := Traffic72hBytes(email, up, down)

		clientMap := map[string]interface{}{
			"email":       email,
			"online":      isOnline,
			"enable":      enable == 1,
			"up_bytes":    up,
			"down_bytes":  down,
			"up_mb":       round2(float64(up) / 1024 / 1024),
			"down_mb":     round2(float64(down) / 1024 / 1024),
			"up_gb":       round2(float64(up) / 1024 / 1024 / 1024),
			"down_gb":     round2(float64(down) / 1024 / 1024 / 1024),
			"last_online": lastOnline,
		}
		if has72h {
			clientMap["up_72h_bytes"] = up72
			clientMap["down_72h_bytes"] = down72
		}
		result.Clients = append(result.Clients, clientMap)
	}
	rows.Close()
	result.TotalClients = len(result.Clients)
	result.TotalUpMB = round2(result.TotalUpMB)
	result.TotalDownMB = round2(result.TotalDownMB)

	// 入口汇总 + 实时总流量（v2.4.20：inbounds.up/down 是 xray 实时更新）
	inboundRows, err := db.Query(`SELECT remark, port, enable, up, down FROM inbounds`)
	var totalInboundUp, totalInboundDown int64
	if err == nil {
		for inboundRows.Next() {
			var remark string
			var port, enable int
			var up, down int64
			if err := inboundRows.Scan(&remark, &port, &enable, &up, &down); err != nil {
				continue
			}
			result.Inbounds = append(result.Inbounds, map[string]interface{}{
				"remark":     remark,
				"port":       port,
				"enable":     enable == 1,
				"up_bytes":   up,
				"down_bytes": down,
				"up_mb":      round2(float64(up) / 1024 / 1024),
				"down_mb":    round2(float64(down) / 1024 / 1024),
				"up_gb":      round2(float64(up) / 1024 / 1024 / 1024),
				"down_gb":    round2(float64(down) / 1024 / 1024 / 1024),
			})
			if enable == 1 {
				totalInboundUp += up
				totalInboundDown += down
			}
		}
		inboundRows.Close()
	}
	// 累加所有 enabled inbound 的实时流量 → app 端作为"vps 主机总流量（实时）"
	if len(result.Inbounds) > 0 {
		result.InboundTotal = map[string]interface{}{
			"up_bytes":   totalInboundUp,
			"down_bytes": totalInboundDown,
			"up_gb":      round2(float64(totalInboundUp) / 1024 / 1024 / 1024),
			"down_gb":    round2(float64(totalInboundDown) / 1024 / 1024 / 1024),
			"inbounds_count": len(result.Inbounds),
		}
	}
	// agent 采集时间戳
	result.ObservedAt = time.Now().Unix()

	return map[string]interface{}{
		"clients":       result.Clients,
		"inbounds":      result.Inbounds,
		"inbound_total": result.InboundTotal,
		"online_count":  result.OnlineCount,
		"total_clients": result.TotalClients,
		"total_up_mb":   result.TotalUpMB,
		"total_down_mb": result.TotalDownMB,
		"total_up_gb":   round2(result.TotalUpMB / 1024),
		"total_down_gb": round2(result.TotalDownMB / 1024),
		"observed_at":   result.ObservedAt,
	}, nil
}

// CollectServices 检查 systemd 服务状态
func CollectServices(serviceNames []string) []map[string]interface{} {
	services := []map[string]interface{}{}
	for _, name := range serviceNames {
		out, _ := runCmd("systemctl", "is-active", name)
		status := out
		if status == "" {
			status = "unknown"
		}
		services = append(services, map[string]interface{}{
			"name":   name,
			"status": status,
		})
	}
	return services
}