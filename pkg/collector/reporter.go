package collector

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type Report struct {
	AgentName string                 `json:"agent_name"`
	Timestamp int64                  `json:"timestamp"`
	Hardware  map[string]interface{} `json:"hardware"`
	XUI       map[string]interface{} `json:"xui,omitempty"`
	Services  []map[string]interface{} `json:"services,omitempty"`
}

type Reporter struct {
	BackendURL string
	Token      string
	AgentName  string
	Client     *http.Client
}

// NewReporter 创建上报器（接受自签证书，agent 端默认启 HTTPS）
func NewReporter(backendURL, token, agentName string) *Reporter {
	return &Reporter{
		BackendURL: backendURL,
		Token:      token,
		AgentName:  agentName,
		Client: &http.Client{
			Timeout: 10 * time.Second,
			Transport: &http.Transport{
				TLSClientConfig:   &tls.Config{InsecureSkipVerify: true},
				DisableKeepAlives: false,
			},
		},
	}
}

// Send 发送一次数据
func (r *Reporter) Send(report *Report) error {
	if report.AgentName == "" {
		report.AgentName = r.AgentName
	}
	if report.Timestamp == 0 {
		report.Timestamp = time.Now().Unix()
	}

	data, _ := json.Marshal(report)
	req, err := http.NewRequestWithContext(context.Background(), "POST", r.BackendURL, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Agent-Token", r.Token)
	req.Header.Set("X-Agent-Name", r.AgentName)

	resp, err := r.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}