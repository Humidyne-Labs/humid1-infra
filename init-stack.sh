#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# HUMID1_OS — Automated First-Run & Provisioning Orchestrator
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
  -c, --config <path>   Override path to the base environment configuration (default: stack.env)
  -h, --help            Display this help message and exit

Workflow:
  1. Validates host runtime (Docker, Docker Compose plugin, OpenSSL).
  2. Reads domains, emails, and SMTP/SFTP settings from stack.env.
  3. Generates random high-entropy cryptographic keys and creates .env (if not present).
  4. Bootstraps PostgreSQL and Kafka storage engines.
  5. Executes ThingsBoard schema provisioning & seed installer.
  6. Launches the full container mesh and waits for Authentik ASGI readiness.
  7. Prompts to configure the Authentik master 'akadmin' password.

Examples:
  $(basename "$0")                      # Standard first-run initialization
  $(basename "$0") -c prod.env          # Initialize using custom environment configuration
  $(basename "$0") -h                   # View this help menu
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
    echo -e "${YELLOW}[!] Base config file '$CONFIG_FILE' not found. Creating a template...${NC}"
    cat << 'EOF' > "$CONFIG_FILE"
# ==============================================================================
# HUMID1_OS — Base Configuration Template
# ==============================================================================

# --- Domain Endpoints ---
BASE_PUBLIC_URL=https://example.com
TB_PUBLIC_URL=https://app.example.com
CHATTO_PUBLIC_URL=https://chat.example.com
AUTHENTIK_PUBLIC_URL=https://auth.example.com

# --- Administrative & Account Emails ---
ADMIN_EMAIL=admin@example.com
CHATTO_OWNERS_EMAILS=admin@example.com

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

# --- Database & Client Identifiers ---
POSTGRES_USER=postgres
TB_OIDC_CLIENT_ID=thingsboard
CHATTO_OIDC_CLIENT_ID=chatto
EOF
    echo -e "${RED}[-] Template created at '$CONFIG_FILE'. Please edit it with your real domain/SMTP values and re-run this script.${NC}"
    exit 1
fi

# Load user settings from configuration file
set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

# 3. Generate .env if not present
if [ ! -f .env ]; then
    echo -e "${YELLOW}[!] Generating fresh runtime .env with random cryptographic keys...${NC}"

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
CHATTO_OWNERS_EMAILS=${CHATTO_OWNERS_EMAILS}

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
EOF
    echo -e "${GREEN}[+] Generated .env with strong unique keys.${NC}"
else
    echo -e "${GREEN}[+] Active .env detected (cryptographic keys preserved).${NC}"
fi

# 4. Ensure init-authentik-db.sql and folders exist
echo -e "\n${CYAN}[Step 3/6] Verifying database bootstrap configs and paths...${NC}"
if [ ! -f init-authentik-db.sql ]; then
    echo "CREATE DATABASE authentik;" > init-authentik-db.sql
    echo -e "${GREEN}[+] Created init-authentik-db.sql for automatic database bootstrapping.${NC}"
fi

mkdir -p landing-page/content
mkdir -p ./custom-templates

# Ensure non-root container users (UID 1000) have read & traverse access
chmod -R a+rX ./custom-templates ./landing-page 2>/dev/null || true
echo -e "${GREEN}[+] Set read/execute permissions on container volume mounts.${NC}"

# 5. Bootstrap Database & Kafka
echo -e "\n${CYAN}[Step 4/6] Launching PostgreSQL and Kafka storage backends...${NC}"
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
echo -e "\n${CYAN}[Step 5/6] Running ThingsBoard database schema installer...${NC}"
docker compose run --rm -e INSTALL_TB=true -e LOAD_DEMO=false thingsboard-ce
echo -e "${GREEN}[+] ThingsBoard schema & seed datasets generated successfully.${NC}"

# 7. Launch Entire Stack & Wait for Authentik Lifecycle
echo -e "\n${CYAN}[Step 6/6] Launching full container mesh...${NC}"
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

echo -e "\n${GREEN}=================================================${NC}"
echo -e "${GREEN}      HUMID1_OS DEPLOYMENT COMPLETE!             ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo -e "Access your endpoints:"
echo -e "  • ${BOLD}Landing & Legal:${NC}  ${BASE_PUBLIC_URL}"
echo -e "  • ${BOLD}Authentik SSO:${NC}    ${AUTHENTIK_PUBLIC_URL} (Login: akadmin)"
echo -e "  • ${BOLD}ThingsBoard UI:${NC}   ${TB_PUBLIC_URL}  (Login: sysadmin@thingsboard.org / sysadmin)"
echo -e "  • ${BOLD}Chatto Chat:${NC}      ${CHATTO_PUBLIC_URL}"
echo -e "\n${CYAN}Stack status check: docker compose ps${NC}\n"