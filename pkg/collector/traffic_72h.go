// Package collector — rolling 72-hour traffic tracking for 3xui clients.
//
// 3xui's SQLite only stores cumulative up/down bytes per client (no per-day
// history). To give the app a "last 72h" column, we snapshot the cumulative
// value on every poll, and serve the difference between the current value
// and the snapshot taken closest to (now - 72h). State is persisted to a
// JSON file so it survives agent restarts.
//
// The file path defaults to /opt/server-monitor/data/traffic_72h.json but
// can be overridden via the Traffic72hFile variable (the agent may set it
// from an env var on startup).
package collector

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Traffic72hFile is the on-disk location of the 72h history. Overridable.
var Traffic72hFile = "/opt/server-monitor/data/traffic_72h.json"

type trafficSnapshot struct {
	Timestamp int64 `json:"ts"` // unix ms
	Up        int64 `json:"up"` // cumulative up bytes at that moment
	Down      int64 `json:"dn"` // cumulative down bytes at that moment
}

var (
	trafficMu sync.RWMutex
	traffic   = map[string][]trafficSnapshot{} // email -> history (oldest first)
)

// LoadTraffic72h reads the persisted history. Call once on agent startup.
// Silently ignores "file not found" — fresh agent will start with empty
// history (first 72h will show 0 / "—").
func LoadTraffic72h() error {
	data, err := os.ReadFile(Traffic72hFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var m map[string][]trafficSnapshot
	if err := json.Unmarshal(data, &m); err != nil {
		return err
	}
	trafficMu.Lock()
	traffic = m
	trafficMu.Unlock()
	log.Printf("📦 72h traffic: loaded %d client histories from %s", len(m), Traffic72hFile)
	return nil
}

// SaveTraffic72h writes the current history to disk. Safe to call
// concurrently; the agent should call it on shutdown and periodically
// (e.g. every minute) to bound data loss.
func SaveTraffic72h() error {
	trafficMu.RLock()
	data, err := json.MarshalIndent(traffic, "", "  ")
	trafficMu.RUnlock()
	if err != nil {
		return err
	}
	if dir := filepath.Dir(Traffic72hFile); dir != "" {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return err
		}
	}
	return os.WriteFile(Traffic72hFile, data, 0644)
}

// RecordTraffic appends the current cumulative up/down to the history
// for this client and trims anything older than 73h (small buffer past 72h
// so we still have a comparison point at exactly 72h ago).
func RecordTraffic(email string, up, down int64) {
	if email == "" {
		return
	}
	now := time.Now().UnixMilli()
	cutoff := now - 73*60*60*1000

	trafficMu.Lock()
	hist := traffic[email]
	hist = append(hist, trafficSnapshot{Timestamp: now, Up: up, Down: down})
	for len(hist) > 0 && hist[0].Timestamp < cutoff {
		hist = hist[1:]
	}
	traffic[email] = hist
	trafficMu.Unlock()
}

// Traffic72hBytes returns the up/down bytes used in roughly the last 72
// hours. If we have history older than 72h, it's current minus the
// snapshot taken closest to 72h ago. If the oldest snapshot we have is
// newer than 72h (cold start), we still return current - oldest so the
// app shows *something* during the warm-up period — it'll just be a
// shorter window than 72h. The frontend may also fall back to "—".
func Traffic72hBytes(email string, currentUp, currentDown int64) (up72, down72 int64, ok bool) {
	trafficMu.RLock()
	hist := traffic[email]
	trafficMu.RUnlock()
	if len(hist) == 0 {
		return 0, 0, false
	}
	// Defensive: keep history sorted by timestamp.
	if !sort.SliceIsSorted(hist, func(i, j int) bool { return hist[i].Timestamp < hist[j].Timestamp }) {
		sort.Slice(hist, func(i, j int) bool { return hist[i].Timestamp < hist[j].Timestamp })
	}
	now := time.Now().UnixMilli()
	target := now - 72*60*60*1000
	var baseline *trafficSnapshot
	for i := range hist {
		if hist[i].Timestamp <= target {
			baseline = &hist[i]
		} else {
			break
		}
	}
	if baseline == nil {
		// Cold start — no snapshot is old enough. Use the oldest.
		baseline = &hist[0]
	}
	up72 = currentUp - baseline.Up
	down72 = currentDown - baseline.Down
	if up72 < 0 {
		up72 = 0
	}
	if down72 < 0 {
		down72 = 0
	}
	return up72, down72, true
}
