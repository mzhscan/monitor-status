#!/usr/bin/env bash
# 星黎监控 reverse-agent 一键部署脚本（v2.4.24+）
#
# 装在**没有公网 IP 的内网机器**上（家里 NAS、树莓派、公司内网 server）。
# 主动 push 数据给 relay，每台机器用一个独立 token。
#
# 一行命令（interactive 引导填参数）：
#   curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh | sudo bash
#
# 自动化（跳过交互，所有 flag 必填）：
#   sudo bash install-reverse-agent.sh --version v2.4.24 \
#     --relay-url https://usvps.mzhhua.cn:9200 \
#     --token "tok-nas-1" --name "内网-nas-1"

set -euo pipefail

# 避免某些 UTF-8 locale 下 bash 解析中文字符串 + set -u 时报 "unbound variable"
# 误报（echo "🔍 xxx: $VAR（中文括号" 这种会触发）。C.UTF-8 既支持中文又稳。
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"

REPO="mzhscan/monitor-status"
VERSION=""
RELAY_URL=""
RELAY_TOKEN=""
AGENT_NAME=""
XUI_DB_PATH=""
PUSH_INTERVAL=""
RELAY_CERT_FP=""
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
    --relay-cert-fp) RELAY_CERT_FP="$2"; shift 2 ;;
    --binary)        BINARY_PATH="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) echo "❌ 未知参数: $1" >&2; exit 1 ;;
  esac
done

# ===== 前置检查 =====
if [[ $EUID -ne 0 ]]; then
  echo "❌ 请用 root 或 sudo 运行" >&2
  exit 1
fi

# ===== TTY / prompt 工具 =====
# 这里必须把 read fd 和 write fd 拆开。如果 PROMPT_FD=0 既当 read 又当 write，
# `printf "..." >&0` 会把 stdout 重定向到 fd 0（stdin），导致 prompt 文本
# 被 read 当作输入读到。这是经典坑。
READ_FD=0
WRITE_FD=1
if [[ -e /dev/tty ]]; then
  # 备份原始 stdin/stdout，然后从 /dev/tty 开新 fd
  if exec 3</dev/tty 4>/dev/tty 2>/dev/null; then
    READ_FD=3
    WRITE_FD=4
  fi
fi

prompt_line() {
  local prompt="$1"
  local varname="$2"
  local default="${3:-}"
  local line
  if [[ -n "$default" ]]; then
    printf "%s [%s]: " "$prompt" "$default" >&"$WRITE_FD"
  else
    printf "%s: " "$prompt" >&"$WRITE_FD"
  fi
  IFS= read -r line <&"$READ_FD" || line=""
  if [[ -z "$line" && -n "$default" ]]; then
    line="$default"
  fi
  printf -v "$varname" '%s' "$line"
}

prompt_yesno() {
  local prompt="$1"
  local default="${2:-y}"
  local choice
  local hint="[Y/n]"
  [[ "$default" == "n" ]] && hint="[y/N]"
  printf "%s %s: " "$prompt" "$hint" >&"$WRITE_FD"
  IFS= read -r choice <&"$READ_FD" || choice=""
  choice="${choice:-$default}"
  # 用 tr 替代 ${choice,,} 兼容 bash 3.2（macOS 自带）
  # 用 here-string <<< 避免 subshell 共享 stdin 的坑
  local lower
  lower=$(tr '[:upper:]' '[:lower:]' <<< "$choice")
  case "$lower" in
    y|yes|是|1) return 0 ;;
    *) return 1 ;;
  esac
}

require_interactive() {
  if [[ ! -e /dev/tty ]]; then
    echo "" >&2
    echo "❌ 需要 interactive 输入，但检测不到 /dev/tty" >&2
    echo "" >&2
    echo "💡 你大概是用 'curl | sudo bash' 跑的——必须传 --relay-url / --token / --name" >&2
    echo "" >&2
    echo "   正确用法（任选其一）：" >&2
    echo "   1) 先下载脚本再跑：" >&2
    echo "      curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-reverse-agent.sh -o /tmp/install-reverse-agent.sh" >&2
    echo "      sudo bash /tmp/install-reverse-agent.sh" >&2
    echo "" >&2
    echo "   2) 全部用 --flags 覆盖（适合自动化）：" >&2
    echo "      curl -fsSL ... | sudo bash -s -- --version v2.4.24 --relay-url https://usvps.mzhhua.cn:9200 --token 'tok-nas-1' --name '内网-nas-1'" >&2
    exit 1
  fi
}

# ===== Welcome =====
echo ""
echo "╔════════════════════════════════════════════╗"
echo "║   星黎监控 reverse-agent 安装向导          ║"
echo "║   （内网机器主动 push 数据给 relay）        ║"
echo "╚════════════════════════════════════════════╝"
echo ""

# ===== 版本 =====
if [[ -z "$VERSION" ]]; then
  require_interactive
  prompt_line "版本（latest = 最新版 / 或填具体如 v2.4.24）" VERSION "latest"
fi

# ===== 解析 latest =====
if [[ "$VERSION" == "latest" ]]; then
  echo "🔍 查询 GitHub 最新 release..."
  LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | head -1 | sed -E 's/.*"v?([^"]+)".*/\1/')
  if [[ -z "$LATEST" ]]; then
    echo "❌ 解析 latest 失败，请显式传 --version vX.Y.Z" >&2
    exit 1
  fi
  VERSION="v$LATEST"
  echo "✅ 最新版: $VERSION"
fi
# 用户可能传 "v2.4.24" 或 "2.4.24"，统一成 "v2.4.24" 形式（带 v 前缀）
case "$VERSION" in
  v*) ;;
  *) VERSION="v$VERSION" ;;
esac

# ===== relay URL =====
if [[ -z "$RELAY_URL" ]]; then
  echo ""
  echo "📡 relay 地址（部署 relay 时输出的那个 URL，含 https:// 和端口）"
  echo "   例: https://usvps.mzhhua.cn:9200"
  require_interactive
  while [[ -z "$RELAY_URL" ]]; do
    prompt_line "relay URL" RELAY_URL
  done
  # 自动加 https:// 前缀（如果用户没填）
  if [[ ! "$RELAY_URL" =~ ^https?:// ]]; then
    RELAY_URL="https://$RELAY_URL"
    echo "   → 自动加前缀: $RELAY_URL"
  fi
fi

# ===== 验证 relay 可达 =====
echo "🔍 检查 relay 可达..."
if curl -fsSL --max-time 8 -k "$RELAY_URL/health" >/dev/null 2>&1; then
  echo "✅ relay /health 通了"
else
  echo "⚠️  relay /health 不通（继续安装，启动后 reverse-agent 会自动重试）"
fi

# ===== token =====
if [[ -z "$RELAY_TOKEN" ]]; then
  echo ""
  echo "🔑 token（跟部署 relay 时输出的 token 列表里挑一个，每台机器用不同的）"
  require_interactive
  while [[ -z "$RELAY_TOKEN" ]]; do
    prompt_line "token" RELAY_TOKEN
  done
fi

# ===== agent name =====
if [[ -z "$AGENT_NAME" ]]; then
  DEFAULT_NAME=$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
  echo ""
  echo "📛 agent 名字（app 端显示，建议中文+机器特征，如 内网-nas-1）"
  require_interactive
  prompt_line "agent 名字" AGENT_NAME "$DEFAULT_NAME"
fi

# ===== 3x-ui db 路径 =====
if [[ -z "$XUI_DB_PATH" ]]; then
  echo ""
  echo "📂 3x-ui 数据库路径（这台机器跑 3x-ui 才需要，否则留空跳过）"
  echo "   默认 /etc/x-ui/x-ui.db（3x-ui 标准路径）"
  require_interactive
  prompt_line "3x-ui db 路径（留空跳过）" XUI_DB_PATH "/etc/x-ui/x-ui.db"
  if [[ -z "$XUI_DB_PATH" ]]; then
    XUI_DB_PATH=""
  fi
fi

# ===== relay cert 指纹（可选但推荐） =====
if [[ -z "$RELAY_CERT_FP" ]]; then
  echo ""
  echo "🔒 relay cert SHA-256 指纹（**生产环境强烈建议**）"
  echo "   不传：跳过 cert 校验（自签 cert 场景能跑但不安全）"
  echo "   传：严格匹配 cert 指纹，relay cert 变了会立刻报错"
  echo "   怎么拿指纹：在 relay 机器上跑 'openssl x509 -in /opt/server-monitor/relay.crt -noout -fingerprint -sha256'"
  require_interactive
  prompt_line "relay cert 指纹（64 字符 hex，留空跳过）" RELAY_CERT_FP ""
fi

# ===== push 间隔 =====
if [[ -z "$PUSH_INTERVAL" ]]; then
  echo ""
  echo "⏱  push 间隔（默认 5s，跟 app 轮询周期对齐）"
  require_interactive
  prompt_line "push 间隔（秒）" PUSH_INTERVAL "5"
fi

# ===== 准备安装 =====
echo ""
echo "📦 安装预览："
echo "   版本:        $VERSION"
echo "   relay URL:   $RELAY_URL"
echo "   agent 名字:  $AGENT_NAME"
echo "   token:       ${RELAY_TOKEN:0:8}...（前 8 位）"
echo "   3x-ui db:    ${XUI_DB_PATH:-（跳过）}"
echo "   push 间隔:   ${PUSH_INTERVAL}s"
echo "   cert 指纹:   ${RELAY_CERT_FP:0:32}...（${#RELAY_CERT_FP} 字符）"
echo "   二进制:      $BIN_DIR/reverse-agent"
echo "   env:         $ENV_FILE"
echo ""
require_interactive
if ! prompt_yesno "确认安装？" "y"; then
  echo "❌ 已取消"
  exit 1
fi

# ===== 下载 binary =====
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) GOARCH="amd64" ;;
  aarch64|arm64) GOARCH="arm64" ;;
  *) echo "❌ 不支持的架构: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$BIN_DIR"

if [[ -n "$BINARY_PATH" ]]; then
  if [[ ! -f "$BINARY_PATH" ]]; then
    echo "❌ --binary 指定的文件不存在: $BINARY_PATH" >&2
    exit 1
  fi
  echo "📦 使用本地 binary: $BINARY_PATH"
  cp "$BINARY_PATH" "$BIN_DIR/reverse-agent"
else
  echo "📥 下载 reverse-agent-$VERSION-linux-$GOARCH ..."
  URL="https://github.com/$REPO/releases/download/$VERSION/reverse-agent-linux-$GOARCH"
  if ! curl -fsSL --connect-timeout 8 -m 120 -o "$BIN_DIR/reverse-agent" "$URL"; then
    echo ""
    echo "❌ 下载失败：$URL" >&2
    echo "💡 国内/墙内解决：在能翻墙的机器上下载 + scp 过来：" >&2
    echo "   scp -P <port> reverse-agent-linux-$GOARCH root@<server>:/tmp/reverse-agent" >&2
    echo "   然后重跑加 --binary /tmp/reverse-agent" >&2
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
RELAY_CERT_FP=$RELAY_CERT_FP
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
ExecStart=$BIN_DIR/reverse-agent -relay-url "\$RELAY_URL" -token "\$RELAY_TOKEN" -name "\$AGENT_NAME" -xui-db "\$XUI_DB_PATH" -interval \$PUSH_INTERVAL -relay-cert-fp "\$RELAY_CERT_FP"
Restart=on-failure
RestartSec=10s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable server-monitor-reverse-agent.service

# 杀老进程
if systemctl is-active --quiet server-monitor-reverse-agent.service 2>/dev/null; then
  echo "🛑 停止已有 reverse-agent"
  systemctl stop server-monitor-reverse-agent.service || true
fi
sleep 1
systemctl start server-monitor-reverse-agent.service

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

════════════════════════════════════════════
EOF
