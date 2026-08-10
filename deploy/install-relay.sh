#!/usr/bin/env bash
# 星黎监控 relay 一键部署脚本（v2.4.25+）
#
# 装在**有公网 IP 的服务器**上（usvps / mzhhua / 其他 VPS）。
# 内网 reverse-agent 会主动 push 数据给这台机器，app 也从这里拉数据。
#
# 一行命令（interactive 引导填参数）：
#   curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-relay.sh | sudo bash
#
# 自动化（跳过交互，所有 flag 必填）：
#   sudo bash install-relay.sh --version v2.4.24 --port 9200 \
#     --tokens "tok-a,tok-b" --external-host usvps.mzhhua.cn
#
# 墙内/无 github：先在能翻墙的机器上下载 relay-server-linux-amd64（arm64），
# scp 过去后用 --binary 跳过下载。

set -euo pipefail

# 避免某些 UTF-8 locale 下 bash 解析中文字符串 + set -u 时报 "unbound variable"
# 误报（echo "🔍 xxx: $VAR（中文括号" 这种会触发）。C.UTF-8 既支持中文又稳。
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"

REPO="mzhscan/monitor-status"
VERSION=""
PORT=""
TOKENS=""
ADD_TOKENS=""           # 追加 token（不替换现有）
EXTERNAL_HOST=""
EXTERNAL_IP=""
BINARY_PATH=""
AUTO_FIREWALL=""

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
    --add-token)     ADD_TOKENS="${ADD_TOKENS:+${ADD_TOKENS},}$2"; shift 2 ;;
    --external-host) EXTERNAL_HOST="$2"; shift 2 ;;
    --external-ip)   EXTERNAL_IP="$2"; shift 2 ;;
    --binary)        BINARY_PATH="$2"; shift 2 ;;
    --firewall)      AUTO_FIREWALL="y"; shift ;;
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
    echo "💡 你大概是用 'curl | sudo bash' 跑的——这种跑法 read 会从脚本" >&2
    echo "   本身读数据，必须传 --version / --port / --tokens 参数。" >&2
    echo "" >&2
    echo "   正确用法（任选其一）：" >&2
    echo "   1) 先下载脚本再跑：" >&2
    echo "      curl -fsSL https://raw.githubusercontent.com/mzhscan/monitor-status/main/deploy/install-relay.sh -o /tmp/install-relay.sh" >&2
    echo "      sudo bash /tmp/install-relay.sh" >&2
    echo "" >&2
    echo "   2) 全部用 --flags 覆盖（适合自动化）：" >&2
    echo "      curl -fsSL ... | sudo bash -s -- --version v2.4.24 --port 9200 --tokens 'tok-a,tok-b' --external-host usvps.mzhhua.cn" >&2
    echo "   3) 追加 token：sudo bash install-relay.sh --add-token '新token1,新token2'" >&2
    exit 1
  fi
}

# ===== add-token 模式（必须在所有变量解析 + interactive 引导之前）=====
# 只传 --add-token 走"追加 token"分支：跳过下载 / 写 systemd / 改 cert，
# 只追加 env 里的 RELAY_TOKENS= 然后 restart。
# 保留所有现有 token、cert、binary、systemd unit、已经 push 的内存数据。
if [[ -n "$ADD_TOKENS" && -z "$VERSION" && -z "$PORT" && -z "$TOKENS" && -z "$BINARY_PATH" && -z "$AUTO_FIREWALL" && -z "$EXTERNAL_HOST" && -z "$EXTERNAL_IP" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ $ENV_FILE 不存在，请先跑完整 install 流程装 relay" >&2
    exit 1
  fi
  EXISTING_TOKENS=$(grep -E '^RELAY_TOKENS=' "$ENV_FILE" | sed -E 's/^RELAY_TOKENS=//')
  if [[ -z "$EXISTING_TOKENS" ]]; then
    echo "❌ $ENV_FILE 里没找到 RELAY_TOKENS=，文件可能坏了" >&2
    exit 1
  fi
  # 拼接 + 去重（保留出现顺序）
  COMBINED=$(printf '%s,%s' "$EXISTING_TOKENS" "$ADD_TOKENS" | tr ',' '\n' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//')
  echo ""
  echo "🔑 追加 token 模式（不重装 relay，只改 env + restart）"
  echo "   现有 token 数: $(echo "$EXISTING_TOKENS" | tr ',' '\n' | wc -l | tr -d ' ')"
  echo "   要追加: $(echo "$ADD_TOKENS" | tr ',' '\n' | wc -l | tr -d ' ') 个"
  echo ""
  echo "   追加的 token（**保存好**）："
  echo "$ADD_TOKENS" | tr ',' '\n' | awk '{printf "     %2d. %s\n", NR, $0}'
  echo ""
  require_interactive
  if ! prompt_yesno "确认追加？" "y"; then
    echo "❌ 已取消"
    exit 1
  fi
  # 改 env file（只改 RELAY_TOKENS= 那一行）
  if grep -q '^RELAY_TOKENS=' "$ENV_FILE"; then
    sed -i.bak -E "s|^RELAY_TOKENS=.*|RELAY_TOKENS=$COMBINED|" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
  else
    echo "RELAY_TOKENS=$COMBINED" >> "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
  # 重启 relay（保留 cert / binary / systemd unit / 已经 push 的数据）
  if systemctl is-active --quiet server-monitor-relay.service 2>/dev/null; then
    echo "🔄 重启 relay..."
    systemctl restart server-monitor-relay.service
    sleep 2
    if systemctl is-active --quiet server-monitor-relay.service; then
      echo "✅ relay 重启成功"
    else
      echo "❌ 重启失败，看日志：journalctl -u server-monitor-relay -n 50" >&2
      exit 1
    fi
  else
    echo "⚠️  relay 没在跑（不会自动启动），手动跑：sudo systemctl start server-monitor-relay" >&2
  fi
  cat <<EOF

════════════════════════════════════════════
✅ token 追加完成
════════════════════════════════════════════
env 文件:  $ENV_FILE
当前白名单 token 数: $(echo "$COMBINED" | tr ',' '\n' | wc -l | tr -d ' ')

新增的 token 列表：
$(echo "$ADD_TOKENS" | tr ',' '\n' | awk '{printf "  %2d. %s\n", NR, $0}')

下一步：在新加的内网机器上跑 install-reverse-agent.sh，token 用上面新加的。
════════════════════════════════════════════
EOF
  exit 0
fi

# ===== 自动探测本机公网 IP（用于 cert SAN，仅在用户没传 --external-ip 时用）=====
DETECTED_IP=""
if [[ -z "$EXTERNAL_IP" && -z "$EXTERNAL_HOST" ]]; then
  DETECTED_IP=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
fi

# ===== Welcome =====
echo ""
echo "╔════════════════════════════════════════════╗"
echo "║   星黎监控 relay 安装向导                  ║"
echo "║   （让内网 reverse-agent 推送数据 + app 拉）║"
echo "╚════════════════════════════════════════════╝"
echo ""

# ===== 版本 =====
if [[ -z "$VERSION" ]]; then
  if [[ -n "$DETECTED_IP" ]]; then
    # 用 printf 避免 bash 在 set -u 下把 "$VAR<中文括号" 误解析为长变量名
    printf "🔍 本机公网 IP: %s（用于 cert SAN，可填也可填域名替代）\n\n" "$DETECTED_IP"
  fi
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

# ===== 端口 =====
if [[ -z "$PORT" ]]; then
  require_interactive
  prompt_line "监听端口（避开 9009/9101 等已有端口，9200 推荐）" PORT "9200"
fi

# ===== token 列表 =====
if [[ -z "$TOKENS" ]]; then
  require_interactive
  echo ""
  echo "🔑 token 配置：每台内网 reverse-agent 一个独立 token"
  echo "   选 1：脚本自动生成 N 个（推荐）"
  echo "   选 2：自己粘贴（逗号分隔）"
  echo ""
  prompt_line "选择" TOKEN_CHOICE "1"
  if [[ "$TOKEN_CHOICE" == "1" ]]; then
    prompt_line "要监控几台内网机器？" N "1"
    N=${N:-1}
    echo "🔐 正在生成 $N 个 token..."
    GENERATED=""
    for i in $(seq 1 "$N"); do
      T=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 32)
      GENERATED="$GENERATED,$T"
    done
    TOKENS="${GENERATED#,}"
    echo ""
    echo "   自动生成的 token（**保存好**，稍后也会写进 /opt/server-monitor/relay.env）："
    echo "$TOKENS" | tr ',' '\n' | awk '{printf "     %2d. %s\n", NR, $0}'
    echo ""
    if ! prompt_yesno "这些 token 你保存了吗？" "n"; then
      echo "   请截图或复制保存后再继续。"
      prompt_line "按回车继续" _
    fi
  else
    while [[ -z "$TOKENS" ]]; do
      prompt_line "token 列表（逗号分隔）" TOKENS
    done
  fi
fi

# ===== cert SAN =====
if [[ -z "$EXTERNAL_HOST" && -z "$EXTERNAL_IP" ]]; then
  if [[ -n "$DETECTED_IP" ]]; then
    DEFAULT_SAN_HINT="留空用 IP $DETECTED_IP，或填域名（如 usvps.mzhhua.cn）"
  else
    DEFAULT_SAN_HINT="必须填一个（公网域名或 IP，否则 app 报 hostname mismatch）"
  fi
  echo ""
  echo "📜 cert SAN 域名 / IP（app 连 relay 时用，要让 cert 验证通过）"
  echo "   $DEFAULT_SAN_HINT"
  require_interactive
  prompt_line "域名（多个用逗号，留空跳过）" EXTERNAL_HOST ""
  if [[ -z "$EXTERNAL_HOST" ]]; then
    if [[ -n "$DETECTED_IP" ]]; then
      EXTERNAL_IP="$DETECTED_IP"
    else
      prompt_line "公网 IP（多个用逗号）" EXTERNAL_IP ""
    fi
  fi
fi

# ===== 防火墙 =====
if [[ -z "$AUTO_FIREWALL" ]]; then
  echo ""
  echo "🔥 防火墙（自动放行 $PORT/tcp）"
  if command -v ufw >/dev/null 2>&1; then
    FW="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    FW="firewalld"
  else
    FW="none（手动配）"
  fi
  echo "   检测到: $FW"
  require_interactive
  if prompt_yesno "是否自动放行 $PORT/tcp？" "y"; then
    AUTO_FIREWALL="y"
  fi
fi

# ===== 准备安装 =====
echo ""
echo "📦 安装预览："
echo "   版本:     $VERSION"
echo "   端口:     $PORT"
echo "   token:    $(echo "$TOKENS" | tr ',' '\n' | wc -l | tr -d ' ') 个"
echo "   cert SAN: host=$EXTERNAL_HOST ip=$EXTERNAL_IP"
echo "   二进制:   $BIN_DIR/relay-server"
echo "   env:      $ENV_FILE"
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
  cp "$BINARY_PATH" "$BIN_DIR/relay-server"
else
  echo "📥 下载 relay-server-$VERSION-linux-$GOARCH ..."
  URL="https://github.com/$REPO/releases/download/$VERSION/relay-server-linux-$GOARCH"
  if ! curl -fsSL --connect-timeout 8 -m 120 -o "$BIN_DIR/relay-server" "$URL"; then
    echo ""
    echo "❌ 下载失败：$URL" >&2
    echo "💡 国内/墙内解决：在能翻墙的机器上下载 + scp 过来：" >&2
    echo "   scp -P <port> relay-server-linux-$GOARCH root@<server>:/tmp/relay-server" >&2
    echo "   然后重跑加 --binary /tmp/relay-server" >&2
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

# ===== 自检：env 必须写成功 + 关键变量不能空 =====
if [[ ! -s "$ENV_FILE" ]]; then
  echo "❌ env 写入失败: $ENV_FILE 不存在或为空" >&2
  echo "   检查 /opt/server-monitor/ 目录权限 + 磁盘空间" >&2
  exit 1
fi
for _k in RELAY_PORT RELAY_TOKENS; do
  if ! grep -q "^${_k}=" "$ENV_FILE"; then
    echo "❌ env 缺少关键变量: $_k" >&2
    exit 1
  fi
done
echo "📝 env 自检通过"
echo "   env 内容（token 已脱敏）:"
sed -E 's/^(RELAY_TOKENS=).*/\1***redacted***/; s/^/   /' "$ENV_FILE"

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
# 5 分钟内连挂 5 次就放弃，避免坏配置（如 token 拼错、cert 路径错）导致
# 日志被 3000+ 次重启信息塞满、用户根本没机会看到真正的错误。
StartLimitBurst=5
StartLimitIntervalSec=120s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable server-monitor-relay.service

# 杀老进程
if systemctl is-active --quiet server-monitor-relay.service 2>/dev/null; then
  echo "🛑 停止已有 relay"
  systemctl stop server-monitor-relay.service || true
fi
sleep 1
systemctl start server-monitor-relay.service

# ===== 健康检查：等到 SubState=running 或超时 =====
echo "⏳ 等待 relay 进入 running 状态..."
SUB_STATE=""
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  SUB_STATE=$(systemctl show -p SubState --value server-monitor-relay.service 2>/dev/null || echo "unknown")
  [[ "$SUB_STATE" == "running" ]] && break
  sleep 1
done

if [[ "$SUB_STATE" == "running" ]]; then
  echo "✅ relay 启动成功 (SubState=running)"
else
  ACTIVE_STATE=$(systemctl show -p ActiveState --value server-monitor-relay.service 2>/dev/null || echo "unknown")
  echo "❌ relay 启动失败：SubState=$SUB_STATE ActiveState=$ACTIVE_STATE" >&2
  echo "" >&2
  echo "=== 最近 30 行 journal 日志 ===" >&2
  journalctl -u server-monitor-relay -n 30 --no-pager >&2 || true
  echo "==============================" >&2
  echo "" >&2
  echo "💡 常见原因：" >&2
  echo "   1) 端口 $PORT 已被占用（lsof -i:$PORT 看谁在用）" >&2
  echo "   2) env 里 RELAY_TOKENS 拼写错 / 包含非法字符" >&2
  echo "   3) cert 路径不存在 / 权限不对" >&2
  exit 1
fi

# ===== 防火墙 =====
if [[ "$AUTO_FIREWALL" == "y" ]]; then
  if command -v ufw >/dev/null 2>&1; then
    echo "🔥 ufw 放行 $PORT/tcp"
    ufw allow "$PORT/tcp" || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    echo "🔥 firewalld 放行 $PORT/tcp"
    firewall-cmd --permanent --add-port="$PORT/tcp" || true
    firewall-cmd --reload || true
  fi
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

token 列表（每行一个，对应一台内网机器）:
$(echo "$TOKENS" | tr ',' '\n' | awk '{printf "  %2d. %s\n", NR, $0}')

验证（看到 active_servers=0 是正常的，还没装 reverse-agent）：
  curl -sk https://<你的域名/IP>:$PORT/health

════════════════════════════════════════════
下一步：在每台内网机器跑 install-reverse-agent.sh（脚本会引导填
relay URL / token / name），然后 app 端加 server。

════════════════════════════════════════════
EOF
