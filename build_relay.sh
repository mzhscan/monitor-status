#!/usr/bin/env bash
# Build relay-server + reverse-agent 二进制（arm64 + amd64）
#
# Usage:
#   ./build_relay.sh
#
# Outputs (in dist/):
#   - relay-server-linux-amd64
#   - relay-server-linux-arm64
#   - reverse-agent-linux-amd64
#   - reverse-agent-linux-arm64
#
# 然后 ./build_apk.sh 会自动把这 4 个新 binary 加到 SHA256SUMS。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
mkdir -p "$DIST_DIR"

# Go path（跟 build_apk.sh 一样要 source flutter env，主要是为了 PATH）
source "$HOME/.flutter_env.sh" 2>/dev/null || true
export PATH="$HOME/development/go/bin:$PATH"

LDFLAGS="-s -w"
CGO=0
PLATFORMS=("amd64" "arm64")
COMMANDS=("relay-server" "reverse-agent")

echo "==> 准备构建"
for cmd in "${COMMANDS[@]}"; do
  for plat in "${PLATFORMS[@]}"; do
    out="$DIST_DIR/${cmd}-linux-${plat}"
    echo "    -> $out"
    CGO_ENABLED=$CGO GOOS=linux GOARCH=$plat \
      go build -ldflags "$LDFLAGS" -o "$out" "./cmd/${cmd}"
  done
done

echo
echo "==> 完成的 binary:"
ls -lh "$DIST_DIR" | grep -E "relay|reverse-agent"
echo
echo "==> 下一步：跑 ./build_apk.sh 重新生成 SHA256SUMS（会把这 4 个新 binary 加进去）"
