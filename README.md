# 星黎监控

多服务器硬件 + 3xui 流量监控。**无后端** —— Android app 直连每台机器。

## Binary 一览（3 个组件，按机器场景分）

| 文件名 | 中文别名 | 装在哪 | 干嘛的 |
|---|---|---|---|
| `xingli-pub-amd64-X.Y.Z` | **有公网客户端**（x86_64） | 有公网 IP 的 Linux x86_64（VPS、PC） | app 直接连这台机器拉数据 |
| `xingli-pub-arm64-X.Y.Z` | **有公网客户端**（ARM） | 有公网 IP 的 Linux ARM（树莓派、ARM VPS、NAS） | 同上，ARM 架构 |
| `xingli-relay-amd64-X.Y.Z` | **无公网服务端**（x86_64） | 有公网 IP 的 Linux x86_64（只需要 1 台） | 接收内网机器 push 的数据 + 提供网页版 dashboard |
| `xingli-relay-arm64-X.Y.Z` | **无公网服务端**（ARM） | 有公网 IP 的 Linux ARM | 同上，ARM 架构 |
| `xingli-pri-amd64-X.Y.Z` | **无公网客户端**（x86_64） | **没**公网 IP 的内网 Linux x86_64 | 主动连公网代理，每 5 秒 push 一次数据 |
| `xingli-pri-arm64-X.Y.Z` | **无公网客户端**（ARM） | **没**公网 IP 的内网 Linux ARM | 同上，ARM 架构 |
| `xingli-X.Y.Z.apk` | Android app | — | 装到手机 |

**简短对照**：

- `pub` = public = **有公网**
- `relay` = **无公网服务端**（公网代理）
- `pri` = private = **无公网**

**按场景选**：

- 🖥️ **有公网 IP 的机器** → 装 `xingli-pub`（**有公网客户端**）
- 🌐 **没公网 IP 的内网机器**：
  1. 在 1 台有公网 IP 的机器上装 `xingli-relay`（**无公网服务端**）
  2. 在内网机器上装 `xingli-pri`（**无公网客户端**），连那台 relay
- 💡 **想看网页版 dashboard**：额外装一个 `xingli-relay`（同一台也行），配置「有公网客户端」URL

## Android app

去 [Releases](https://github.com/mzhscan/monitor-status/releases) 下载 `xingli-X.Y.Z.apk` 装到手机。

**首次启动会自动弹"添加服务器"对话框**，按提示填显示名称 + URL + token 即可。如果首次没弹或之后删光了所有 server，点底部 **+** tab 手动加。

每个 server 独立一项（没有"统一面板"概念）。**默认按字母排序**，长按任意卡片的菜单 → 「排序」可进入拖动排序模式。

## 一键部署

### 1️⃣ 装「有公网客户端」（`xingli-pub`，有公网 IP 的机器）

在**每台**有公网的机器上：

```bash
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-agent.sh | \
  sudo bash -s -- --version latest
```

脚本会用中文 interactive 引导：
1. 显示名称（默认 hostname）
2. 共享密钥（自己设一个强密码）
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

### 2️⃣ 没公网 IP？装「无公网服务端」+「无公网客户端」

#### 装「无公网服务端」（`xingli-relay`，1 台公网机器）

```bash
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-relay.sh | sudo bash
```

跑完会一步步问：端口 / token / 公网域名 / 防火墙 ... 全程回车 + 选数字即可。

#### 装「无公网客户端」（`xingli-pri`，内网机器）

```bash
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh | sudo bash
```

会问：relay URL / token / 机器名字 / cert 指纹 ...

> 自动化场景想跳过引导、传 flag 跑？看 `deploy/` 里每个脚本的 flag 列表。

#### 💡 install 脚本改进（v2.4.25+）

- **env 自检**：写完 env 后立刻校验存在 + 非空 + 关键变量齐全，**杜绝"二进制下了但 env 缺失"导致死循环重启**这种坑。
- **systemd StartLimit**：5 分钟内连挂 5 次就放弃，**不再无限重启**。
- **启动健康检查**：等 `SubState=running` 再判定成功，启动失败时**自动内嵌最近 30 行日志 + 常见原因提示**。
- **3x-ui db prompt**：`直接回车 = 跳过`（之前回车会误填 `/etc/x-ui/x-ui.db` 默认值）。

**升级**：直接重跑同样的 install 命令即可，env 文件保留，二进制覆盖重启即生效。

**老版本留下的"半坏"状态怎么救**：

```bash
# 1. 看 service 当前 SubState
sudo systemctl show server-monitor-<组件> -p SubState --value

# 2. 确认 env 存在 + 有内容
sudo cat /opt/server-monitor/<组件>.env

# 3. 缺了就补：直接重跑 install 命令（同 URL 同 flag）
# 4. 看日志
sudo tail -n 30 /var/log/server-monitor/<组件>.log
```

#### 装好之后再加内网机器（不重装无公网服务端）

**不要重装**（会重置 cert / 内存里已经 push 的数据 / app 端 cert trust）。用 `--add-token`：

```bash
# 一行加 N 个（逗号分隔）
sudo bash install-relay.sh --add-token "tok-new-1,tok-new-2,tok-new-3"

# 多次跑也 OK，重复自动去重
sudo bash install-relay.sh --add-token "tok-new-1"   # 已存在，自动跳过
```

**不知道用什么 token 字符串**？用 `openssl rand -hex 16` 生成 32 字符随机：

```bash
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

⚠️ **每个内网机器必须用独立 token**。一个 token 被多台机器共用会出现"数据在机器间跳变"（无公网服务端内存里同一个 token 只存一份最新数据，后 push 的覆盖前 push 的）。

### 日志位置（v2.4.25+）

**所有 monitor 服务的日志都不进 systemd journal** —— 各写到自己的文件，每天 logrotate 保留 4 天：

```bash
# 看实时日志
sudo tail -f /var/log/server-monitor/<组件>.log

# 查最后一次启动时间 + 最近 30 行
sudo tail -n 30 /var/log/server-monitor/<组件>.log
```

**为什么**：无公网客户端每 5s 一次 push，进 journal 会把系统 journald 撑爆（影响 sshd / nginx / 其他服务的日志）。我们的服务自己管自己的日志，**完全不影响系统**。

**老版本（journald-only）的服务**还在用 journal 记日志。升级方法：直接重跑 install 命令，service 文件会被新版本覆盖，自动迁移到新日志路径。

### HTTPS 证书

「有公网客户端」默认启 HTTPS（`USE_TLS=true`），自动按以下顺序找证书：

1. **显式 `CERT_FILE` / `KEY_FILE`**（install 脚本会问）
2. **trim OS**：自动从 `/usr/trim/etc/network_gateway_cert.conf` 加载
3. **3x-ui 自带 cert**：`/root/cert/{ip,domain}/fullchain.pem` + `privkey.pem`
4. **自签 fallback**：都不行就在 `/opt/server-monitor/certs/` 生成自签（10 年有效）

app 端首次连自签证书时，会弹"是否信任"对话框显示 SHA-256 指纹，跟服务端核对一致后再信任。

## 网页版（v2.4.26+）

不用装 app，浏览器打开就能看：

```
https://<无公网服务端的域名或 IP>:<无公网服务端端口>/web/
```

例：https://usvps.mzhhua.cn:9200/web/

**功能**：
- 📊 全部机器的实时 CPU / 内存 / 磁盘 / 网络 / 运行时长
- 🛰️ 3xui 客户端列表 + 在线数 + 总流量
- 📈 **3xui 客户端的 72h 累计流量折线图**（点客户端行展开）
- 🌓 暗色主题，自适应 PC / 平板 / 手机
- 🔄 每 5s 自动刷新

**架构**：
- 静态文件（HTML / CSS / JS）**编译进无公网服务端二进制**（`//go:embed all:web`），不是单独目录
- 内网「无公网客户端」推过来的数据直接用（push 模式，零延迟）
- 公网「有公网客户端」需要额外配 `RELAY_AGENT_ENDPOINTS`（install 脚本会问），无公网服务端 5s 缓存代理拉取

**数据流**：
```
内网「无公网客户端」→ POST /ingest (push)
公网「有公网客户端」───→ 无公网服务端 ──GET /api/report (proxy, 5s 缓存)
                            ↓
                       浏览器 /web/
```

**配置公网「有公网客户端」**（让网页版能看它们的 3xui 趋势图）：

重跑 `install-relay.sh`，到「🌐 公网客户端代理」那一步，填：
```
mzhhua|https://mzhhua.cn:9009/api/report|<有公网客户端的 AGENT_TOKEN>
doogeee|https://doogeee.cn:9009/api/report|<有公网客户端的 AGENT_TOKEN>
usvps|https://usvps.mzhhua.cn:9009/api/report|<有公网客户端的 AGENT_TOKEN>
```

**安全**：网页版没有独立 auth —— 跟 Android app 一样靠 URL 本身私有（自签 cert + 域名/IP 不公开）。如果要把网页版公开访问，建议套一层 basic auth（用 Nginx / Caddy 反代）。

**限制**：
- View-only，不能加/删服务器（管理还是用 Android app）
- 趋势图只有 3xui 客户端流量（3xui 客户端数据是「有公网客户端」按需 push 的）
- 折线图 downsample 到 200 点（72h 原始数据可能 5 万+ 点，前端画不下）

## 配置（「有公网客户端」env）

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

- 共享密钥走 `X-Agent-Token` header（常量时间比较）
- 公共 CA 证书（Let's Encrypt）自动信任
- 自签 / 不可信 cert 走 TOFU 弹窗（显示 SHA-256 指纹，user 跟服务端核对）
- token 存 Android Keystore（v2.3.0 起改用 `flutter_secure_storage`）
- 「有公网客户端」默认监听全网卡，token 鉴权（**有公网暴露面**）。缓解方式：
  - `AGENT_BIND=127.0.0.1` + SSH 隧道 / WireGuard / Cloudflare Tunnel
  - 前面套 fail2ban + 反代限制来源 IP
- 自签证书的 SAN 列表默认只有 `127.0.0.1` / `::1` / `localhost`，公网连会被 hostname mismatch 拦截。通过 `AGENT_IPS` / `AGENT_HOSTNAMES` 把真实地址加到 SAN 后可以正常验证

## 开发

```bash
# 后端（单 module 跨 cmd/）
go run ./cmd/agent            # → xingli-pub      （有公网客户端）
go run ./cmd/relay-server     # → xingli-relay   （无公网服务端）
go run ./cmd/reverse-agent    # → xingli-pri      （无公网客户端）

# Flutter
cd app
flutter pub get
flutter run --dart-define=GLASS_STYLE=solid
```

## 发布

```bash
git tag X.Y.Z          # 不带 v 前缀
git push origin X.Y.Z
```

Release workflow 自动 build 6 个 binary + 1 个 APK + SHA256SUMS，按 ASCII 命名 `xingli-<角色>-<架构>-<版本>` 发布。

## License

MIT
