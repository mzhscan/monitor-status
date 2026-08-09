#!/usr/bin/env bash
# 星黎监控 relay 一键部署脚本（v2.4.24+）
#
# 给"有公网 IP 的服务器"装 relay：
#   - 内网 reverse-agent 主动 POST 数据给 relay
#   - app 调 GET /api/report 从 relay 拉数据（协议跟现有 agent 完全一致）
#   - app 端零改动，每个内网机器配一个独立 token
#
# 一行命令（最新版自动从 GitHub release 解析）：
#   curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-relay.sh | \
#     sudo bash -s -- --version latest --tokens "tokA,tokB"
#
# 例（指定版本 + 自定义端口 + 公网 IP/域名用于 cert SAN）：
#   sudo bash install-relay.sh --version v2.4.24 \
#     --port 9100 \
#     --tokens "tokA,tokB" \
#     --external-ip 1.2.3.4 \
#     --external-host doogeee.cn

set -euo pipefail

REPO="mzhscan/monitor-status"
VERSION=""
PORT="9100"
TOKENS=""
EXTERNAL_IP=""
EXTERNAL_HOST=""
BINARY_PATH=""

DATA_DIR="/opt/server-monitor"
BIN_DIR="$DATA_DIR/bin"
ENV_FILE="$DATA_DIR/relay.env"
TMP=$(mktemp -d)
trap 'mavis-trash '$TMP' || rm -rf '$TMP' 2>/dev/null || true' EXIT

# ===== 参数解析 =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)       VERSION="$2"; shift 2 ;;
    --port)          PORT="$2"; shift 2 ;;
    --tokens)        TOKENS="$2"; shift 2 ;;
    --external-ip)   EXTERNAL_IP="$2"; shift 2 ;;
    --external-host) EXTERNAL_HOST="$2"; shift 2 ;;
    --binary)        BINARY_PATH="$2"; shift 2 ;;
    --data-dir)      DATA_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) echo "❌ 未知参数: $1" >&2; exit 1 ;;
  esac
done

# ===== 前置检查 =====
if [[ $EUID -ne 0 ]]; then
  echo "❌ 请用 root 或 sudo 运行（relay 需要监听端口 + 写 systemd unit）" >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  echo "❌ 缺少 --version（如 v2.4.24 或 latest）" >&2
  exit 1
fi

if [[ -z "$TOKENS" ]]; then
  echo "❌ 缺少 --tokens（逗号分隔，至少 1 个）" >&2
  echo "   例: --tokens \"tokA,tokB\"" >&2
  echo "   每个 token 对应一台内网机器，reverse-agent push 用哪个 token，app poll 也用哪个 token" >&2
  exit 1
fi

# ===== 自动探测公网 IP/域名（cert SAN 需要） =====
if [[ -z "$EXTERNAL_IP" ]]; then
  EXTERNAL_IP=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
  if [[ -n "$EXTERNAL_IP" ]]; then
    echo "🔍 自动探测到公网 IP: $EXTERNAL_IP（用于 cert SAN）"
  fi
fi

# ===== 解析 --version latest =====
if [[ "$VERSION" == "latest" ]]; then
  echo "🔍 查询 GitHub 最新 release..."
  VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | head -1 | sed -E 's/.*"v?([^"]+)".*/\1/')
  if [[ -z "$VERSION" ]]; then
    echo "❌ 解析 latest 失败，请显式传 --version vX.Y.Z" >&2
    exit 1
  fi
  echo "✅ 最新版: v$VERSION"
fi
VERSION="v$VERSION"
VERSION=${VERSION#vv}  # 防止用户传 "vv2.4.24" 之类

# ===== 下载 binary =====
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) GOARCH="amd64" ;;
  aarch64|arm64) GOARCH="arm64" ;;
  *) echo "❌ 不支持的架构: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$BIN_DIR"

if [[ -n "$BINARY_PATH" ]]; then
  echo "📦 使用本地 binary: $BINARY_PATH"
  cp "$BINARY_PATH" "$BIN_DIR/relay-server"
else
  echo "📥 下载 relay-server-$VERSION-linux-$GOARCH ..."
  URL="https://github.com/$REPO/releases/download/$VERSION/relay-server-linux-$GOARCH"
  if ! curl -fsSL --max-time 120 "$URL" -o "$BIN_DIR/relay-server"; then
    echo "❌ 下载失败：$URL" >&2
    echo "   可能是版本 $VERSION 还没构建 relay-server 二进制" >&2
    echo "   或网络不通。备选：先用 --binary /path/to/relay-server 本地装" >&2
    exit 1
  fi
fi
chmod +x "$BIN_DIR/relay-server"

# ===== 写 env file =====
cat > "$ENV_FILE" <<EOF
# 星黎监控 relay 配置（v2.4.24+）
# ⚠️ chmod 600，root only。不要 commit 到 git。
RELAY_PORT=$PORT
RELAY_BIND=0.0.0.0
RELAY_TOKENS=$TOKENS
RELAY_IPS=$EXTERNAL_IP
RELAY_HOSTS=$EXTERNAL_HOST
RELAY_DATA_DIR=$DATA_DIR
EOF
chmod 600 "$ENV_FILE"

# ===== systemd unit =====
SERVICE_FILE="/etc/systemd/system/server-monitor-relay.service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=星黎监控 relay (server-monitor-relay)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_DIR/relay-server
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable server-monitor-relay.service
systemctl restart server-monitor-relay.service

sleep 2
if systemctl is-active --quiet server-monitor-relay.service; then
  echo "✅ relay 启动成功"
else
  echo "❌ relay 启动失败，看日志：journalctl -u server-monitor-relay -n 50" >&2
  exit 1
fi

# ===== 输出部署信息 =====
cat <<EOF

════════════════════════════════════════════
✅ relay 部署完成
════════════════════════════════════════════
服务名:    server-monitor-relay
监听端口:  $PORT
env 文件:  $ENV_FILE
binary:    $BIN_DIR/relay-server
日志:      journalctl -u server-monitor-relay -f

token 白名单（每行一个，对应一台内网机器）:
$(echo "$TOKENS" | tr ',' '\n' | awk '{printf "  %s\n", $0}')

下一步：
  1. 在内网机器上装 reverse-agent（每台机器用一个 token）
     例: sudo bash install-reverse-agent.sh --version $VERSION \\
           --relay-url http://<relay 公网 IP>:$PORT \\
           --token <上面任一 token> \\
           --name "内网-1"

  2. app 端加服务器：
     - name:  内网-1
     - url:   https://<relay 公网域名>:$PORT
     - token: 上面任一 token

  3. 防火墙：放行 $PORT/TCP（只放行从内网 reverse-agent 来的 IP 段更安全）

════════════════════════════════════════════
EOF
