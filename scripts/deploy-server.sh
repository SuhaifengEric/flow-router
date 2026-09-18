#!/usr/bin/env bash
# Flow Router / UpstreamOps 服务器部署脚本
#
# 设计原则：
#   1. 幂等 —— 可重复执行，不会破坏已有数据
#   2. 绝不覆盖已有 .env —— 换掉 APP_SECRET 会让库中已加密的密文永久解不开
#   3. 默认安全 —— 默认开启鉴权（AUTH_ENABLED=true），公网暴露是默认场景
#
# 用法：
#   ./deploy-server.sh                     # 交互式，默认开启鉴权
#   HTTP_PORT=8090 ./deploy-server.sh      # 指定端口
#   AUTH_ENABLED=false ./deploy-server.sh  # 仅在纯内网/本机时这样用
#
set -euo pipefail

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. 必须在项目根目录运行 ----------
[[ -f "$COMPOSE_FILE" ]] || die "未找到 $COMPOSE_FILE，请在项目根目录运行本脚本"

# ---------- 1. 预检：Docker ----------
say "检查 Docker 环境"
if ! command -v docker >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[x] 未检测到 Docker。

方案 A —— 安装 Docker（推荐，镜像已预构建，无需编译）：
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
  然后重新运行本脚本。

方案 B —— 不用 Docker，改用静态二进制：
    在本机执行 scripts/build-binary.sh 产出 linux 二进制，
    上传到服务器后直接运行（需自行提供 config.yaml 与目录）。
    详见 README「本地开发」一节。
EOF
  exit 1
fi
docker info >/dev/null 2>&1 || die "Docker 已安装但守护进程不可用，请先启动：systemctl start docker"

# 兼容 docker compose (v2 插件) 与 docker-compose (v1 独立命令)
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "未找到 docker compose，请安装 docker-compose-plugin"
fi
say "使用：$DC"

# ---------- 2. 生成 / 复用 .env ----------
HTTP_PORT="${HTTP_PORT:-8080}"
AUTH_ENABLED="${AUTH_ENABLED:-true}"

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '\n'
  else
    head -c 48 /dev/urandom | base64 | tr -d '\n'
  fi
}

if [[ -f "$ENV_FILE" ]]; then
  warn "$ENV_FILE 已存在 —— 保留不覆盖（保护已加密数据）"
  # 读出现有 APP_SECRET 以做检查
  EXISTING_SECRET="$(grep -E '^APP_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  if [[ -z "$EXISTING_SECRET" || "$EXISTING_SECRET" == please-change-me* ]]; then
    die "$ENV_FILE 中的 APP_SECRET 为空或仍是示例值，请手动设置一个 32 字节以上的随机串。
    注意：如库中已有数据，改动 APP_SECRET 会导致这些数据无法解密。"
  fi
  say "复用现有 APP_SECRET（长度 ${#EXISTING_SECRET}）"
else
  say "生成 .env"

  if [[ "$AUTH_ENABLED" == "true" ]]; then
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
      # 非交互式环境（如 CI）下不阻塞，直接报错要求显式提供
      if [[ -t 0 ]]; then
        read -rsp "请设置后台管理员密码（ADMIN_PASSWORD）: " ADMIN_PASSWORD
        echo
      fi
    fi
    # 与后端行为一致：AUTH_ENABLED=true 但密码缺失时进程会 os.Exit(1)
    [[ -n "$ADMIN_PASSWORD" ]] || die "AUTH_ENABLED=true 必须提供 ADMIN_PASSWORD。
    或显式关闭鉴权（仅限纯内网）：AUTH_ENABLED=false ./deploy-server.sh"
    [[ ${#ADMIN_PASSWORD} -ge 12 ]] || warn "密码长度不足 12 位，公网环境建议加长"
  fi

  APP_SECRET="$(gen_secret)"

  cat > "$ENV_FILE" <<EOF
# 由 scripts/deploy-server.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 【重要】APP_SECRET 必须长期固定并妥善备份；改动后库中既有密文将无法解密。

HTTP_PORT=${HTTP_PORT}
IMAGE_TAG=${IMAGE_TAG:-latest}
SERVER_MODE=release
LOG_LEVEL=info

DATABASE_DRIVER=sqlite
DATABASE_PATH=/app/data/upstream-ops.db

APP_SECRET=${APP_SECRET}

AUTH_ENABLED=${AUTH_ENABLED}
ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-}
AUTH_TOKEN_SECRET=
EOF

  chmod 600 "$ENV_FILE"
  say ".env 已生成（权限 600）"
fi

# ---------- 3. 端口占用检查 ----------
PORT_IN_USE="$(grep -E '^HTTP_PORT=' "$ENV_FILE" | head -1 | cut -d= -f2- || echo "$HTTP_PORT")"
PORT_IN_USE="${PORT_IN_USE:-8080}"
if command -v ss >/dev/null 2>&1; then
  if ss -lntp 2>/dev/null | grep -q ":${PORT_IN_USE} "; then
    # 若占用者就是本项目已运行的容器，则属正常（重复执行场景）
    if ! $DC ps 2>/dev/null | grep -q "${PORT_IN_USE}->"; then
      warn "端口 ${PORT_IN_USE} 已被其他进程占用。"
      warn "查看占用者：ss -lntp | grep ':${PORT_IN_USE} '"
      warn "改用其他端口：HTTP_PORT=8090 ./deploy-server.sh（需先删除 .env 中的 HTTP_PORT 行）"
      die "请先解决端口冲突"
    fi
  fi
fi

# ---------- 4. 拉取镜像并启动 ----------
say "拉取镜像"
$DC pull 2>/dev/null || warn "拉取失败（可能网络受限），将尝试使用本地已有镜像"

say "启动服务"
$DC up -d

# ---------- 5. 健康检查 ----------
say "等待健康检查"
HEALTHY=false
for i in $(seq 1 30); do
  sleep 2
  if curl -fsS --max-time 3 "http://127.0.0.1:${PORT_IN_USE}/healthz" >/dev/null 2>&1; then
    HEALTHY=true
    break
  fi
  if ! $DC ps --status running 2>/dev/null | grep -q .; then
    break
  fi
done

if [[ "$HEALTHY" != "true" ]]; then
  warn "健康检查未通过，最近日志："
  $DC logs --tail=40
  die "启动失败，请检查上面日志"
fi

# ---------- 6. 汇总 ----------
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<服务器IP>')"
cat <<EOF

\033[1;32m✔ 部署完成\033[0m

  访问地址   http://${PUBLIC_IP}:${PORT_IN_USE}
  健康检查   http://${PUBLIC_IP}:${PORT_IN_USE}/healthz  -> {"status":"ok"}
  数据目录   ./data/  (SQLite 库 + config.yaml)

  鉴权状态   AUTH_ENABLED=$(grep -E '^AUTH_ENABLED=' "$ENV_FILE" | cut -d= -f2-)
EOF

if grep -qE '^AUTH_ENABLED=true' "$ENV_FILE"; then
  echo "           账号 $(grep -E '^ADMIN_USERNAME=' "$ENV_FILE" | cut -d= -f2-)（密码见 .env）"
  echo
  echo "  提醒：网关用 Bearer / x-api-key 收客户端密钥，公网务必配 HTTPS 反代后再接入流量。"
else
  warn "鉴权已关闭 —— /api/* 对任何能访问该端口的人完全开放，含充值/兑换等操作接口。"
  warn "仅限纯本机或受信内网使用。"
fi

cat <<'EOF'

  常用命令
    docker compose logs -f      # 跟日志
    docker compose restart      # 重启
    docker compose down         # 停止（data/ 保留）
    docker compose up -d        # 升级：先 docker compose pull

EOF
