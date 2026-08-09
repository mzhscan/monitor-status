# 星黎监控 relay + reverse-agent（v2.4.24+）

让**没有公网 IP 的内网机器**也能被现有 app 监控。**app 端零改动**。

## 它是什么

两个新组件，跟现有 agent / app 互不影响：

| 组件 | 装在哪 | 干什么 | 是否需要公网 IP |
|---|---|---|---|
| **relay-server** | 有公网的服务器（如 mzhhua.cn / usvps） | 接收内网机器 push，给 app 提供拉数据接口 | ✅ 是 |
| **reverse-agent** | 没公网 IP 的内网机器 | 复用 collector，每 5 秒主动把数据推给 relay | ❌ 否 |

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
   │  relay-server (公网，如 usvps)         │
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

---

# 一、准备工作

部署前需要确定 3 件事：

| 项目 | 说明 | 例子 |
|---|---|---|
| **公网服务器** | 有公网 IP / 域名，能跑 systemd 服务 | usvps.mzhhua.cn（22.141.204.236） |
| **relay 端口** | relay-server 监听的端口 | 9200（避开现有 9009/9101） |
| **token 列表** | 每台内网机器一个 token，逗号分隔 | `tok-nas-1,tok-nas-2,tok-nas-3` |

**token 怎么生成？** 至少 16 位随机字符串。Linux 上：

```bash
openssl rand -hex 16
# 输出: 3f2e8a1b9c4d5e6f7a8b9c0d1e2f3a4b
```

每台机器一个。或者用密码管理器生成。

---

# 二、服务端部署（relay-server）

> 装在**有公网 IP 的服务器**上（这里以 usvps.mzhhua.cn:9200 为例）

SSH 到公网服务器后跑：

```bash
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-relay.sh | \
  sudo bash -s -- --version latest \
    --port 9200 \
    --tokens "tok-nas-1,tok-nas-2,tok-nas-3" \
    --external-host usvps.mzhhua.cn
```

**参数说明**：

| 参数 | 必填 | 说明 |
|---|---|---|
| `--version` | ✅ | `latest` 或 `v2.4.24` 等具体版本 |
| `--port` | | 监听端口（默认 9100），建议 9200 避开 agent 端口 |
| `--tokens` | ✅ | token 白名单，逗号分隔 |
| `--external-host` | 强烈建议 | cert SAN 域名，**不传会 hostname mismatch** |
| `--external-ip` | 可选 | 如果公网服务器没域名只有 IP，传这个 |
| `--binary` | 可选 | 本地已下载的 binary（墙内用） |

**装完输出**会显示 token 列表、env 文件位置、systemd 状态，**保存好 token 列表**。

防火墙放行端口：

```bash
# Ubuntu/Debian
sudo ufw allow from any to any port 9200 proto tcp

# 如果是 firewalld
sudo firewall-cmd --permanent --add-port=9200/tcp
sudo firewall-cmd --reload

# 或者限制 IP 段（更安全）
sudo ufw allow from <reverse-agent 的 IP 段> to any port 9200 proto tcp
```

**验证**：

```bash
curl -sk https://usvps.mzhhua.cn:9200/health
# → {"status":"ok","active_servers":0,"active_recent":0,"uptime_sec":N}
```

---

# 三、客户端部署（reverse-agent）

> 装在**没公网 IP 的内网机器**上（家里 NAS、树莓派、公司内网 server 等）

每台内网机器跑一次（用服务端 token 列表里的**一个** token）：

```bash
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh | \
  sudo bash -s -- --version latest \
    --relay-url https://usvps.mzhhua.cn:9200 \
    --token "tok-nas-1" \
    --name "内网-nas-1"
```

**参数说明**：

| 参数 | 必填 | 说明 |
|---|---|---|
| `--version` | ✅ | `latest` 或 `v2.4.24` |
| `--relay-url` | ✅ | relay 的 URL（**带 https:// 前缀和端口**） |
| `--token` | ✅ | 服务端 token 列表里的某一个，每台机器不同 |
| `--name` | ✅ | app 端显示名 |
| `--xui-db` | 可选 | 3x-ui sqlite 路径（默认 `/etc/x-ui/x-ui.db`，不跑 3x-ui 不用管） |
| `--interval` | 可选 | push 间隔秒数（默认 5s） |
| `--binary` | 可选 | 本地已下载的 binary |

**装完会自动启动**。看日志：

```bash
journalctl -u server-monitor-reverse-agent -f
# 应该看到：
# 🚀 星黎监控 reverse-agent [内网-nas-1] 启动
# 📡 推送目标: https://usvps.mzhhua.cn:9200 (interval=5s)
# ✅ relay /health ok
# ✅ push ok (xxxx bytes, clients=N)
```

**多台内网机器**：每台跑一次上面的命令，`--token` 和 `--name` 换成不同的。

---

# 四、app 端配置

打开 Flutter app → 右上角 "+" → 填：

| 字段 | 填 | 例子 |
|---|---|---|
| 名称 | 跟 reverse-agent 的 `--name` 一致 | `内网-nas-1` |
| 地址（URL） | relay 的 URL（**不是** reverse-agent 的） | `https://usvps.mzhhua.cn:9200` |
| Token | 跟 reverse-agent 的 `--token` 一致 | `tok-nas-1` |

保存。app 立刻拉一次，正常的话 5 秒后开始稳定轮询。

**多台内网机器**：

| reverse-agent `--name` | reverse-agent `--token` | app 端 token |
|---|---|---|
| `内网-nas-1` | `tok-nas-1` | `tok-nas-1` |
| `内网-pi` | `tok-pi` | `tok-pi` |
| `内网-rout` | `tok-rout` | `tok-rout` |

每台机器在 app 端是**独立 server 项**，URL 都填同一个 relay URL，只是 token 不同。

---

# 五、验证

部署完跑三个：

```bash
# 1. relay 状态（active_servers 应该等于你装的 reverse-agent 数量）
curl -sk https://usvps.mzhhua.cn:9200/health

# 2. 用 app 那个 token 直接 curl relay（看能不能拉到数据）
curl -sk -H "X-Agent-Token: tok-nas-1" https://usvps.mzhhua.cn:9200/api/report | python3 -m json.tool | head -20

# 3. reverse-agent 日志（看 push 成功）
journalctl -u server-monitor-reverse-agent -n 20
```

第 1 步 `active_servers` 一直是 0 → reverse-agent 没 push 成功，看第 3 步。
第 2 步拉到完整 JSON → app 端配置没问题，等 5 秒内数据就到 app。

---

# 六、文件位置（装好后）

```
/opt/server-monitor/
├── bin/
│   ├── relay-server           # 服务端 binary
│   └── reverse-agent          # 客户端 binary
├── relay.env                  # 服务端配置 (chmod 600, root only)
├── reverse-agent.env          # 客户端配置 (chmod 600)
├── relay.crt / relay.key      # 服务端自签 cert
└── ...
/etc/systemd/system/
├── server-monitor-relay.service
└── server-monitor-reverse-agent.service
```

---

# 七、常见操作

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

---

# 八、升级

```bash
# 升级 relay（保持原来的 --port / --tokens / --external-host）
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-relay.sh | \
  sudo bash -s -- --version v2.4.25 \
    --port 9200 \
    --tokens "tok-nas-1,tok-nas-2" \
    --external-host usvps.mzhhua.cn

# 升级 reverse-agent
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh | \
  sudo bash -s -- --version v2.4.25 \
    --relay-url https://usvps.mzhhua.cn:9200 \
    --token "tok-nas-1" \
    --name "内网-nas-1"
```

env 文件不会被覆盖（脚本只覆盖 binary），重启服务即可。

---

# 九、故障排查

### 1. "数据未就绪，请稍后重试"

reverse-agent 还没 push 过，或 push 失败。先看 reverse-agent 日志：

```bash
journalctl -u server-monitor-reverse-agent -n 50
```

如果是 `relay 不可达`：检查网络、防火墙、`--relay-url` 是不是填错了（要带 `https://` 前缀和端口）。

### 2. "数据已过期（X 秒前更新）"

reverse-agent 在 push 但被 relay 判定为过期（默认 2 分钟没更新）。看 reverse-agent 日志是不是有连续报错。

### 3. app 端 "Hostname mismatch" 错误

relay 自签 cert 的 SAN 没包含 app 用的域名/IP。重新装 relay 加 `--external-host` / `--external-ip`：

```bash
sudo systemctl stop server-monitor-relay
sudo bash install-relay.sh --version v2.4.24 --port 9200 \
  --tokens "tok-nas-1,tok-nas-2" \
  --external-host usvps.mzhhua.cn
```

### 4. token 泄露 / 想换 token

```bash
# 1. 服务端换 token
sudo nano /opt/server-monitor/relay.env     # 改 RELAY_TOKENS=
sudo systemctl restart server-monitor-relay

# 2. 每台 reverse-agent 机器改 token
sudo nano /opt/server-monitor/reverse-agent.env
sudo systemctl restart server-monitor-reverse-agent

# 3. app 端用新 token 重新加服务器
```

### 5. reverse-agent 能 ping 通 relay 但 push 失败

多半是 token 拼错了或者被改过。检查：

```bash
# 服务端实际生效的 token
sudo cat /opt/server-monitor/relay.env | grep TOKENS

# 客户端推送用的 token
sudo cat /opt/server-monitor/reverse-agent.env | grep TOKEN
```

要严格一致。

---

# 十、设计取舍说明

- **为什么不做认证 + 注册流程？** —— 多一道复杂度，对个人项目过重。静态 token whitelist 已经够用，且每个 token 只对应一台机器，泄露了影响有限。
- **为什么不持久化数据？** —— relay 不是 source of truth。reverse-agent 永远有最新数据，relay 挂了数据丢点也无所谓。app 端的 v2.4.22 badge 会显示"离线"，用户会知道。
- **为什么不用 WebSocket / SSE？** —— app 端每 5 秒 poll 已经够用，HTTP POST/GET 简单可靠，不需要长连接。
- **为什么不直接用 mqtt / message queue？** —— 多一个依赖，多一个故障点。HTTP POST/GET 几十行 Go 就搞定。
