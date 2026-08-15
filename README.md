# 星黎监控 (monitor-status)

多服务器硬件 + 3xui 流量监控。**无后端** —— Flutter 客户端直连每台机器上的 agent。

## 架构

```
[Flutter Android APK]
       │
       │ HTTPS（每台 server 一个连接）
       ▼
[Agent on server-1 :9101]   ──读──>  [3x-ui DB / 3xui cert]
[Agent on server-2 :9101]   ──读──>  [trim OS 自动 cert]
[Agent on server-3 :9101]   ──读──>  [自签 / 其他 cert]
```

- **APK**：Flutter 客户端，所有数据存本机
- **Agent**：被监控机器上跑的轻量 HTTP server（一个 binary，~14MB）
- **不需要后端**：每台机器的 agent 直接对 app 暴露 `/health` + `/api/report`
- **同一 binary 适配两种场景**：装在 VPS 上会顺带读 `/etc/x-ui/x-ui.db` 采集 3xui 客户端流量 + 72h 流量历史；装在 NAS（无 x-ui）上只采集硬件数据

## 一键部署 agent

在**每台**被监控的机器上：

```bash
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-agent.sh | \
  sudo bash -s -- --version latest
```

脚本会用中文 interactive 引导：
1. agent 名字（默认 hostname）
2. agent Token（自己设一个强密码）
3. 监听端口（默认 9101）
4. HTTPS 证书来源（自动检测 / 自己提供 / 留空生成自签）

也可以传 flag 跳过交互：
```bash
sudo bash install-agent.sh --version latest \
  --name my-server \
  --token '<your-strong-secret>' \
  --port 9101 \
  --cert /root/cert/ip/fullchain.pem \
  --key /root/cert/ip/privkey.pem
```

### 没有公网 IP 的内网机器？

v2.4.24+ 新增了 **relay + reverse-agent** 模式，让家里树莓派 / 内网 NAS / 公司内网 server 也能被监控。**app 端零改动**。

- 在有公网 IP 的服务器（如 usvps）装 **relay-server**
- 在内网机器装 **reverse-agent**，主动 push 数据给 relay
- app 配置 server 时 URL 填 relay、token 跟 reverse-agent 一致

详细部署文档：[relay/README.md](relay/README.md)

#### 初次安装（一行命令 + 脚本引导）

```bash
# 服务端（公网，SSH 到有公网的机器上跑）
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-relay.sh | sudo bash

# 客户端（内网，SSH 到内网机器上跑）
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh | sudo bash
```

跑完会一步步问：版本 / 端口 / token / 公网域名 / 防火墙 ... 全程回车 + 选数字即可。

> 自动化场景想跳过引导、传 flag 跑？看 [relay/README.md → 自动化用 flag](relay/README.md#自动化用-flag)

#### 💡 v2.4.25+ install 脚本改进

- **env 自检**：写完 `/opt/server-monitor/{reverse-agent,relay}.env` 后立刻校验存在 + 非空 + 关键变量齐全，**杜绝"二进制下了但 env 缺失"导致 agent 死循环重启**这种坑（旧版在某些 corner case 下会沉默写失败）。
- **systemd StartLimit**：5 分钟内连挂 5 次就放弃，**不再无限重启**（之前能刷 3000+ 次重启信息把日志塞满）。
- **启动健康检查**：等 `SubState=running` 再判定成功，启动失败时**自动内嵌最近 30 行 journal 日志 + 常见原因提示**，不用再开第二个终端查。
- **3x-ui db prompt**：`直接回车 = 跳过`（之前回车会误填 `/etc/x-ui/x-ui.db` 默认值，对没跑 3x-ui 的机器造成误导）。

**升级**：直接重跑同样的 install 命令即可，env 文件保留，二进制覆盖重启即生效。

**老版本留下的"半坏"状态怎么救**（比如 `systemctl status` 一直显示 activating/restarting）：

```bash
# 1. 看 service 当前 SubState
sudo systemctl show server-monitor-reverse-agent -p SubState --value

# 2. 确认 env 存在 + 有内容
sudo cat /opt/server-monitor/reverse-agent.env

# 3. 缺了就补：直接重跑 install 命令（同 URL 同 flag），它会重新写 env + 启服务
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh | sudo bash

# 4. 看日志（v2.4.25+: 日志不在 journal，在自己的文件里）
sudo tail -n 30 /var/log/server-monitor/reverse-agent.log
```

#### 装好之后再加内网机器（不重装 relay）

**不要重装**（会重置 cert / 内存里已经 push 的数据 / app 端 cert trust）。用 `--add-token`：

```bash
# 一行加 N 个（逗号分隔）
sudo bash install-relay.sh --add-token "tok-new-1,tok-new-2,tok-new-3"

# 多次跑也 OK，重复自动去重
sudo bash install-relay.sh --add-token "tok-new-1"   # 已存在，自动跳过

# 不会动 cert / binary / 已经 push 的内存数据
# 仅追加 env + restart
```

**不知道用什么 token 字符串**？用 `openssl rand -hex 16` 生成 32 字符随机：

```bash
# 一行生成 N 个 + 一次 add
TOKENS=""
for i in 1 2 3 4 5; do
  T=$(openssl rand -hex 16)
  TOKENS="${TOKENS:+$TOKENS,}$T"
  echo "  tok-$i: $T"      # 打印出来你抄到内网机器
done
sudo bash install-relay.sh --add-token "$TOKENS"
```

**想删某台内网机器的 token**（如下线了）：手动改 env：

```bash
sudo nano /opt/server-monitor/relay.env     # 改 RELAY_TOKENS=
sudo systemctl restart server-monitor-relay
```

⚠️ **每个内网机器必须用独立 token**。一个 token 被多台机器共用会出现"数据在机器间跳变"（relay 内存里同一个 token 只存一份最新数据，后 push 的覆盖前 push 的）。

详细：[relay/README.md → 二.5、已装好之后再加 token](relay/README.md#二5已装好之后再加-token新增内网机器)

### 日志位置（v2.4.25+）

**所有 monitor 服务（agent / relay-server / reverse-agent）的日志都不进 systemd journal** —— 各写到自己的文件，每天 logrotate 保留 4 天：

```bash
# 看实时日志
sudo tail -f /var/log/server-monitor/agent.log
sudo tail -f /var/log/server-monitor/relay.log
sudo tail -f /var/log/server-monitor/reverse-agent.log

# 查最后一次启动时间 + 最近 30 行
sudo tail -n 30 /var/log/server-monitor/reverse-agent.log
```

**为什么**：reverse-agent 每 5s 一次 push，进 journal 会把系统 journald 撑爆（影响 sshd / nginx / 其他服务的日志）。我们的服务自己管自己的日志，**完全不影响系统**。

**logrotate 配置文件**：`/etc/logrotate.d/server-monitor-{agent,relay,reverse-agent}`（每天 rotate / 保留 4 份 / 压缩 / copytruncate）。

**老版本（journald-only）的服务**还在用 journal 记日志。升级方法：直接重跑 install 命令，service 文件会被新版本覆盖，自动迁移到新日志路径。

### HTTPS 证书

agent 默认启 HTTPS（`USE_TLS=true`），自动按以下顺序找证书：

1. **显式 `CERT_FILE` / `KEY_FILE`**（install 脚本会问）
2. **trim OS**：自动从 `/usr/trim/etc/network_gateway_cert.conf` 加载
3. **3x-ui 自带 cert**：`/root/cert/{ip,domain}/fullchain.pem` + `privkey.pem`
4. **自签 fallback**：都不行就在 `/opt/server-monitor/certs/` 生成自签（10 年有效）

app 端首次连自签证书时，会弹"是否信任"对话框显示 SHA-256 指纹，跟服务端核对一致后再信任。

## 网页版（v2.4.26+）

不用装 app，浏览器打开就能看：

```
https://<relay 的域名或 IP>:<relay 端口>/web/
```

例：https://usvps.mzhhua.cn:9200/web/

**功能**：
- 📊 全部机器的实时 CPU / 内存 / 磁盘 / 网络 / 运行时长
- 🛰️ 3xui 客户端列表 + 在线数 + 总流量
- 📈 **3xui 客户端的 72h 累计流量折线图**（点客户端行展开）
- 🌓 暗色主题，自适应 PC / 平板 / 手机
- 🔄 每 5s 自动刷新

**架构**：
- 静态文件（HTML / CSS / JS）**编译进 relay 二进制**（`//go:embed all:web`），不是单独目录
- 内网 reverse-agent 推过来的数据直接用（push 模式，零延迟）
- 公网 agent（mzhhua.cn / doogeee.cn / usvps agent 自身）需要额外配 `RELAY_AGENT_ENDPOINTS`（install 脚本会问），relay 5s 缓存代理拉取

**数据流**：
```
内网 reverse-agent → POST /ingest (push)
公网 agent ───→ relay ──GET /api/report (proxy, 5s 缓存)
                            ↓
                       浏览器 /web/
```

**配置公网 agent**（让网页版能看它们的 3xui 趋势图）：

重跑 `install-relay.sh`，到「🌐 公网 agent 代理」那一步，填：
```
mzhhua|https://mzhhua.cn:9009/api/report|<mzhhua 的 AGENT_TOKEN>
doogeee|https://doogeee.cn:9009/api/report|<doogeee 的 AGENT_TOKEN>
usvps|https://usvps.mzhhua.cn:9009/api/report|<usvps 的 AGENT_TOKEN>
```
（`|` 分隔的是 name / url / token，多条用 `,` 分隔）

**安全**：网页版没有独立 auth —— 跟 Android app 一样靠 relay URL 本身私有（自签 cert + 域名/IP 不公开）。如果要把网页版公开访问，建议套一层 basic auth（用 Nginx / Caddy 反代）。

**限制**：
- View-only，不能加/删服务器（管理还是用 Android app）
- 趋势图只有 3xui 客户端流量（agent 只为这个做了 72h history）
- 折线图 downsample 到 200 点（72h 原始数据可能 5 万+ 点，前端画不下）

## Android APK

去 [Releases](https://github.com/mzhscan/monitor-status/releases) 下载 `monitor-status-*.apk` 装到手机。

**首次启动会自动弹"添加服务器"对话框**，按提示填显示名称 + agent URL + agent token 即可。如果首次没弹或之后删光了所有 server，点右上角 **+** 手动加。

每个 agent 独立一个 server 项（没有"统一面板"概念）。**默认按字母排序**，长按任意卡片的菜单 → 「排序」可进入 iOS 风格的拖动排序模式。

## Binary 一览（3 个组件，按场景分）

| Binary | 中文别名 | 装在哪 | 干嘛的 |
|---|---|---|---|
| `agent-linux-amd64` | **公网直连版**（x86_64） | 有公网 IP 的 Linux x86_64（VPS、PC） | 监听 9101，app 直接连这台机器拉数据 |
| `agent-linux-arm64` | **公网直连版**（ARM） | 有公网 IP 的 Linux ARM（树莓派、ARM VPS、Apple Silicon Mac mini、NAS） | 同上，ARM 架构 |
| `relay-server-linux-amd64` | **公网中转版**（x86_64） | 有公网 IP 的 Linux x86_64（只需要 1 台） | 接收内网机器 push 的数据，再转发给 app；同时提供 `/web/` 网页版 dashboard |
| `relay-server-linux-arm64` | **公网中转版**（ARM） | 有公网 IP 的 Linux ARM | 同上，ARM 架构 |
| `reverse-agent-linux-amd64` | **内网推送版**（x86_64） | **没**公网 IP 的内网 Linux x86_64 | 主动连公网 relay，每 5 秒 push 一次数据 |
| `reverse-agent-linux-arm64` | **内网推送版**（ARM） | **没**公网 IP 的内网 Linux ARM | 同上，ARM 架构 |

**按场景选**：

- 🖥️ **有公网 IP 的机器**：装 `agent`（公网直连版）
- 🌐 **没公网 IP 的内网机器**：
  1. 在 1 台有公网 IP 的机器上装 `relay-server`（公网中转版）
  2. 在内网机器上装 `reverse-agent`（内网推送版），连那台 relay
- 💡 **有公网 + 想看网页版 dashboard**：再额外装一个 `relay-server`（同一台也行，不同端口），配置公网 agent 的 URL 到 `RELAY_AGENT_ENDPOINTS`

详细部署：[relay/README.md](relay/README.md)

## Agent 配置（env）

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `AGENT_NAME` | ✅ | hostname | app 端显示名 |
| `AGENT_TOKEN` | ✅ | — | app 端连过来时验的密钥 |
| `AGENT_PORT` | | `9101` | 监听端口 |
| `AGENT_BIND` | | `0.0.0.0` | 监听地址。有公网 IP 的机器建议改成 `127.0.0.1` 配合 SSH 隧道或 VPN，避免 9101 暴露公网被扫 |
| `USE_TLS` | | `true` | 是否启 HTTPS |
| `CERT_FILE` | | 自动 | 显式证书路径（覆盖自动查找） |
| `KEY_FILE` | | 自动 | 显式私钥路径 |
| `AGENT_IPS` | | 空 | 逗号分隔的 IP，自签证书会加到 SAN 列表里 |
| `AGENT_HOSTNAMES` | | 空 | 逗号分隔的 DNS 名，自签证书会加到 SAN 列表里 |
| `XUI_DB_PATH` | | `/etc/x-ui/x-ui.db` | 3x-ui sqlite |
| `COLLECT_INTERVAL` | | `2` | 采集间隔（秒） |
| `TRAFFIC_72H_FILE` | | `/opt/server-monitor/data/traffic_72h.json` | 72h 流量历史 |

## 安全 / 隐私

- agent token 走 `X-Agent-Token` header（常量时间比较）
- 公共 CA 证书（Let's Encrypt）自动信任
- 自签 / 不可信 cert 走 TOFU 弹窗（显示 SHA-256 指纹，user 跟服务端核对）
- token 存 Android Keystore（v2.3.0 起改用 `flutter_secure_storage`，v2.3 之前是 SharedPreferences 明文）
- agent 默认监听全网卡，token 鉴权（**有公网暴露面**）。缓解方式：
  - `AGENT_BIND=127.0.0.1` + SSH 隧道 / WireGuard / Cloudflare Tunnel
  - 前面套 fail2ban + 反代限制来源 IP
- 自签证书的 SAN 列表默认只有 `127.0.0.1` / `::1` / `localhost`，公网连会被 hostname mismatch 拦截。通过 `AGENT_IPS` / `AGENT_HOSTNAMES` 把真实地址加到 SAN 后可以正常验证（不用绕 Flutter 端的 issuer 白名单）

## 开发

```bash
# 后端 / agent (单 module 跨 cmd/)
go run ./cmd/agent

# Flutter
cd app
flutter pub get
flutter run --dart-define=GLASS_STYLE=solid
```

## Release

```bash
git tag v2.4.12
git push origin v2.4.12
```

`.github/workflows/release.yml` 会编译：
- `agent-linux-amd64` / `agent-linux-arm64`
- `monitor-status-<YYMMDDHHmm>.apk`（用项目 keystore 签名）
- `SHA256SUMS`

并自动创建 GitHub Release。

## License

MIT
