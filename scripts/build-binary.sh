#!/usr/bin/env bash
# 构建无需 Docker 的 Linux 静态二进制（前端已嵌入）。
#
# 背景：源码仓库里 web/dist 只有 .gitkeep 占位符，直接 go build 出来的二进制
# **不含前端界面**（只能提供 API）。必须先把前端 build 产物放进 web/dist，
# 再 go build，才能得到含 UI 的单文件。
#
# 用法：
#   ./scripts/build-binary.sh                 # 默认 linux/amd64
#   ARCH=arm64 ./scripts/build-binary.sh      # linux/arm64
#   ARCH=both  ./scripts/build-binary.sh      # 两个架构都出
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCH="${ARCH:-amd64}"
OUTDIR="${OUTDIR:-dist-bin}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

for t in go node; do
  command -v "$t" >/dev/null 2>&1 || die "缺少 $t，请先安装"
done

# ---------- 1. 构建前端 ----------
say "构建前端 (frontend → web/dist)"
pushd frontend >/dev/null
if command -v pnpm >/dev/null 2>&1; then
  pnpm install --no-frozen-lockfile
  pnpm build
else
  echo "未找到 pnpm，回退到 npm"
  npm install
  npm run build
fi
popd >/dev/null

FRONTEND_DIST="$ROOT/frontend/dist"
[[ -f "$FRONTEND_DIST/index.html" ]] || die "前端构建产物缺失：$FRONTEND_DIST/index.html 不存在"

# ---------- 2. 放入 web/dist 供 go:embed 嵌入 ----------
say "写入 web/dist（供 //go:embed 嵌入）"
rm -rf web/dist
mkdir -p web/dist
cp -R "$FRONTEND_DIST/." web/dist/
[[ -f web/dist/index.html ]] || die "拷贝后 web/dist/index.html 仍不存在"

# ---------- 3. 交叉编译 ----------
mkdir -p "$OUTDIR"
build_one() {
  local arch="$1"
  local out="$OUTDIR/flow-router-linux-${arch}"
  say "编译 linux/${arch} → $out"
  # CGO 必须关闭：SQLite 用的是纯 Go 驱动 (glebarez/sqlite)，可产出完全静态二进制
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go build -trimpath -ldflags="-s -w" -o "$out" ./cmd/server
  ls -lh "$out"
  file "$out"
}

case "$ARCH" in
  both) build_one amd64; build_one arm64 ;;
  amd64|arm64) build_one "$ARCH" ;;
  *) die "不支持的 ARCH=$ARCH（可选 amd64 / arm64 / both）" ;;
esac

cat <<EOF

✔ 构建完成，产物在 $OUTDIR/

上传到服务器后运行：
  scp $OUTDIR/flow-router-linux-amd64 user@server:/opt/flow-router/flow-router
  ssh user@server
  mkdir -p /opt/flow-router/data
  cd /opt/flow-router
  # 首次运行会自动生成 config.yaml，之后用环境变量配置：
  APP_SECRET='<32字节以上随机串>' AUTH_ENABLED=true ADMIN_PASSWORD='<强密码>' \\
    ./flow-router -config ./data/config.yaml

建议用 systemd 托管（崩溃自动重启 + 开机自启），可参考仓库 README 的部署说明。
EOF
