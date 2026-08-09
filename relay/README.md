# 星黎监控 relay + reverse-agent（v2.4.24+）

让**没有公网 IP 的内网机器**也能被现有 app 监控。**app 端零改动**。

## 架构

```
[内网机器 A]                    [内网机器 B]
   reverse-agent                  reverse-agent
   (collect + POST)              (collect + POST)
        │                              │
        │  POST /ingest                │  POST /ingest
        │  X-Relay-Token: tokA         │  X-Relay-Token: tokB
        ▼                              ▼
   ┌────────────────────────────────────────┐
   │  relay-server (公网，如 doogeee.cn)    │
   │  内存: tokA → ReportA                  │
   │         tokB → ReportB                  │
   └────────────────────────────────────────┘
        ▲                              ▲
        │ GET /api/report              │ GET /api/report
        │ X-Agent-Token: tokA          │ X-Agent-Token: tokB
        │                              │
   [Flutter app] ──────────────────────┘
   (现有 app 零改动)
```

## 关键设计

- **复用 `pkg/collector`** —— reverse-agent 直接调用 `collector.Collect()`，跟现有 `cmd/agent` 100% 同代码、同数据格式。app 端 `AgentData.fromJson` 不需要任何改动。
- **token 一一对应** —— relay 启动时配一个 token 白名单，每个 token 对应一台内网机器。reverse-agent push 用 tokenA，app poll 也用 tokenA，relay 看 token 路由到对应数据。
- **纯内存** —— 无持久化。relay 重启 = 数据清空，reverse-agent 重新 push 一次就恢复。这是"中转"的设计，不是"中央存储"。
- **断联行为** —— reverse-agent 推不上数据超过 2 分钟，relay 返回 503；app 端 `lastSuccessMs` 不更新 → v2.4.22 badge 显示"卡 Xs/离线"。

## 部署步骤

### Step 1: 在公网服务器装 relay（以 doogeee.cn:9100 为例）

```bash
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-relay.sh | \
  sudo bash -s -- --version latest \
    --port 9100 \
    --tokens "tokA,tokB,tokC" \
    --external-host doogeee.cn
```

- `--tokens`：逗号分隔，**每台内网机器一个 token**。token 至少 16 位随机字符串。
- `--external-host`：relay 自签 cert 的 SAN 域名，**强烈建议传**，否则 app 端会报 hostname mismatch。
- 防火墙放行 9100/TCP。

如果公网服务器有 IP 没域名（比如裸 VPS），传 `--external-ip 1.2.3.4`。

### Step 2: 在内网机器装 reverse-agent

```bash
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh | \
  sudo bash -s -- --version latest \
    --relay-url https://doogeee.cn:9100 \
    --token "tokA" \
    --name "内网-nas"
```

- `--relay-url`：跟 Step 1 的 `--port` 拼起来。
- `--token`：从 Step 1 的 `--tokens` 里挑一个，每台机器用不同的。
- `--name`：app 端显示的名字。
- 如果内网机器跑 3x-ui，加 `--xui-db /etc/x-ui/x-ui.db`（默认就是这个）。

### Step 3: app 端加服务器

在 Flutter app 里点 "+" → 填：

| 字段 | 值 |
|---|---|
| name | 内网-nas（跟 Step 2 的 `--name` 一致即可） |
| url | `https://doogeee.cn:9100`（**跟 Step 1 的 relay URL 一致**） |
| token | `tokA`（**跟 Step 2 的 `--token` 一致**） |

保存即可。app 每 5 秒会调一次 `GET /api/report` 带 `X-Agent-Token: tokA`，relay 返回 tokenA 对应内网机器的最新数据。

## 防火墙

relay 的 9100 端口要开放：

- ✅ 从内网 reverse-agent 的出站 IP 段（如果固定）
- ✅ 从手机 app 用的网络（如果手机是移动网，可能需要全开放或白名单）
- ❌ 不需要给全网开 —— 但**最稳是限制 IP 段**。可以用 `ufw allow from <ip> to any port 9100 proto tcp`

## 多台内网机器

只需要在 Step 1 的 `--tokens` 里多列几个 token（逗号分隔），然后每台机器 Step 2 用一个。

最多支持多少？理论无限（内存 map），但**单 relay 进程**扛并发量有限（GO HTTPS server 默认能跑几 K QPS 没问题，几百台内网机器 + 几十个 app 用户足够）。

## 文件位置（装好后）

```
/opt/server-monitor/
├── bin/
│   ├── relay-server
│   └── reverse-agent
├── relay.env                  # relay 配置 (chmod 600, root only)
├── reverse-agent.env          # reverse-agent 配置 (chmod 600)
├── relay.crt / relay.key      # relay 自签 cert
└── ...
/etc/systemd/system/
├── server-monitor-relay.service
└── server-monitor-reverse-agent.service
```

## 常见操作

```bash
# 看 relay 日志
journalctl -u server-monitor-relay -f

# 看 reverse-agent 日志
journalctl -u server-monitor-reverse-agent -f

# 重启
sudo systemctl restart server-monitor-relay
sudo systemctl restart server-monitor-reverse-agent

# 改 token / 端口：编辑 env 后 restart
sudo nano /opt/server-monitor/relay.env
sudo systemctl restart server-monitor-relay
```

## 升级

```bash
# 升级 relay
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-relay.sh | \
  sudo bash -s -- --version v2.4.25   # 跟之前一样的 --tokens / --port / --external-host

# 升级 reverse-agent
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh | \
  sudo bash -s -- --version v2.4.25   # 跟之前一样的 --relay-url / --token / --name
```

env 文件不会被覆盖（脚本只覆盖 binary），重启服务即可。

## 故障排查

### 1. "数据未就绪，请稍后重试"

reverse-agent 还没 push 过，或 push 失败。先看 reverse-agent 日志：

```bash
journalctl -u server-monitor-reverse-agent -n 50
```

如果是 `relay 不可达`：检查网络、防火墙、`--relay-url` 是不是填错了（要带 `https://` 前缀）。

### 2. "数据已过期（X 秒前更新）"

reverse-agent 在 push 但被 relay 判定为过期（默认 2 分钟没更新）。看 reverse-agent 日志是不是有连续报错。

### 3. app 端 "Hostname mismatch" 错误

relay 自签 cert 的 SAN 没包含 app 用的域名/IP。重新装 relay 加 `--external-host` / `--external-ip`：

```bash
sudo systemctl stop server-monitor-relay
sudo bash install-relay.sh --version v2.4.24 --tokens "..." --external-host doogeee.cn ...
```

### 4. token 泄露 / 想换 token

```bash
sudo nano /opt/server-monitor/relay.env     # 改 RELAY_TOKENS=
sudo systemctl restart server-monitor-relay
# 然后去每台 reverse-agent 机器改 reverse-agent.env
# 最后 app 端用新 token 重新加服务器
```

## 设计取舍说明

- **为什么不做认证 + 注册流程？** —— 多一道复杂度，对个人项目过重。静态 token whitelist 已经够用，且每个 token 只对应一台机器，泄露了影响有限。
- **为什么不持久化数据？** —— relay 不是 source of truth。reverse-agent 永远有最新数据，relay 挂了数据丢点也无所谓。app 端的 v2.4.22 badge 会显示"离线"，用户会知道。
- **为什么不用 WebSocket / SSE？** —— app 端每 5 秒 poll 已经够用，HTTP POST/GET 简单可靠，不需要长连接。
