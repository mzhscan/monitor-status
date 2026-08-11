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

**一键安装（脚本会一步步问你，跟着填就行）**：

```bash
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-relay.sh | sudo bash
```

跑起来后大概长这样：

```
╔════════════════════════════════════════════╗
║   星黎监控 relay 安装向导                  ║
╚════════════════════════════════════════════╝

🔍 本机公网 IP: 22.141.204.236（自动探测的）

版本（latest = 最新版 / 或填具体如 v2.4.24） [latest]: <回车>
监听端口（避开 9009/9101 等已有端口，9200 推荐） [9200]: <回车或填 19200>

🔑 token 配置：每台内网 reverse-agent 一个独立 token
   选 1：脚本自动生成 N 个（推荐）
   选 2：自己粘贴（逗号分隔）
选择 [1]: 1
要监控几台内网机器？ [1]: 2
🔐 正在生成 2 个 token...
   自动生成的 token（**保存好**）:
     1. a1b2c3d4e5f6...
     2. f6e5d4c3b2a1...
这些 token 你保存了吗？ [Y/n]: y

📜 cert SAN 域名 / IP（app 连 relay 时用，要让 cert 验证通过）
域名（多个用逗号，留空跳过）: usvps.mzhhua.cn

🔥 防火墙（自动放行 9200/tcp）
   检测到: ufw
是否自动放行 9200/tcp？ [Y/n]: y

🌐 公网 agent 代理（v2.4.26+ 网页版用）
   格式: name|url|token（多条用 , 分隔）
   留空跳过：网页版只展示内网 reverse-agent 推的机器
公网 agent 列表（留空跳过）: mzhhua|https://mzhhua.cn:9009/api/report|xxx,doogeee|https://doogeee.cn:9009/api/report|yyy

📦 安装预览：
   版本:     v2.4.26
   端口:     9200
   token:    2 个
   cert SAN: host=usvps.mzhhua.cn ip=
   公网代理: 2 个公网 agent（v2.4.26+ 网页版用）
   二进制:   /opt/server-monitor/relay-server
   env:      /opt/server-monitor/relay.env
确认安装？ [Y/n]: y
✅ relay 启动成功
```

**脚本会引导你填**：
- 版本（默认 latest）
- 监听端口（默认 9200）
- token 数量（自动生成 N 个 32 字符随机 token，**每个内网机器一个**）
- 公网域名 / IP（cert SAN）
- 是否自动放行防火墙
- **公网 agent 代理列表**（v2.4.26+，让网页版看到公网机器的 3xui 趋势图）

**装完输出**会显示 token 列表、env 文件位置、systemd 状态、网页版 URL，**保存好 token 列表**。

**公网 agent 格式说明**：`name|url|token`，例：
```
mzhhua|https://mzhhua.cn:9009/api/report|<mzhhua 的 AGENT_TOKEN>
doogeee|https://doogeee.cn:9009/api/report|<doogeee 的 AGENT_TOKEN>
usvps|https://usvps.mzhhua.cn:9009/api/report|<usvps 的 AGENT_TOKEN>
```
（每行一条，或者一行用 `,` 分隔都行。token 跟 Android app 配的是同一个）

**装完**：打开 https://usvps.mzhhua.cn:9200/web/ 看 dashboard（PC / 平板 / 手机自适应）。

详细网页版说明：[主 README → 网页版](../README.md#网页版v2426)

防火墙如果脚本没自动放（比如检测不到 ufw/firewalld），手动：

```bash
# Ubuntu/Debian
sudo ufw allow from any to any port 9200 proto tcp

# firewalld
sudo firewall-cmd --permanent --add-port=9200/tcp
sudo firewall-cmd --reload
```

**验证**：

```bash
curl -sk https://usvps.mzhhua.cn:9200/health
# → {"status":"ok","active_servers":0,"active_recent":0,"uptime_sec":N}
```

---

# 二.5、已装好之后再加 token（新增内网机器）

装好 relay 后，要加新的内网机器，**不要重装**（会重置 cert / 内存里已经 push 的数据 / app 端 cert trust）。用 `--add-token`：

```bash
# 一行加 1 个 / N 个（逗号分隔）
sudo bash install-relay.sh --add-token "tok-new-1,tok-new-2,tok-new-3"

# 也可多次跑（追加 + 自动去重）
sudo bash install-relay.sh --add-token "tok-new-4"
sudo bash install-relay.sh --add-token "tok-new-1"   # 已存在，自动跳过
```

**会做什么**：
- 读 `/opt/server-monitor/relay.env` 里的现有 `RELAY_TOKENS=`
- 拼上新的 → 去重 → 写回 env
- `systemctl restart server-monitor-relay` 重新加载白名单

**不会做什么**：
- ❌ 不重新下载 binary
- ❌ 不重新生成 cert（app 端 cert trust 不变）
- ❌ 不动 systemd unit
- ❌ 不清内存里已经 push 的数据

**不知道用什么 token 字符串**？用 `openssl rand -hex 16` 生成 32 字符随机：

```bash
# 一行生成 N 个 token + 一次 add
TOKENS=""
for i in 1 2 3 4 5; do
  T=$(openssl rand -hex 16)
  TOKENS="${TOKENS:+$TOKENS,}$T"
  echo "  tok-$i: $T"      # 打印出来你抄到内网机器
done
echo "----- 上面是要加到 relay 的 5 个 token，每个内网机器用一个 -----"
sudo bash install-relay.sh --add-token "$TOKENS"
```

**想删某台内网机器的 token**（如下线了）：手动改 env：

```bash
sudo nano /opt/server-monitor/relay.env     # 改 RELAY_TOKENS=
sudo systemctl restart server-monitor-relay
```

⚠️ **重要：每个内网机器必须用独立 token**。一个 token 被多台机器共用会出现"数据在机器间跳变"（因为 relay 内存里同一个 token 只存一份最新数据，后 push 的覆盖前 push 的）。详见 [# 十一、设计取舍说明](#十一设计取舍说明) 的"为什么不做 1 token → N 机器"。

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
# v2.4.25+: 日志不在 journal，在自己的文件里
tail -f /var/log/server-monitor/reverse-agent.log
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
tail -n 20 /var/log/server-monitor/reverse-agent.log
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
# 看 relay 日志（v2.4.25+: 不在 journal，在自己的文件里）
tail -f /var/log/server-monitor/relay.log

# 看 reverse-agent 日志
tail -f /var/log/server-monitor/reverse-agent.log

# 重启
sudo systemctl restart server-monitor-relay
sudo systemctl restart server-monitor-reverse-agent

# 改 token / 端口 / 公网代理：编辑 env 后 restart
sudo nano /opt/server-monitor/relay.env
sudo systemctl restart server-monitor-relay

# 网页版 API 自测
curl -sk https://localhost:9200/web/api/agents | python3 -m json.tool
```

**网页版**（v2.4.26+）：
- 打开 https://<relay>:9200/web/ 看 dashboard
- 改 `RELAY_AGENT_ENDPOINTS` 加公网 agent 后再 restart，dashboard 就能看到它们

---

# 八、自动化用 flag

上面"一键安装"模式是**脚本一步步问你**。如果你是**自动化场景**（CI、批量部署、Ansible 等），不想交互，可以传 flag 全跑：

```bash
# 服务端
sudo bash install-relay.sh --version v2.4.26 \
  --port 9200 \
  --tokens "tok-a,tok-b,tok-c" \
  --external-host usvps.mzhhua.cn \
  --agent-endpoints "mzhhua|https://mzhhua.cn:9009/api/report|AGENT_TOKEN,doogeee|https://doogeee.cn:9009/api/report|AGENT_TOKEN"

# 客户端
sudo bash install-reverse-agent.sh --version v2.4.24 \
  --relay-url https://usvps.mzhhua.cn:9200 \
  --token "tok-a" \
  --name "内网-nas-1"
```

**全 flag 列表**：

| 命令 | flag | 必填 | 说明 |
|---|---|---|---|
| 两个 | `--version` | ✅ | `latest` 或 `v2.4.24` |
| relay | `--port` | | 监听端口（默认 9200） |
| relay | `--tokens` | ✅ | 逗号分隔，**每个内网机器一个** |
| relay | `--add-token` | | **追加**新 token（不替换现有，已装过 relay 用） |
| relay | `--external-host` | 强烈建议 | cert SAN 域名 |
| relay | `--external-ip` | 可选 | cert SAN IP（没域名时用） |
| relay | `--agent-endpoints` | 可选（v2.4.26+）| 公网 agent 代理列表，逗号分隔 `name\|url\|token`（让网页版能看它们的 3xui 趋势图） |
| reverse-agent | `--relay-url` | ✅ | relay 的 URL（带 https:// 和端口） |
| reverse-agent | `--token` | ✅ | 服务端 token 列表里的某一个 |
| reverse-agent | `--name` | ✅ | app 端显示名 |
| reverse-agent | `--xui-db` | 可选 | 3x-ui sqlite 路径（默认 `/etc/x-ui/x-ui.db`） |
| reverse-agent | `--relay-cert-fp` | 强烈建议 | relay cert SHA-256 指纹，64 字符 hex |
| reverse-agent | `--interval` | 可选 | push 间隔（默认 5s） |
| 两个 | `--binary` | 可选 | 本地已下载的 binary（墙内用） |

# 九、升级

```bash
# 升级 relay（脚本会读之前的 env 文件，问你想保留还是改 token 等）
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-relay.sh | sudo bash

# 升级 reverse-agent
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh | sudo bash
```

env 文件不会被覆盖（脚本只覆盖 binary），重启服务即可。**升级跑同一条命令就行，不用改任何 flag**。

---

# 十、故障排查

### 1. "数据未就绪，请稍后重试"

reverse-agent 还没 push 过，或 push 失败。先看 reverse-agent 日志：

```bash
# v2.4.25+: 日志不在 journal
tail -n 50 /var/log/server-monitor/reverse-agent.log
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

### 6. install 脚本看起来"卡住 / 没跑完"（v2.4.25 之前的老坑）

老版本 install 脚本（v2.4.24 及更早）有两个静默坑：

1. **env 写入失败不报错** —— 极少数 corner case（磁盘满 / 目录权限 / heredoc 中断）下 `/opt/server-monitor/reverse-agent.env` 没写出来，但 service 已经 enable 了。结果：agent 启动失败 → systemd `Restart=on-failure` **无限重启**，日志里能看到 `restart counter is at 3026` 之类的恐怖数字，真正的错误被刷掉。
2. **启动检查只看 `is-active` + sleep 2** —— 对 Go binary 太短，agent 还没初始化完就报"启动失败"，用户被引导去看日志但其实没日志可看。

**v2.4.25+ 修复**（直接重跑 install 命令即可升级）：

- 写完 env 立刻 `[[ -s "$ENV_FILE" ]]` 检查 + 关键变量 grep，**任何一步失败立刻 exit 1**，不等 systemd 反复重启
- systemd unit 加 `StartLimitBurst=5` + `StartLimitIntervalSec=120s`，**5 分钟内连挂 5 次就放弃**
- 启动健康检查改成**轮询 SubState=running（最多 15 秒）**，失败时**自动内嵌最近 30 行 journal 日志 + 常见原因提示**

**如果你在 v2.4.24 或更老版本上踩过这个坑**，按下面救回来：

```bash
# 1. 看 service 现在的状态（如果是 activating / restarting 就是踩坑了）
sudo systemctl show server-monitor-reverse-agent -p SubState --value
sudo systemctl show server-monitor-reverse-agent -p NRestarts --value

# 2. 直接重跑 install 命令（覆盖 binary + 重新写 env + 重启）
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh | sudo bash

# 3. 重跑完应该看到 "✅ reverse-agent 启动成功 (SubState=running)"
#    然后 tail -f /var/log/server-monitor/reverse-agent.log 看 push ok
```

---

# 十一、设计取舍说明

- **为什么不做认证 + 注册流程？** —— 多一道复杂度，对个人项目过重。静态 token whitelist 已经够用，且每个 token 只对应一台机器，泄露了影响有限。
- **为什么不持久化数据？** —— relay 不是 source of truth。reverse-agent 永远有最新数据，relay 挂了数据丢点也无所谓。app 端的 v2.4.22 badge 会显示"离线"，用户会知道。
- **为什么不用 WebSocket / SSE？** —— app 端每 5 秒 poll 已经够用，HTTP POST/GET 简单可靠，不需要长连接。
- **为什么不直接用 mqtt / message queue？** —— 多一个依赖，多一个故障点。HTTP POST/GET 几十行 Go 就搞定。
