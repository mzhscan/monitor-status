#!/usr/bin/env bash
# 星黎监控 agent 一键部署脚本（中文 interactive + flag 覆盖）
#
# 一行命令（最新版，--version latest 自动解析 GitHub 最新 release）：
#   curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-agent.sh | \
#     sudo bash -s -- --version latest
# 例（v2.2.0）：
#   curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-agent.sh | \
#     sudo bash -s -- --version v2.2.0
#
# 墙内 / server 访问不到 github.com 时：
#   1) 在能翻墙的机器上下载 agent-linux-amd64（或 arm64）
#   2) scp 过去：scp agent-linux-amd64 root@server:/tmp/agent
#   3) 加 --binary 跳过 GitHub 下载：
#      sudo bash install-agent.sh --version latest --binary /tmp/agent
#
# Optional flags (覆盖 interactive 输入):
#   --version VER    GitHub release 版本，可写 "latest" 自动解析最新
#                    (e.g. v2.0.0, latest)
#   --name NAME      agent 名字 (e.g. "us-vps")
#   --token TOKEN    agent 共享密钥
#   --port PORT      监听端口 (默认 9101)
#   --cert PATH      显式证书路径 (trim 自动 / 3x-ui cert / 自签 都可)
#   --key PATH       显式私钥路径
#   --binary PATH    本地已下载的 agent binary（跳过 GitHub 下载，墙内用户用）
#   --no-tls         不启 HTTPS（不推荐）

set -euo pipefail

REPO="mzhscan/monitor-status"
VERSION=""
NAME=""
TOKEN=""
PORT="9101"
CERT_FILE=""
KEY_FILE=""
BINARY_PATH=""
USE_TLS=1

# ===== 参数解析 =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --name)    NAME="$2"; shift 2 ;;
    --token)   TOKEN="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --cert)    CERT_FILE="$2"; shift 2 ;;
    --key)     KEY_FILE="$2"; shift 2 ;;
    --binary)  BINARY_PATH="$2"; shift 2 ;;
    --no-tls)  USE_TLS=0; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "❌ 缺少 --version (例如 v2.0.0 或 latest)" >&2
  exit 1
fi

DATA_DIR="/opt/server-monitor"
BIN_DIR="$DATA_DIR/bin"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# ===== 架构检测 =====
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) GOARCH=amd64 ;;
  aarch64|arm64) GOARCH=arm64 ;;
  *) echo "❌ 不支持的架构: $ARCH" >&2; exit 1 ;;
esac

# ===== --version latest 解析 =====
# 走 GitHub API 查最新 release tag，替换 VERSION。
# 仅在 --version 显式传 "latest" 时才查；具体版本 (v2.0.0) 不查。
# 失败时给清晰提示：要么写死版本号，要么用 --binary 跳下载。
if [[ "$VERSION" == "latest" ]]; then
  echo "🔍 正在查询 GitHub 最新 release..."
  LATEST_TAG=$(curl -fsSL --connect-timeout 8 -m 30 \
    "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | grep -oE '"tag_name":[[:space:]]*"[^"]+"' \
    | head -1 \
    | sed -E 's/.*"([^"]+)".*/\1/')
  if [[ -z "$LATEST_TAG" ]]; then
    echo "" >&2
    echo "❌ 无法从 GitHub 解析 latest 版本" >&2
    echo "💡 两种解决方法：" >&2
    echo "   1) 显式指定版本号：" >&2
    echo "      sudo bash install-agent.sh --version vX.Y.Z --name <n> --token <t>" >&2
    echo "   2) 跳过 GitHub 下载，先本地传 binary：" >&2
    echo "      scp agent-linux-${GOARCH} root@<server>:/tmp/agent" >&2
    echo "      sudo bash install-agent.sh --version latest --binary /tmp/agent" >&2
    exit 1
  fi
  echo "✅ 解析到最新版本: $LATEST_TAG"
  VERSION="$LATEST_TAG"
fi

URL="https://github.com/${REPO}/releases/download/${VERSION}/agent-linux-${GOARCH}"

# ===== 下载 / 取本地 binary =====
if [[ -n "$BINARY_PATH" ]]; then
  if [[ ! -f "$BINARY_PATH" ]]; then
    echo "❌ --binary 指定的文件不存在: $BINARY_PATH" >&2
    exit 1
  fi
  echo "📦 使用本地 binary: $BINARY_PATH"
  cp "$BINARY_PATH" "$TMP/agent"
  chmod +x "$TMP/agent"
else
  echo "📥 正在下载 $URL"
  if ! curl -fsSL --connect-timeout 8 -m 60 -o "$TMP/agent" "$URL"; then
    echo ""
    echo "❌ 下载失败（服务器可能访问不到 github.com）" >&2
    echo "" >&2
    echo "💡 国内/墙内解决方法：在能翻墙的机器上先下载好，再 scp 过来：" >&2
    echo "   # 在你本地 Mac 执行：" >&2
    echo "   curl -fsSL -O '$URL'" >&2
    echo "   scp -P <port> <binary> root@<server>:/tmp/agent" >&2
    echo "" >&2
    echo "   # 然后在 server 上重新跑本脚本，加 --binary 参数：" >&2
    echo "   sudo bash install-agent.sh --version $VERSION --name <name> --token <token> --binary /tmp/agent" >&2
    exit 1
  fi
  chmod +x "$TMP/agent"
fi

# ===== interactive 输入 =====
echo ""
echo "╔════════════════════════════════════════════╗"
echo "║   星黎监控 agent 安装向导                   ║"
echo "╚════════════════════════════════════════════╝"
echo ""

# ===== TTY 检测 + prompt 工具 =====
# curl | bash 这种跑法，stdin 被脚本本身占了，read 会读脚本下一行当输入。
# 这里统一从 /dev/tty 读写（如果有），没有就直接报错要求用户用 --flags。
if [[ -e /dev/tty ]]; then
  # 用 < 同时开读写（read 也要用这个 fd）
  exec 3<>/dev/tty
  PROMPT_FD=3
else
  PROMPT_FD=0
fi

prompt_line() {
  local prompt="$1"
  local varname="$2"
  local default="${3:-}"
  local line
  if [[ -n "$default" ]]; then
    printf "%s [%s]: " "$prompt" "$default" >&"$PROMPT_FD"
  else
    printf "%s: " "$prompt" >&"$PROMPT_FD"
  fi
  IFS= read -r line <&"$PROMPT_FD" || line=""
  if [[ -z "$line" && -n "$default" ]]; then
    line="$default"
  fi
  printf -v "$varname" '%s' "$line"
}

require_interactive() {
  if [[ ! -e /dev/tty ]]; then
    echo "" >&2
    echo "❌ 需要 interactive 输入，但检测不到 /dev/tty" >&2
    echo "" >&2
    echo "💡 你大概是用 'curl | sudo bash' 跑的——这种跑法 read 会从脚本" >&2
    echo "   本身读数据，必须传 --name / --token / --port 参数。" >&2
    echo "" >&2
    echo "   正确用法（任选其一）：" >&2
    echo "   1) 先下载脚本再跑：" >&2
    echo "      curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-agent.sh -o /tmp/install-agent.sh" >&2
    echo "      sudo bash /tmp/install-agent.sh --version v2.0.0 --name <name> --token <token>" >&2
    echo "" >&2
    echo "   2) 全部用 --flags 覆盖（适合自动化）：" >&2
    echo "      curl -fsSL ... | sudo bash -s -- --version v2.0.0 --name <n> --token <t> --port 9101" >&2
    exit 1
  fi
}

# agent 名字
if [[ -z "$NAME" ]]; then
  DEFAULT_NAME=$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
  require_interactive
  prompt_line "agent 名字（用于 app 显示）" NAME "$DEFAULT_NAME"
fi

# agent token
if [[ -z "$TOKEN" ]]; then
  require_interactive
  while [[ -z "$TOKEN" ]]; do
    prompt_line "agent Token（app 端连过来时用，自己设一个强密码）" TOKEN
  done
fi

# 端口
if [[ -z "$PORT" || "$PORT" == "9101" ]] && [[ "${1:-}" != "--port" ]]; then
  require_interactive
  prompt_line "监听端口" PORT "9101"
fi

# ===== HTTPS 证书来源 =====
echo ""
echo "📜 HTTPS 证书（选 1/2/3）："
echo "   1) 自动检测（trim OS / 3x-ui cert / 自签）  [推荐]"
echo "   2) 我自己提供证书文件路径"
if [[ $USE_TLS -eq 1 && -z "$CERT_FILE" ]]; then
  require_interactive
  prompt_line "选择" CERT_CHOICE "1"
  if [[ "$CERT_CHOICE" == "2" ]]; then
    while [[ -z "$CERT_FILE" || ! -f "$CERT_FILE" ]]; do
      prompt_line "证书文件路径" CERT_FILE
      if [[ -n "$CERT_FILE" && ! -f "$CERT_FILE" ]]; then
        echo "❌ 文件不存在: $CERT_FILE" >&2
        CERT_FILE=""
      fi
    done
    while [[ -z "$KEY_FILE" || ! -f "$KEY_FILE" ]]; do
      prompt_line "私钥文件路径" KEY_FILE
      if [[ -n "$KEY_FILE" && ! -f "$KEY_FILE" ]]; then
        echo "❌ 文件不存在: $KEY_FILE" >&2
        KEY_FILE=""
      fi
    done
  fi
fi

# ===== 准备安装 =====
mkdir -p "$BIN_DIR" "$DATA_DIR/data"

# 杀老进程（如果 systemd unit 已存在 / 旧 binary 在跑）
echo "🛑 停止已有 agent 进程"
if systemctl is-active --quiet server-monitor-agent 2>/dev/null; then
  systemctl stop server-monitor-agent || true
fi
pkill -9 -f 'agent-[a-z0-9-]+$' 2>/dev/null || true
pkill -9 -f "$BIN_DIR/agent" 2>/dev/null || true
sleep 1
if command -v ss >/dev/null && ss -tln 2>/dev/null | grep -q ":${PORT}\b"; then
  echo "❌ 端口 $PORT 仍被占用，请手动 fuser -k ${PORT}/tcp 后重试" >&2
  exit 1
fi

# 装 binary
cp "$TMP/agent" "$BIN_DIR/agent"
chmod +x "$BIN_DIR/agent"

# 写 env file
ENV_FILE="$DATA_DIR/agent.env"
cat > "$ENV_FILE" <<EOF
AGENT_NAME=$NAME
AGENT_TOKEN=$TOKEN
AGENT_PORT=$PORT
XUI_DB_PATH=/etc/x-ui/x-ui.db
EOF
if [[ $USE_TLS -eq 1 ]]; then
  echo "USE_TLS=true" >> "$ENV_FILE"
  if [[ -n "$CERT_FILE" ]]; then
    echo "CERT_FILE=$CERT_FILE" >> "$ENV_FILE"
  fi
  if [[ -n "$KEY_FILE" ]]; then
    echo "KEY_FILE=$KEY_FILE" >> "$ENV_FILE"
  fi
fi
chmod 600 "$ENV_FILE"

# systemd unit
cat > /etc/systemd/system/server-monitor-agent.service <<EOF
[Unit]
Description=星黎监控 Agent ($NAME)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$DATA_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_DIR/agent
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable server-monitor-agent
systemctl restart server-monitor-agent

# ===== 状态 =====
sleep 2
if systemctl is-active --quiet server-monitor-agent; then
  echo ""
  echo "✅ 安装成功！"
  echo "   agent 名:    $NAME"
  echo "   监听端口:    $PORT (HTTPS)"
  echo "   env 文件:    $ENV_FILE"
  echo "   日志:         journalctl -u server-monitor-agent -f"
  echo ""
  echo "📱 app 端添加服务器："
  echo "   显示名称:    $NAME"
  if [[ $USE_TLS -eq 1 ]]; then
    # 尝试猜本机 IP
    IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<your-server-ip>")
    echo "   Agent URL:   https://${IP}:${PORT}"
    echo "   Agent Token: $TOKEN"
  fi
  echo ""
  echo "   （首次连接如果弹「信任证书」对话框，请与"
  echo "    管理员核对 SHA-256 指纹后再信任）"
else
  echo "❌ 启动失败，查看日志： journalctl -u server-monitor-agent -n 30"
  exit 1
fi
