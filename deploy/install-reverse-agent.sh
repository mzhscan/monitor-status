#!/usr/bin/env bash
# 星黎监控 reverse-agent 一键部署脚本（v2.4.24+）
#
# 给"没有公网 IP 的内网机器"装 reverse-agent：
#   - 复用 pkg/collector.Collect()（跟 cmd/agent 同一份代码，输出格式完全一致）
#   - 每 5 秒主动 POST 给 relay 的 /ingest
#   - relay 按 token 路由，app 调 GET /api/report 拿这台机器的数据
#
# 一行命令：
#   curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh | \
#     sudo bash -s -- --version latest \\
#       --relay-url https://doogeee.cn:9100 \\
#       --token "tokA" \\
#       --name "内网-nas"
#
# 可选：
#   --xui-db /etc/x-ui/x-ui.db   跑 3x-ui 才需要，否则跳过
#   --interval 5                 push 间隔（秒），默认 5
#   --no-tls-verify              跳过 cert 校验（**不推荐**，仅调试）

set -euo pipefail

REPO="mzhscan/monitor-status"
VERSION=""
RELAY_URL=""
RELAY_TOKEN=""
AGENT_NAME=""
XUI_DB_PATH=""
PUSH_INTERVAL="5"
BINARY_PATH=""

DATA_DIR="/opt/server-monitor"
BIN_DIR="$DATA_DIR/bin"
ENV_FILE="$DATA_DIR/reverse-agent.env"
TMP=$(mktemp -d)
trap 'mavis-trash '$TMP' || rm -rf '$TMP' 2>/dev/null || true' EXIT

# ===== 参数解析 =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)       VERSION="$2"; shift 2 ;;
    --relay-url)     RELAY_URL="$2"; shift 2 ;;
    --token)         RELAY_TOKEN="$2"; shift 2 ;;
    --name)          AGENT_NAME="$2"; shift 2 ;;
    --xui-db)        XUI_DB_PATH="$2"; shift 2 ;;
    --interval)      PUSH_INTERVAL="$2"; shift 2 ;;
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
  echo "❌ 请用 root 或 sudo 运行（需要写 systemd unit）" >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  echo "❌ 缺少 --version（如 v2.4.24 或 latest）" >&2
  exit 1
fi

if [[ -z "$RELAY_URL" ]]; then
  echo "❌ 缺少 --relay-url（如 https://doogeee.cn:9100）" >&2
  exit 1
fi

if [[ -z "$RELAY_TOKEN" ]]; then
  echo "❌ 缺少 --token（必须跟 relay 白名单里的某个 token 一致）" >&2
  exit 1
fi

if [[ -z "$AGENT_NAME" ]]; then
  echo "❌ 缺少 --name（如 内网-nas，会显示在 app 端）" >&2
  exit 1
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
VERSION=${VERSION#vv}

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
  cp "$BINARY_PATH" "$BIN_DIR/reverse-agent"
else
  echo "📥 下载 reverse-agent-$VERSION-linux-$GOARCH ..."
  URL="https://github.com/$REPO/releases/download/$VERSION/reverse-agent-linux-$GOARCH"
  if ! curl -fsSL --max-time 120 "$URL" -o "$BIN_DIR/reverse-agent"; then
    echo "❌ 下载失败：$URL" >&2
    echo "   可能是版本 $VERSION 还没构建 reverse-agent 二进制" >&2
    echo "   或网络不通。备选：先用 --binary /path/to/reverse-agent 本地装" >&2
    exit 1
  fi
fi
chmod +x "$BIN_DIR/reverse-agent"

# ===== 写 env file =====
cat > "$ENV_FILE" <<EOF
# 星黎监控 reverse-agent 配置（v2.4.24+）
# ⚠️ chmod 600，root only。
RELAY_URL=$RELAY_URL
RELAY_TOKEN=$RELAY_TOKEN
AGENT_NAME=$AGENT_NAME
XUI_DB_PATH=$XUI_DB_PATH
PUSH_INTERVAL=${PUSH_INTERVAL}s
EOF
chmod 600 "$ENV_FILE"

# ===== systemd unit =====
SERVICE_FILE="/etc/systemd/system/server-monitor-reverse-agent.service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=星黎监控 reverse-agent (\$AGENT_NAME)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_DIR/reverse-agent -relay-url "\$RELAY_URL" -token "\$RELAY_TOKEN" -name "\$AGENT_NAME" -xui-db "\$XUI_DB_PATH" -interval \$PUSH_INTERVAL
Restart=on-failure
RestartSec=10s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable server-monitor-reverse-agent.service
systemctl restart server-monitor-reverse-agent.service

sleep 2
if systemctl is-active --quiet server-monitor-reverse-agent.service; then
  echo "✅ reverse-agent 启动成功"
else
  echo "❌ 启动失败，看日志：journalctl -u server-monitor-reverse-agent -n 50" >&2
  exit 1
fi

# ===== 输出部署信息 =====
cat <<EOF

════════════════════════════════════════════
✅ reverse-agent 部署完成
════════════════════════════════════════════
服务名:       server-monitor-reverse-agent
agent 名字:   $AGENT_NAME
推送目标:     $RELAY_URL
push 间隔:    ${PUSH_INTERVAL}s
env 文件:     $ENV_FILE
binary:       $BIN_DIR/reverse-agent
日志:         journalctl -u server-monitor-reverse-agent -f

app 端配置：
  - name:  $AGENT_NAME
  - url:   $RELAY_URL
  - token: $RELAY_TOKEN

如果 relay 显示 "数据已过期"，先看 reverse-agent 日志能不能 push 成功。
如果 cert hostname mismatch：relay 自签 cert 默认只有 127.0.0.1，
redeploy relay 时加 --external-ip / --external-host 即可。

════════════════════════════════════════════
EOF
