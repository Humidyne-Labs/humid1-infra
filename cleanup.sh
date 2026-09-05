#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# HUMID1_OS — Stack Cleanup & Teardown Utility
# ==============================================================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

MODE="full"
FORCE=false

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Clean up or completely reset the HUMID1_OS Docker stack.

Options:
  -a, --authentik-only   Nuke Authentik database & volume only (preserves ThingsBoard, Chatto & Caddy)
  -f, --force            Bypass interactive safety confirmation
  -h, --help             Display this help menu

Examples:
  $(basename "$0")                      # Complete stack wipe (containers + all persistent data)
  $(basename "$0") -f                   # Non-interactive complete stack wipe
  $(basename "$0") --authentik-only     # Reset Authentik DB/media without wiping ThingsBoard
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -a|--authentik-only)
            MODE="authentik"
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        *)
            echo -e "${RED}[-] Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}        HUMID1_OS :: TEARDOWN & CLEANUP          ${NC}"
echo -e "${CYAN}=================================================${NC}"

if [ "$MODE" = "authentik" ]; then
    echo -e "${YELLOW}[!] Target: Reset Authentik Database & Cache ONLY${NC}"
    echo -e "    ThingsBoard, Chatto, NATS, Cap, and Caddy TLS certificates will be preserved.\n"
    
    if [ "$FORCE" = false ]; then
        read -rp "Are you sure you want to drop the Authentik database? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
            echo -e "${YELLOW}[*] Operation aborted.${NC}"
            exit 0
        fi
    fi

    echo -e "\n${CYAN}[1/3] Stopping Authentik containers...${NC}"
    docker compose stop authentik-server authentik-worker

    # Ensure postgres is running to accept SQL commands
    if ! docker compose ps postgres | grep -q "Up"; then
        docker compose up -d postgres
        sleep 2
    fi

    echo -e "${CYAN}[2/3] Dropping and recreating 'authentik' database in PostgreSQL...${NC}"
    docker compose exec postgres psql -U postgres -d postgres -c "
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'authentik' AND pid <> pg_backend_pid();
        DROP DATABASE IF EXISTS authentik;
        CREATE DATABASE authentik;
    " > /dev/null 2>&1 || true

    echo -e "${CYAN}[3/3] Purging Authentik state volume...${NC}"
    docker compose rm -f -s -v authentik-server authentik-worker > /dev/null 2>&1 || true
    docker volume rm humid1_authentik-data > /dev/null 2>&1 || docker volume rm authentik-data > /dev/null 2>&1 || true

    echo -e "\n${GREEN}[+] Authentik database and artifacts successfully nuked!${NC}"
    echo -e "${CYAN}[*] Run 'docker compose up -d' to restart Authentik fresh.${NC}"
    exit 0
fi

# Full Stack Wipe
echo -e "${RED}[WARNING] FULL STACK TEARDOWN SELECTED${NC}"
echo -e "This will permanently delete:"
echo -e "  • All running HUMID1 containers"
echo -e "  • ThingsBoard PostgreSQL database & Kafka streams"
echo -e "  • Authentik identity database & outpost data"
echo -e "  • Chatto messaging data & NATS JetStreams"
echo -e "  • Captcha Valkey cache data"
echo -e "  • Caddy SSL/TLS certificates\n"

if [ "$FORCE" = false ]; then
    read -rp "Type 'NUKE' to confirm complete system reset: " confirm
    if [ "$confirm" != "NUKE" ]; then
        echo -e "${YELLOW}[*] Reset canceled.${NC}"
        exit 0
    fi
fi

echo -e "\n${CYAN}[1/3] Stopping and removing containers and networks...${NC}"
docker compose down -v --remove-orphans

echo -e "${CYAN}[2/3] Purging any dangling volumes...${NC}"
VOLUMES=(
    "tb-postgres-data" 
    "postgres-data" 
    "humid1_postgres-data"
    "tb-ce-kafka-data" 
    "kafka-data" 
    "humid1_kafka-data"
    "nats-data" 
    "humid1_nats-data"
    "authentik-data" 
    "humid1_authentik-data"
    "cap-valkey-data"
    "valkey-data"
    "humid1_valkey-data"
    "caddy_data" 
    "humid1_caddy_data"
)

for vol in "${VOLUMES[@]}"; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        echo -e "    Removing volume: ${vol}"
        docker volume rm -f "$vol" >/dev/null 2>&1 || true
    fi
done

echo -e "${CYAN}[3/3] Pruning orphaned network interfaces...${NC}"
docker network prune -f > /dev/null 2>&1 || true

echo -e "\n${GREEN}[+] All containers, databases, and persistent volumes purged.${NC}"
echo -e "${CYAN}[*] Ready for a fresh launch with ./init-stack.sh${NC}\n"