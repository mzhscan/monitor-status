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

### HTTPS 证书

agent 默认启 HTTPS（`USE_TLS=true`），自动按以下顺序找证书：

1. **显式 `CERT_FILE` / `KEY_FILE`**（install 脚本会问）
2. **trim OS**：自动从 `/usr/trim/etc/network_gateway_cert.conf` 加载
3. **3x-ui 自带 cert**：`/root/cert/{ip,domain}/fullchain.pem` + `privkey.pem`
4. **自签 fallback**：都不行就在 `/opt/server-monitor/certs/` 生成自签（10 年有效）

app 端首次连自签证书时，会弹"是否信任"对话框显示 SHA-256 指纹，跟服务端核对一致后再信任。

## Android APK

去 [Releases](https://github.com/mzhscan/monitor-status/releases) 下载 `monitor-status-*.apk` 装到手机。

**首次启动会自动弹"添加服务器"对话框**，按提示填显示名称 + agent URL + agent token 即可。如果首次没弹或之后删光了所有 server，点右上角 **+** 手动加。

每个 agent 独立一个 server 项（没有"统一面板"概念）。**默认按字母排序**，长按任意卡片的菜单 → 「排序」可进入 iOS 风格的拖动排序模式。

## Agent 平台

release 里有：
- `agent-linux-amd64`：x86_64 Linux（PC、VPS、普通 Linux）
- `agent-linux-arm64`：aarch64 Linux（树莓派 4/5、ARM VPS、Apple Silicon Mac mini、NAS）

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
