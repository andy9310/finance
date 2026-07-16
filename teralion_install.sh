#!/usr/bin/env bash
# ============================================================================
# Teralion Trading — one-shot Linux installer
#
# 用法（在 Linux server 上，要 root 權限）:
#   1. 先把 fubon_neo Linux wheel 放到 /tmp/fubon_neo-XXX.whl
#   2. (可選) 先 rsync trading.db / 分線 CSV 到 /data/teralion/{db,csv}
#   3. chmod +x teralion_install.sh
#   4. sudo ./teralion_install.sh
#
# 這個 script 會自動處理:
#   - apt 基礎套件 + Docker + cloudflared + qrencode
#   - 建 /data/teralion 資料目錄
#   - git clone day-trade-system branch 到 /opt/teralion
#   - Python venv + pip install + fubon_neo wheel
#   - 前端 build + 串進 backend
#   - 互動式產生 .env
#   - 起 Signal docker container
#   - 註冊 backend systemd service
#
# 不會自動處理（最後會印出指令給你手動跑）:
#   - Signal 連動手機（要掃 QR）
#   - Cloudflare tunnel login + create + DNS route（要 web 登入 + 你自己的 domain）
#   - trading.db / CSV 資料搬遷
# ============================================================================

set -euo pipefail

# ── 可改參數（跑之前可以調）─────────────────────────────────
APP_DIR="${APP_DIR:-/opt/teralion}"
DATA_DIR="${DATA_DIR:-/data/teralion}"
REPO_URL="${REPO_URL:-https://github.com/TeralionTech/twse_day_trade.git}"
BRANCH="${BRANCH:-day-trade-system}"
FUBON_WHL_GLOB="${FUBON_WHL_GLOB:-/tmp/fubon_neo-*.whl}"
SERVICE_NAME="teralion-backend"

# ── 部署模式 ────────────────────────────────────────────────
#   INSTALL_MODE=git     (預設) — git clone BRANCH 明文原始碼，前端在機上 build
#                        給「自己的機器」(Kled/Yanling, day-trade-system) 用
#   INSTALL_MODE=tarball — 解壓 meta scp 上來的混淆 tarball，前端已 prebuilt
#                        給「客戶機」(混淆 saas-delivery) 用，需 LICENSE_KEY
# tarball mode 額外 env:
#   TARBALL_PATH=/root/alex-obf-xxx.tar.gz   (混淆包，內含 teralion_WEB/ + shared/)
#   LICENSE_KEY=<meta 發的 UUID>             (客戶機 license gate 必填)
#   LICENSE_SERVER_URL=https://central...    (meta license server)
INSTALL_MODE="${INSTALL_MODE:-git}"

# ── Helpers ─────────────────────────────────────────────────
C_BLUE='\033[1;36m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_OFF='\033[0m'

log()  { printf "\n${C_BLUE}[install]${C_OFF} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[warn]${C_OFF} %s\n" "$*"; }
die()  { printf "${C_RED}[error]${C_OFF} %s\n" "$*" >&2; exit 1; }
ok()   { printf "${C_GREEN}[ok]${C_OFF} %s\n" "$*"; }

# 要 root（裝 apt / Docker / systemd 都要）
[[ $EUID -eq 0 ]] || die "請用 sudo 跑這個 script"

# 抓真正登入的 user（sudo 跑時 $USER 是 root，要找原 user）
# 直接以 root 登入跑時 SUDO_USER 為空，可指定 RUN_USER 環境變數覆寫，
# 否則 fallback 到 root（VPS 上很常見的情況）。
RUN_USER="${RUN_USER:-${SUDO_USER:-root}}"
if [[ "$RUN_USER" == "root" ]]; then
    warn "以 root 身份跑（VPS 上常見）— backend 服務也會用 root 跑"
    warn "如想用其他 user：先 useradd teralion 後 RUN_USER=teralion sudo ./teralion_install.sh"
fi
RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
[[ -n "$RUN_HOME" ]] || die "找不到 user $RUN_USER 的 home dir"
log "執行身份: root（target user=$RUN_USER, home=$RUN_HOME）"

# ── Step 0: 檢查 OS ─────────────────────────────────────────
log "檢查 OS..."
[[ -f /etc/os-release ]] || die "找不到 /etc/os-release"
. /etc/os-release
log "  Distro: $PRETTY_NAME"
case "$ID" in
    ubuntu|debian) ;;
    *) warn "這個 script 是針對 Ubuntu/Debian 寫的，其他 distro 自負風險" ;;
esac

# ── Step 1: apt 基礎套件 ────────────────────────────────────
log "安裝 apt 基礎套件..."
apt update -y
apt install -y \
    git curl wget vim build-essential ca-certificates \
    libgomp1 libstdc++6 software-properties-common \
    python3-pip qrencode rsync

# 強制裝 Python 3.11 (deadsnakes PPA) — 不依賴系統預設 python3，
# 避免 Ubuntu 22.04 預設 3.10 / 24.04 預設 3.12 / 手動 ln 3.14 的不一致行為
log "安裝 Python 3.11 (deadsnakes)..."
add-apt-repository -y ppa:deadsnakes/ppa
apt update -y
apt install -y python3.11 python3.11-venv python3.11-dev

PYTHON_BIN=/usr/bin/python3.11
PY_VER=$($PYTHON_BIN -c 'import sys; print("%d.%d" % sys.version_info[:2])')
log "  Python (deadsnakes): $PY_VER"
[[ "$PY_VER" != "3.11" ]] && die "意外的 Python 版本: $PY_VER (應為 3.11)"

# ── Step 2: Docker ─────────────────────────────────────────
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker 已裝，跳過"
else
    log "安裝 Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi
# 把 user 加進 docker group
if ! groups "$RUN_USER" | grep -qw docker; then
    usermod -aG docker "$RUN_USER"
    warn "已把 $RUN_USER 加進 docker group — 之後要 logout/login 才會生效"
fi

# ── Step 3: cloudflared ────────────────────────────────────
if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared 已裝，跳過"
else
    log "安裝 cloudflared..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  CF_ARCH=amd64 ;;
        aarch64) CF_ARCH=arm64 ;;
        *) die "不支援架構 $ARCH" ;;
    esac
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
        -o /tmp/cloudflared
    install -m 755 /tmp/cloudflared /usr/local/bin/cloudflared
    rm /tmp/cloudflared
fi
log "  cloudflared: $(cloudflared --version 2>&1 | head -1)"

# ── Step 4: 資料目錄 ───────────────────────────────────────
log "建立 $DATA_DIR/{db,csv,logs,signal}..."
mkdir -p "$DATA_DIR"/{db,csv,logs,signal}
chown -R "$RUN_USER:$RUN_USER" "$DATA_DIR"

# ── Step 5: 取得程式碼（git clone 或 解壓混淆 tarball）─────────
if [[ "$INSTALL_MODE" == "tarball" ]]; then
    TARBALL_PATH="${TARBALL_PATH:?tarball mode 需要 TARBALL_PATH env}"
    [[ -f "$TARBALL_PATH" ]] || die "TARBALL_PATH 不存在: $TARBALL_PATH"
    log "解壓混淆 tarball → $APP_DIR (INSTALL_MODE=tarball)..."
    # 保留現有 .env / data（若重部署），只換 code
    mkdir -p "$APP_DIR"
    chown "$RUN_USER:$RUN_USER" "$APP_DIR"
    # tarball 內是 repo-root 佈局 (teralion_WEB/ + shared/)，直接解到 APP_DIR
    sudo -u "$RUN_USER" tar xzf "$TARBALL_PATH" -C "$APP_DIR"
    ok "已解壓混淆包（策略檔 obfuscated，客戶看不到原始邏輯）"
elif [[ -d "$APP_DIR/.git" ]]; then
    log "更新現有程式碼於 $APP_DIR (INSTALL_MODE=git)..."
    sudo -u "$RUN_USER" git -C "$APP_DIR" fetch origin
    sudo -u "$RUN_USER" git -C "$APP_DIR" checkout "$BRANCH"
    sudo -u "$RUN_USER" git -C "$APP_DIR" pull --ff-only
else
    log "clone 專案到 $APP_DIR (INSTALL_MODE=git)..."
    mkdir -p "$APP_DIR"
    chown "$RUN_USER:$RUN_USER" "$APP_DIR"
    sudo -u "$RUN_USER" git clone -b "$BRANCH" "$REPO_URL" "$APP_DIR"
fi
BACKEND_DIR="$APP_DIR/teralion_WEB/backend"
FRONTEND_DIR="$APP_DIR/teralion_WEB/frontend"
[[ -d "$BACKEND_DIR" ]] || die "找不到 $BACKEND_DIR — repo/tarball 結構不對？"

# ── Step 6: 檢查 fubon_neo wheel ───────────────────────────
shopt -s nullglob
WHL_FILES=( $FUBON_WHL_GLOB )
shopt -u nullglob
if (( ${#WHL_FILES[@]} == 0 )); then
    die "找不到 fubon_neo wheel — 請把 Linux .whl 放到 $FUBON_WHL_GLOB 後重跑"
fi
FUBON_WHL="${WHL_FILES[0]}"
log "  fubon wheel: $FUBON_WHL"

# ── Step 7: Node 20 (給前端 build) ─────────────────────────
if ! command -v node >/dev/null 2>&1 || [[ $(node --version | sed 's/v//;s/\..*//') -lt 20 ]]; then
    log "安裝 Node 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi
log "  Node: $(node --version)"

# ── Step 8: backend venv + pip ────────────────────────────
log "建 backend venv + 裝 Python 套件..."
sudo -u "$RUN_USER" bash <<EOF
set -euo pipefail
cd "$BACKEND_DIR"
[[ -d .venv ]] || $PYTHON_BIN -m venv .venv
source .venv/bin/activate
pip install --upgrade pip wheel setuptools
pip install -r requirements.txt
pip install --force-reinstall --no-cache "$FUBON_WHL"
python -c "from fubon_neo.sdk import FubonSDK; print('fubon_neo ok')"
python -c "import pandas; print('pandas ok')"
# nautilus_trader 只有 day-trade-system 需要；Alex-version 砍掉了
python -c "import importlib.util as u; print('nautilus_trader', 'ok' if u.find_spec('nautilus_trader') else 'skipped (Alex-version 不需要)')"
EOF

# ── Step 9: 前端 build（tarball mode 跳過，包內已含 frontend_dist）──
if [[ "$INSTALL_MODE" == "tarball" ]]; then
    log "INSTALL_MODE=tarball → 跳過 npm build（tarball 已含 backend/frontend_dist）"
    [[ -f "$BACKEND_DIR/frontend_dist/index.html" ]] \
        || warn "tarball 內找不到 backend/frontend_dist/index.html — 前端可能沒 serve"
else
    log "前端 npm ci + build..."
    sudo -u "$RUN_USER" bash <<EOF
set -euo pipefail
cd "$FRONTEND_DIR"
npm ci
npm run build
EOF
    log "串接 frontend_dist symlink..."
    sudo -u "$RUN_USER" bash -c "rm -rf '$BACKEND_DIR/frontend_dist' && ln -s '../frontend/dist' '$BACKEND_DIR/frontend_dist'"
fi

# ── Step 10: 產生 .env ─────────────────────────────────────
# 支援兩種模式：
#   1. 互動模式（預設）— 跳 read prompt 給 user 填
#   2. 非互動模式 — 設 NON_INTERACTIVE_MODE=true 後從 env 直接讀
#     必填 env：ANTHROPIC_API_KEY
#     選填 env：SIGNAL_SENDER, SIGNAL_RECIPIENT, CENTRAL_CONTROL_ENABLED
#   給 central VPS 自動 provision 用。
ENV_FILE="$BACKEND_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    warn "$ENV_FILE 已存在，跳過產生（如要重設請先刪除）"
else
    NON_INTERACTIVE_MODE="${NON_INTERACTIVE_MODE:-false}"
    if [[ "$NON_INTERACTIVE_MODE" == "true" ]]; then
        log "非互動模式 — 從 env 讀 .env 設定"
        ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY env required in non-interactive mode}"
        SIGNAL_SENDER="${SIGNAL_SENDER:-}"
        SIGNAL_RECIPIENT="${SIGNAL_RECIPIENT:-$SIGNAL_SENDER}"
        SIGNAL_ENABLED="${SIGNAL_ENABLED:-$( [[ -n "$SIGNAL_SENDER" ]] && echo true || echo false )}"
        CENTRAL_CONTROL_ENABLED_VAL="${CENTRAL_CONTROL_ENABLED:-false}"
        # tarball mode（客戶機）license gate 必填 — 沒 LICENSE_KEY backend 開機就 sys.exit
        if [[ "$INSTALL_MODE" == "tarball" ]]; then
            LICENSE_KEY="${LICENSE_KEY:?tarball mode 需要 LICENSE_KEY env (meta 發的授權)}"
            LICENSE_SERVER_URL="${LICENSE_SERVER_URL:-https://central.teraliontech.com}"
        fi
    else
        log "產生 .env — 請填入下列資訊"
        read -rp "  ANTHROPIC_API_KEY (sk-ant-...): " ANTHROPIC_API_KEY
        read -rp "  Signal sender 號碼 (+886...，按 Enter 跳過 Signal): " SIGNAL_SENDER
        if [[ -n "$SIGNAL_SENDER" ]]; then
            read -rp "  Signal recipient 號碼 (按 Enter = 同 sender): " SIGNAL_RECIPIENT
            SIGNAL_RECIPIENT="${SIGNAL_RECIPIENT:-$SIGNAL_SENDER}"
            SIGNAL_ENABLED=true
        else
            SIGNAL_ENABLED=false
            SIGNAL_RECIPIENT=""
        fi
        CENTRAL_CONTROL_ENABLED_VAL="${CENTRAL_CONTROL_ENABLED:-false}"
    fi

    cat > "$ENV_FILE" <<EOF
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY

SIGNAL_ENABLED=$SIGNAL_ENABLED
SIGNAL_API_URL=http://localhost:8089
SIGNAL_SENDER=$SIGNAL_SENDER
SIGNAL_RECIPIENT=$SIGNAL_RECIPIENT

BACKTEST_CSV_DIR=$DATA_DIR/csv
SQLITE_PATH=$DATA_DIR/db/trading.db

CENTRAL_CONTROL_ENABLED=$CENTRAL_CONTROL_ENABLED_VAL

# PnL 通知閾值（dashboard 未實現損益跨閾值送 Signal，每日每方向各 1 次）
PNL_NOTIFY_PROFIT_THRESHOLD=20000
PNL_NOTIFY_LOSS_THRESHOLD=-40000
EOF
    # tarball mode（客戶機混淆版）追加 license — backend 開機會 phone home 驗
    if [[ "$INSTALL_MODE" == "tarball" ]]; then
        cat >> "$ENV_FILE" <<EOF

# SaaS License（客戶機混淆版必填，沒設 backend 拒絕啟動）
LICENSE_KEY=$LICENSE_KEY
LICENSE_SERVER_URL=$LICENSE_SERVER_URL
EOF
    fi
    chown "$RUN_USER:$RUN_USER" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "已寫入 $ENV_FILE (chmod 600)"
fi

# ── Step 11: Signal docker container ───────────────────────
if docker ps -a --format '{{.Names}}' | grep -qw teralion-signal; then
    log "Signal container 已存在，重啟..."
    docker restart teralion-signal >/dev/null
else
    log "啟動 Signal docker container..."
    # MODE=json-rpc：linking API 支援完整、效能也比 normal (Java daemon) 好。
    # native mode 不支援 /v1/qrcodelink，會卡住 link 流程。
    docker run -d \
        --name teralion-signal \
        --restart unless-stopped \
        -p 127.0.0.1:8089:8080 \
        -v "$DATA_DIR/signal:/home/.local/share/signal-cli" \
        -e MODE=json-rpc \
        bbernhard/signal-cli-rest-api:latest >/dev/null
fi
sleep 2
if curl -sf http://localhost:8089/v1/about >/dev/null 2>&1; then
    ok "Signal API ready at http://localhost:8089"
else
    warn "Signal API 還沒回應，docker logs teralion-signal 看一下"
fi

# ── Step 12: systemd service ───────────────────────────────
log "註冊 systemd service: $SERVICE_NAME..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Teralion Trading Backend
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$BACKEND_DIR
EnvironmentFile=$BACKEND_DIR/.env
ExecStart=$BACKEND_DIR/.venv/bin/python -m uvicorn main:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null
systemctl restart "$SERVICE_NAME"
sleep 3

if curl -sf http://localhost:8000/api >/dev/null 2>&1; then
    ok "Backend 已啟動: $(curl -s http://localhost:8000/api)"
else
    warn "Backend 還沒回應，看 log: sudo journalctl -u $SERVICE_NAME -f"
fi

# ── 最後印剩下要手動跑的步驟 ────────────────────────────────
cat <<EOF

${C_GREEN}════════════════════════════════════════════════════════════${C_OFF}
${C_GREEN}✅ 自動化階段完成${C_OFF}

服務狀態檢查:
  sudo systemctl status $SERVICE_NAME
  docker ps | grep teralion-signal
  curl http://localhost:8000/api

接下來這幾步${C_YELLOW}要互動操作${C_OFF}（無法自動）:

${C_BLUE}━━━ A. 連動手機 Signal (一次性) ━━━${C_OFF}
  # 印出 sgnl:// 連結
  docker exec teralion-signal signal-cli link -n "teralion-server"

  # 把那串 URI 餵給 qrencode 產 QR code:
  echo 'sgnl://link?xxxxxxx' | qrencode -t ANSIUTF8

  # 手機 Signal app → 設定 → 連結的裝置 → 連結新裝置 → 掃 QR

${C_BLUE}━━━ B. 設 Cloudflare Tunnel (一次性) ━━━${C_OFF}
  # 1. login（跳瀏覽器）
  cloudflared tunnel login

  # 2. 建 tunnel
  cloudflared tunnel create teralion-trade

  # 3. 編輯 config (上面指令會印 UUID + 路徑)
  mkdir -p ~/.cloudflared
  cat > ~/.cloudflared/config.yml <<YAML
tunnel: <UUID>
credentials-file: $RUN_HOME/.cloudflared/<UUID>.json
ingress:
  - hostname: trade.YOUR-DOMAIN.com
    service: http://localhost:8000
  - service: http_status:404
YAML

  # 4. 設 DNS routing
  cloudflared tunnel route dns teralion-trade trade.YOUR-DOMAIN.com

  # 5. 裝成 service
  sudo cloudflared service install
  sudo systemctl start cloudflared

${C_BLUE}━━━ C. 把 trading.db + CSV 從 Windows 搬過來 ━━━${C_OFF}
  # 在 Windows 端跑 (用 WSL 或 git-bash):
  rsync -avzP backend/data/trading.db $RUN_USER@<server-ip>:$DATA_DIR/db/
  rsync -avzP backend/data/backtest_daily.sqlite3 $RUN_USER@<server-ip>:$DATA_DIR/db/
  rsync -avzP "C:/path/to/分線資料/" $RUN_USER@<server-ip>:$DATA_DIR/csv/

  # 搬完重啟 backend:
  sudo systemctl restart $SERVICE_NAME

${C_BLUE}━━━ D. 驗證 ━━━${C_OFF}
  curl http://localhost:8000/api                       # local
  curl https://trade.YOUR-DOMAIN.com/api               # tunnel
  瀏覽器開 https://trade.YOUR-DOMAIN.com               # 看到登入頁

${C_BLUE}━━━ Log 看哪裡 ━━━${C_OFF}
  sudo journalctl -u $SERVICE_NAME -f                  # backend
  sudo journalctl -u cloudflared -f                    # tunnel
  docker logs teralion-signal --tail 50 -f             # signal

${C_GREEN}════════════════════════════════════════════════════════════${C_OFF}
EOF
