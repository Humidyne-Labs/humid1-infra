#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# HUMID1_OS — Automated First-Run & Provisioning Orchestrator
# NEW, Untested on vps 9/12/2026
# ==============================================================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_FILE="stack.env"

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Initialize, generate cryptographic secrets, bootstrap databases, and launch the HUMID1_OS container stack.

Options:
  -c, --config <path>   Override path to base environment configuration (default: stack.env)
  -h, --help            Display this help message and exit

Workflow:
  1. Validates host runtime (Docker, Docker Compose plugin, OpenSSL).
  2. Reads domains, emails, and SMTP/SFTP settings from stack.env.
  3. Generates high-entropy cryptographic keys and creates .env & bunkerweb.env.
  4. Bootstraps PostgreSQL and Kafka storage engines.
  5. Executes ThingsBoard schema provisioning & seed installer.
  6. Launches the full container mesh and waits for Authentik ASGI readiness.
  7. Prompts to configure the Authentik master 'akadmin' password.
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}[-] Unknown parameter: $1${NC}\n"
            show_help
            exit 1
            ;;
    esac
done

echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}     HUMID1_OS :: FIRST-RUN INITIALIZATION       ${NC}"
echo -e "${CYAN}=================================================${NC}\n"

# 1. Check Prerequisites
echo -e "${CYAN}[Step 1/6] Validating host environment...${NC}"
command -v docker >/dev/null 2>&1 || { echo -e "${RED}[-] Docker is not installed. Aborting.${NC}"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo -e "${RED}[-] Docker Compose plugin is missing. Aborting.${NC}"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo -e "${RED}[-] OpenSSL is required for secret generation. Aborting.${NC}"; exit 1; }
echo -e "${GREEN}[+] Host runtime validated.${NC}\n"

# 2. Check / Load Base Configuration
echo -e "${CYAN}[Step 2/6] Checking configuration sources...${NC}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}[!] Base config file '$CONFIG_FILE' not found. Creating a sanitized template...${NC}"
    cat << 'EOF' > "$CONFIG_FILE"
# ==============================================================================
# HUMID1_OS — Public Base Configuration Template (No Secrets Here)
# ==============================================================================

# --- Root Domain ---
ROOT_DOMAIN=example.com

# --- Public Endpoints ---
BASE_PUBLIC_URL=https://example.com
DASH_PUBLIC_URL=https://dash.example.com
TB_PUBLIC_URL=https://app.example.com
CHATTO_PUBLIC_URL=https://chat.example.com
AUTHENTIK_PUBLIC_URL=https://auth.example.com
CAP_PUBLIC_URL=https://cap.example.com
BW_PUBLIC_URL=https://bw.example.com
MQTT_PUBLIC_HOST=mqtt.example.com

# --- Administrative & Account Emails ---
ADMIN_EMAIL=support@example.com
CHATTO_OWNERS_EMAILS=support@example.com

# --- Tailscale Restriction Range ---
TAILSCALE_SUBNET=100.64.0.0/10

# --- SMTP Relay Settings ---
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=support@example.com
SMTP_PASSWORD=change_me

# --- SFTP Backup Target ---
SFTP_HOST=host_ip
SFTP_PORT=1234
SFTP_USER=vps-user
SFTP_KEY=/root/.ssh/id

# --- Identifiers & OIDC Slugs ---
POSTGRES_USER=postgres
TB_OIDC_CLIENT_ID=thingsboard
CHATTO_OIDC_CLIENT_ID=chatto
AUTHENTIK_APP_SLUG=humid1-os
AUTHENTIK_CLIENT_ID=humid1-client
DEFAULT_DEVICE_NAME=HUMID1-Master-Node
APP_TITLE="HUMID1 OS"
APP_DESCRIPTION="Telemetry & Automation Platform"
DASHBOARD_VERSION=2.5.4
DASHBOARD_REVISION=aedf599
EOF
    echo -e "${RED}[-] Template created at '$CONFIG_FILE'. Edit it with your domain names and re-run this script.${NC}"
    exit 1
fi

# Load user settings from configuration file
set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

# Extract clean hostnames from URLs (strip https:// and trailing /)
clean_host() {
    echo "$1" | sed -e 's|^[^/]*//||' -e 's|/.*$||'
}

ROOT_HOST="${ROOT_DOMAIN:-$(clean_host "$BASE_PUBLIC_URL")}"
DASH_HOST="$(clean_host "$DASH_PUBLIC_URL")"
TB_HOST="$(clean_host "$TB_PUBLIC_URL")"
CHAT_HOST="$(clean_host "$CHATTO_PUBLIC_URL")"
AUTH_HOST="$(clean_host "$AUTHENTIK_PUBLIC_URL")"
CAP_HOST="$(clean_host "$CAP_PUBLIC_URL")"
BW_HOST="$(clean_host "$BW_PUBLIC_URL")"
MQTT_HOST="${MQTT_PUBLIC_HOST:-mqtt.$ROOT_HOST}"

# 3. Generate .env and bunkerweb.env if not present
echo -e "\n${CYAN}[Step 3/6] Generating cryptographic secrets and environment configs...${NC}"

if [ ! -f .env ]; then
    echo -e "${YELLOW}[*] Generating runtime .env with random cryptographic keys...${NC}"

    PG_PASS=$(openssl rand -hex 24)
    AUTH_SEC=$(openssl rand -hex 32)
    TB_OIDC_SEC=$(openssl rand -hex 32)
    CHATTO_OIDC_SEC=$(openssl rand -hex 32)
    NATS_TOK=$(openssl rand -hex 24)
    CHATTO_COOK_ENC=$(openssl rand -hex 32)
    CHATTO_COOK_SIG=$(openssl rand -hex 32)
    CHATTO_CORE_SEC=$(openssl rand -hex 32)
    CHATTO_ASSET_SIG=$(openssl rand -hex 32)
    CAP_KEY=$(openssl rand -hex 32)
    
    # Generate compliant BunkerWeb admin password (Upper, Lower, Number, Special)
    BW_ADMIN_PASS="Bw@$(openssl rand -hex 10)1!"

    cat << EOF > .env
# Generated Runtime Configuration from $CONFIG_FILE

# Domain Endpoints
BASE_PUBLIC_URL=${BASE_PUBLIC_URL}
TB_PUBLIC_URL=${TB_PUBLIC_URL}
CHATTO_PUBLIC_URL=${CHATTO_PUBLIC_URL}
AUTHENTIK_PUBLIC_URL=${AUTHENTIK_PUBLIC_URL}

# Database
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${PG_PASS}

# Captcha Service
CAP_ADMIN_KEY=${CAP_KEY}

# Authentik Secrets
AUTHENTIK_SECRET_KEY=${AUTH_SEC}
AUTHENTIK_ERROR_REPORTING__ENABLED=false

# Authentik & ThingsBoard SSO Settings for Dashboard
VITE_THINGSBOARD_URL=${TB_PUBLIC_URL}
VITE_AUTHENTIK_URL=${AUTHENTIK_PUBLIC_URL}
VITE_AUTHENTIK_APP_SLUG=${AUTHENTIK_APP_SLUG:-humid1-os}
VITE_AUTHENTIK_CLIENT_ID=${AUTHENTIK_CLIENT_ID:-humid1-client}
VITE_DASHBOARD_URL=${DASH_PUBLIC_URL}
VITE_APP_REDIRECT_URI=${DASH_PUBLIC_URL}/login/oauth2/code/
VITE_DEFAULT_DEVICE_NAME="${DEFAULT_DEVICE_NAME:-HUMID1-Master-Node}"
VITE_APP_TITLE="${APP_TITLE:-HUMID1 OS}"
VITE_APP_DESCRIPTION="${APP_DESCRIPTION:-Telemetry & Automation Platform}"
VITE_DASHBOARD_VERSION=${DASHBOARD_VERSION:-latest}
VITE_DASHBOARD_REVISION=${DASHBOARD_REVISION:-latest}

# OIDC Client Secrets
TB_OIDC_CLIENT_ID=${TB_OIDC_CLIENT_ID:-thingsboard}
TB_OIDC_CLIENT_SECRET=${TB_OIDC_SEC}
CHATTO_OIDC_CLIENT_ID=${CHATTO_OIDC_CLIENT_ID:-chatto}
CHATTO_OIDC_CLIENT_SECRET=${CHATTO_OIDC_SEC}

# Chatto & NATS Security
NATS_TOKEN=${NATS_TOK}
CHATTO_COOKIE_ENCRYPTION_SECRET=${CHATTO_COOK_ENC}
CHATTO_COOKIE_SIGNING_SECRET=${CHATTO_COOK_SIG}
CHATTO_CORE_SECRET_KEY=${CHATTO_CORE_SEC}
CHATTO_ASSETS_SIGNING_SECRET=${CHATTO_ASSET_SIG}
CHATTO_OWNERS_EMAILS=${CHATTO_OWNERS_EMAILS:-$ADMIN_EMAIL}

# SMTP Relay
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASSWORD=${SMTP_PASSWORD}

# SFTP Backup
SFTP_HOST=${SFTP_HOST}
SFTP_PORT=${SFTP_PORT}
SFTP_USER=${SFTP_USER}
SFTP_KEY=${SFTP_KEY}

# BunkerWeb UI Credentials
BUNKER_WEB_ADMIN_USERNAME=admin
BUNKER_WEB_ADMIN_PASSWORD=${BW_ADMIN_PASS}
EOF
    echo -e "${GREEN}[+] Generated .env with strong unique keys.${NC}"
else
    echo -e "${GREEN}[+] Active .env detected (cryptographic keys preserved).${NC}"
fi

if [ ! -f bunkerweb.env ]; then
    echo -e "${YELLOW}[*] Generating bunkerweb.env from $CONFIG_FILE...${NC}"

    cat << EOF > bunkerweb.env
# ==============================================================================
# HARDENING & ANTI-RECONNAISSANCE
# ==============================================================================
DISABLE_DEFAULT_SERVER=yes
USE_DNSBL=yes
USE_BLACKLIST=yes
USE_BAD_BEHAVIOR=yes
BAD_BEHAVIOR_BAN_TIME=86400
BAD_BEHAVIOR_THRESHOLD=10
USE_LIMIT_REQ=yes
LIMIT_REQ_RATE=20r/s
LIMIT_REQ_BURST=80
SECURITY_MODE=detect

# ==============================================================================
# GLOBAL / BUNKERWEB CORE SETTINGS
# ==============================================================================
BUNKERWEB_INSTANCES=bunkerweb
MULTISITE=yes
API_WHITELIST_IP=127.0.0.1 172.19.0.100 172.19.0.101

AUTO_LETS_ENCRYPT=yes
EMAIL_LETS_ENCRYPT=${ADMIN_EMAIL}
AUTO_REDIRECT_HTTP_TO_HTTPS=yes
MAX_CLIENT_SIZE=100m

# All active domains and stream listeners
SERVER_NAME=${ROOT_HOST} www.${ROOT_HOST} ${AUTH_HOST} ${TB_HOST} ${CHAT_HOST} ${CAP_HOST} ${DASH_HOST} ${MQTT_HOST} ${BW_HOST}

# ==============================================================================
# 1. WWW REDIRECT
# ==============================================================================
www.${ROOT_HOST}_REDIRECT_TO=https://${ROOT_HOST}
www.${ROOT_HOST}_REDIRECT_TO_REQUEST_URI=yes
www.${ROOT_HOST}_REDIRECT_TO_STATUS_CODE=301

# ==============================================================================
# 2. MAIN LANDING PAGE
# ==============================================================================
${ROOT_HOST}_USE_REVERSE_PROXY=yes
${ROOT_HOST}_REVERSE_PROXY_URL=/
${ROOT_HOST}_REVERSE_PROXY_HOST=http://landingpage:6000
${ROOT_HOST}_CONTENT_SECURITY_POLICY="default-src 'self' https: data: 'unsafe-inline' 'unsafe-eval'; connect-src 'self' https: wss: ws:; frame-ancestors 'self'; base-uri 'self'; form-action 'self' https:;"
${ROOT_HOST}_CROSS_ORIGIN_OPENER_POLICY="same-origin-allow-popups"

# ==============================================================================
# 3. AUTHENTIK SSO
# ==============================================================================
${AUTH_HOST}_USE_REVERSE_PROXY=yes
${AUTH_HOST}_REVERSE_PROXY_URL=/
${AUTH_HOST}_REVERSE_PROXY_HOST=http://authentik-server:9000
${AUTH_HOST}_REVERSE_PROXY_WS=yes
${AUTH_HOST}_REVERSE_PROXY_INTERCEPT_ERRORS=no
${AUTH_HOST}_ALLOWED_METHODS="GET|POST|HEAD|OPTIONS|PUT|DELETE|PATCH"

# CORS for Custom Dashboard
${AUTH_HOST}_USE_CORS=yes
${AUTH_HOST}_CORS_ALLOW_ORIGIN="https://${DASH_HOST}"
${AUTH_HOST}_CORS_ALLOW_METHODS="GET, POST, PUT, DELETE, OPTIONS, PATCH"
${AUTH_HOST}_CORS_ALLOW_HEADERS="Authorization, Content-Type, X-Authorization, X-Requested-With, Accept"
${AUTH_HOST}_CORS_ALLOW_CREDENTIALS=yes

# ==============================================================================
# 4. THINGSBOARD ADMIN UI (LOCKED TO TAILSCALE)
# ==============================================================================
${TB_HOST}_USE_WHITELIST=yes
${TB_HOST}_WHITELIST_IP="${TAILSCALE_SUBNET:-100.64.0.0/10} 127.0.0.1 172.16.0.0/12"
${TB_HOST}_USE_REVERSE_PROXY=yes
${TB_HOST}_REVERSE_PROXY_URL=/
${TB_HOST}_REVERSE_PROXY_HOST=http://thingsboard-ce:8080
${TB_HOST}_REVERSE_PROXY_WS=yes
${TB_HOST}_REVERSE_PROXY_INTERCEPT_ERRORS=no
${TB_HOST}_ALLOWED_METHODS="GET|POST|HEAD|OPTIONS|PUT|DELETE|PATCH"

# ==============================================================================
# 5. CUSTOM DASHBOARD & API PROXY
# ==============================================================================
${DASH_HOST}_USE_REVERSE_PROXY=yes

# Route 1: OAuth2 endpoints -> ThingsBoard CE
${DASH_HOST}_REVERSE_PROXY_URL_1=/oauth2/
${DASH_HOST}_REVERSE_PROXY_HOST_1=http://thingsboard-ce:8080

# Route 2: Login OAuth2 endpoints -> ThingsBoard CE
${DASH_HOST}_REVERSE_PROXY_URL_2=/login/oauth2/
${DASH_HOST}_REVERSE_PROXY_HOST_2=http://thingsboard-ce:8080

# Route 3: REST & Telemetry APIs -> ThingsBoard CE
${DASH_HOST}_REVERSE_PROXY_URL_3=/api/
${DASH_HOST}_REVERSE_PROXY_HOST_3=http://thingsboard-ce:8080
${DASH_HOST}_REVERSE_PROXY_WS_3=yes

# Route 4: Fallback -> Dashboard SPA Frontend
${DASH_HOST}_REVERSE_PROXY_URL_4=/
${DASH_HOST}_REVERSE_PROXY_HOST_4=http://dashboard:5000
${DASH_HOST}_REVERSE_PROXY_WS_4=yes

# Android Digital Asset Links Verification
${DASH_HOST}_CUSTOM_CONF_SERVER_HTTP_assetlinks="location = /.well-known/assetlinks.json { default_type application/json; return 200 '[{\"relation\":[\"delegate_permission/common.handle_all_urls\"],\"target\":{\"namespace\":\"android_app\",\"package_name\":\"com.humid1.app\",\"sha256_cert_fingerprints\":[\"EB:F7:73:E4:4B:D5:C8:FD:50:AF:E6:37:DF:86:31:FD:61:5B:B9:09:B6:F0:69:C5:03:F9:D6:FC:E6:A3:47:E0\"]}}]'; }"

# ==============================================================================
# 6. CHATTO COMMUNITY
# ==============================================================================
${CHAT_HOST}_USE_REVERSE_PROXY=yes
${CHAT_HOST}_REVERSE_PROXY_URL=/
${CHAT_HOST}_REVERSE_PROXY_HOST=http://chatto:4000
${CHAT_HOST}_REVERSE_PROXY_WS=yes
${CHAT_HOST}_REVERSE_PROXY_INTERCEPT_ERRORS=no

# ==============================================================================
# 7. CAPTCHA SERVICE
# ==============================================================================
${CAP_HOST}_USE_REVERSE_PROXY=yes
${CAP_HOST}_REVERSE_PROXY_URL=/
${CAP_HOST}_REVERSE_PROXY_HOST=http://cap:3000

# Protect Admin Panels (Allow Tailscale only, block public internet)
${CAP_HOST}_CUSTOM_CONF_SERVER_HTTP_admin_lock="location ~* ^/(admin|api/admin) { allow ${TAILSCALE_SUBNET:-100.64.0.0/10}; allow 127.0.0.1; allow 172.16.0.0/12; deny all; proxy_pass http://cap:3000; }"

# ==============================================================================
# 8. MQTTS LAYER 4 TLS STREAM (:8883 -> thingsboard-ce:1883)
# ==============================================================================
${MQTT_HOST}_SERVER_TYPE=stream
${MQTT_HOST}_LISTEN_STREAM=no
${MQTT_HOST}_LISTEN_STREAM_PORT_SSL=8883
${MQTT_HOST}_USE_REVERSE_PROXY=yes
${MQTT_HOST}_REVERSE_PROXY_HOST=thingsboard-ce:1883

# ==============================================================================
# 9. BUNKERWEB DASHBOARD (LOCKED TO TAILSCALE)
# ==============================================================================
${BW_HOST}_USE_WHITELIST=yes
${BW_HOST}_WHITELIST_IP="${TAILSCALE_SUBNET:-100.64.0.0/10} 127.0.0.1 172.16.0.0/12"
${BW_HOST}_USE_TEMPLATE=ui
${BW_HOST}_USE_REVERSE_PROXY=yes
${BW_HOST}_REVERSE_PROXY_URL=/
${BW_HOST}_REVERSE_PROXY_HOST=http://bunkerweb-ui:7000
${BW_HOST}_REVERSE_PROXY_INTERCEPT_ERRORS=no
EOF
    echo -e "${GREEN}[+] Generated bunkerweb.env with matching domain configuration.${NC}"
else
    echo -e "${GREEN}[+] Active bunkerweb.env detected.${NC}"
fi

# 4. Bootstrap Files & Directories
echo -e "\n${CYAN}[Step 4/6] Verifying bootstrap assets and paths...${NC}"
if [ ! -f init-authentik-db.sql ]; then
    echo "CREATE DATABASE authentik;" > init-authentik-db.sql
    echo -e "${GREEN}[+] Created init-authentik-db.sql.${NC}"
fi

mkdir -p ./custom-templates
chmod -R a+rX ./custom-templates 2>/dev/null || true

# 5. Bootstrap Database & Kafka
echo -e "\n${CYAN}[Step 5/6] Launching PostgreSQL and Kafka storage engines...${NC}"
docker compose up -d postgres kafka

echo -e "    Waiting for PostgreSQL to pass internal health check..."
until docker compose exec postgres pg_isready -U "${POSTGRES_USER:-postgres}" >/dev/null 2>&1; do
    sleep 2
    echo -n "."
done
echo -e "\n${GREEN}[+] PostgreSQL is healthy and accepting connections.${NC}"

# Ensure 'authentik' db exists
docker compose exec postgres psql -U "${POSTGRES_USER:-postgres}" -d postgres -c "
    SELECT 'CREATE DATABASE authentik' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'authentik')\gexec
" > /dev/null 2>&1 || true

# 6. Initialize ThingsBoard Schema
echo -e "\n${CYAN}[Step 6/6] Running ThingsBoard database schema installer...${NC}"
docker compose run --rm -e INSTALL_TB=true -e LOAD_DEMO=false thingsboard-ce
echo -e "${GREEN}[+] ThingsBoard schema installed.${NC}"

# 7. Launch Entire Stack & Wait for Authentik Lifecycle
echo -e "\n${CYAN}[*] Launching full container mesh and WAF...${NC}"
docker compose up -d --remove-orphans

echo -e "\n${CYAN}[*] Waiting for Authentik to apply migrations and initialize ASGI workers...${NC}"
until docker compose exec authentik-server python3 -c "
import urllib.request
try:
    res = urllib.request.urlopen('http://127.0.0.1:9000/-/health/live/', timeout=2)
    exit(0 if res.getcode() == 200 else 1)
except Exception:
    exit(1)
" >/dev/null 2>&1; do
    sleep 3
    echo -n "."
done
echo -e "\n${GREEN}[+] Authentik is fully initialized and operational!${NC}"

echo -e "\n${CYAN}[*] Waiting for Authentik blueprints to seed default admin...${NC}"
until docker compose exec authentik-server python3 -c "
import os, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'authentik.root.settings')
django.setup()
from authentik.core.models import User
exit(0 if User.objects.filter(username='akadmin').exists() else 1)
" >/dev/null 2>&1; do
    sleep 2
    echo -n "."
done

echo -e "\n${YELLOW}-------------------------------------------------${NC}"
echo -e "${YELLOW}Set your Authentik master 'akadmin' password now:${NC}"
echo -e "${YELLOW}-------------------------------------------------${NC}"
docker compose exec authentik-server /manage.py changepassword akadmin

# Load BunkerWeb UI admin password from generated .env
BW_PASS=$(grep '^BUNKER_WEB_ADMIN_PASSWORD=' .env | cut -d '=' -f2-)

echo -e "\n${GREEN}=================================================${NC}"
echo -e "${GREEN}      HUMID1_OS DEPLOYMENT COMPLETE!             ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo -e "Access your endpoints:"
echo -e "  • ${BOLD}Landing Page:${NC}       ${BASE_PUBLIC_URL}"
echo -e "  • ${BOLD}Custom Dashboard:${NC}   ${DASH_PUBLIC_URL}"
echo -e "  • ${BOLD}Authentik SSO:${NC}      ${AUTHENTIK_PUBLIC_URL} (User: akadmin)"
echo -e "  • ${BOLD}BunkerWeb WAF UI:${NC}   ${BW_PUBLIC_URL} (User: admin | Pass: ${YELLOW}${BW_PASS}${NC})"
echo -e "  • ${BOLD}ThingsBoard UI:${NC}     ${TB_PUBLIC_URL} (User: sysadmin@thingsboard.org / sysadmin)"
echo -e "  • ${BOLD}Chatto Chat:${NC}        ${CHATTO_PUBLIC_URL}"
echo -e "\n${CYAN}Stack status check: docker compose ps${NC}\n"
