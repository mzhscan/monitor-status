# 星黎监控 (monitor-status)

多服务器硬件 + 3xui 流量监控。**无后端** —— Flutter 客户端直连每台机器上的 agent。

## 架构

```
[Flutter Android APK]
       │
       │ HTTPS（每台 server 一个连接）
       ▼
[Agent on us-vps :9101]   ──读──>  [3x-ui DB / 3xui cert]
[Agent on mzhhua :9101]   ──读──>  [trim OS 自动 cert]
[Agent on doogee :9101]  ──读──>  [trim OS 自动 cert]
```

- **APK**：Flutter 客户端，所有数据存本机
- **Agent**：被监控机器上跑的轻量 HTTP server（一个 binary，~7MB）
- **不需要后端**：每台机器的 agent 直接对 app 暴露 `/health` + `/api/report`

## 一键部署 agent

在**每台**被监控的机器上：

```bash
curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-agent.sh | \
  sudo bash -s -- --version v2.0.0
```

脚本会用中文 interactive 引导：
1. agent 名字（默认 hostname）
2. agent Token（自己设一个强密码）
3. 监听端口（默认 9101）
4. HTTPS 证书来源（自动检测 / 自己提供 / 留空生成自签）

也可以传 flag 跳过交互：
```bash
sudo bash install-agent.sh --version v2.0.0 \
  --name us-vps \
  --token CoAI_xxx \
  --port 9101 \
  --cert /root/cert/ip/fullchain.pem \
  --key /root/cert/ip/privkey.pem
```

### HTTPS 证书

agent 默认启 HTTPS（`USE_TLS=true`），自动按以下顺序找证书：

1. **显式 `CERT_FILE` / `KEY_FILE`**（install 脚本会问）
2. **trim OS**：自动从 `/usr/trim/etc/network_gateway_cert.conf` 加载（mzhhua / doogeee 适用）
3. **3x-ui 自带 cert**：`/root/cert/{ip,domain}/fullchain.pem` + `privkey.pem`（us-vps 适用）
4. **自签 fallback**：都不行就在 `/opt/server-monitor/certs/` 生成自签（10 年有效）

app 端首次连自签证书时，会弹"是否信任"对话框显示 SHA-256 指纹，跟服务端核对一致后再信任。

## Android APK

去 [Releases](https://github.com/mzhscan/monitor-status/releases) 下载 `monitor-status-*.apk` 装到手机。首次启动：
1. 点右上角 **+**
2. 填显示名称 + agent URL + agent token
3. 完成，3xui 客户端列表 + 72h 流量 + 硬件数据立即可见

每个 agent 独立一个 server 项（没有"统一面板"概念），按字母排序。

## Agent 平台

release 里有：
- `agent-linux-amd64`：x86_64 Linux（PC、VPS、普通 Linux）
- `agent-linux-arm64`：aarch64 Linux（树莓派 4/5、ARM VPS、Mac mini Asahi、NAS）

## Agent 配置（env）

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `AGENT_NAME` | ✅ | hostname | app 端显示名 |
| `AGENT_TOKEN` | ✅ | — | app 端连过来时验的密钥 |
| `AGENT_PORT` | | `9101` | 监听端口 |
| `USE_TLS` | | `true` | 是否启 HTTPS |
| `CERT_FILE` | | 自动 | 显式证书路径（覆盖自动查找） |
| `KEY_FILE` | | 自动 | 显式私钥路径 |
| `XUI_DB_PATH` | | `/etc/x-ui/x-ui.db` | 3x-ui sqlite |
| `COLLECT_INTERVAL` | | `2` | 采集间隔（秒） |
| `TRAFFIC_72H_FILE` | | `/opt/server-monitor/data/traffic_72h.json` | 72h 流量历史 |

## 安全 / 隐私

- agent token 走 `X-Agent-Token` header（常量时间比较）
- 公共 CA 证书（Let's Encrypt）自动信任
- 自签 / 不可信 cert 走 TOFU 弹窗（显示 SHA-256 指纹，user 跟服务端核对）
- token 存 APK 本地 SharedPreferences（**plaintext**，v2.1 改用 secure storage）
- agent 直连公网，token 鉴权（**有暴露面**，建议放 fail2ban / Cloudflare Tunnel）

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
git tag v2.0.0
git push origin v2.0.0
```

`.github/workflows/release.yml` 会编译：
- `agent-linux-amd64` / `agent-linux-arm64`
- `monitor-status-<YYMMDDHHmm>.apk`（用项目 keystore 签名）
- `SHA256SUMS`

并自动创建 GitHub Release。

## License

MIT
