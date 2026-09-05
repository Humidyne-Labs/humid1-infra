#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# HUMID1_OS — Automated Snapshot & Remote SFTP Backup Utility
# ==============================================================================

HUMID1_DIR="${HUMID1_DIR:-/root/humid1}"
BACKUP_DIR="${BACKUP_DIR:-/root/humid1_snapshots}"
ENV_FILE="${HUMID1_DIR}/.env"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
INCLUDE_VOLUMES=false
UPLOAD_SFTP=false

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Create a compressed, timestamped snapshot archive of the HUMID1_OS stack and optionally push it to SFTP.

Options:
  -v, --include-volumes    Include live Docker database & app volumes (Generates: humid1_full_snapshot_*.tar.gz)
  -u, --upload             Upload snapshot directly to SFTP server (Reads SFTP_* from .env)
  -d, --dir <path>         Override source project directory (default: /root/humid1)
  -e, --env-file <path>    Override .env path to source SFTP/SMTP credentials
  -o, --output <path>      Override local backup folder (default: /root/humid1_snapshots)
  -h, --help               Display this help message

File Naming:
  Virgin / Config Snapshot:  humid1_virgin_snapshot_<TIMESTAMP>.tar.gz
  Full System Snapshot:      humid1_full_snapshot_<TIMESTAMP>.tar.gz

Examples:
  $(basename "$0")                          # Fast config/code snapshot
  $(basename "$0") -v                       # Full snapshot including database & persistent volumes
  $(basename "$0") -v -u                    # Full snapshot + remote SFTP upload
  $(basename "$0") -u                       # Fast config snapshot + remote SFTP upload
EOF
}

# Parse command line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--include-volumes)
            INCLUDE_VOLUMES=true
            shift
            ;;
        -u|--upload)
            UPLOAD_SFTP=true
            shift
            ;;
        -d|--dir)
            HUMID1_DIR="$2"
            ENV_FILE="${HUMID1_DIR}/.env"
            shift 2
            ;;
        -e|--env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        -o|--output)
            BACKUP_DIR="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}[-] Unknown parameter: $1${NC}"
            exit 1
            ;;
    esac
done

# Source credentials from .env if available
if [ -f "$ENV_FILE" ]; then
    # Load SFTP_* and SMTP_* variables without altering non-exported values
    set -a
    # shellcheck disable=SC1090
    source <(grep -E '^(SFTP_|SMTP_)' "$ENV_FILE" 2>/dev/null || true)
    set +a
fi

# Fallback SFTP Configuration defaults
SFTP_HOST="${SFTP_HOST:-mastercontrol}"
SFTP_PORT="${SFTP_PORT:-2022}"
SFTP_USER="${SFTP_USER:-vps-backup}"
SFTP_KEY="${SFTP_KEY:-/root/.ssh/id_sftp_backup}"

# Ensure source directory exists
if [ ! -d "$HUMID1_DIR" ]; then
    echo -e "${RED}[-] Error: Source directory '$HUMID1_DIR' does not exist.${NC}"
    exit 1
fi

mkdir -p "$BACKUP_DIR"

if [ "$INCLUDE_VOLUMES" = true ]; then
    SNAPSHOT_TYPE="full"
else
    SNAPSHOT_TYPE="virgin"
fi

SNAPSHOT_NAME="humid1_${SNAPSHOT_TYPE}_snapshot_${TIMESTAMP}.tar.gz"
SNAPSHOT_PATH="${BACKUP_DIR}/${SNAPSHOT_NAME}"

echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}        HUMID1_OS SNAPSHOT CREATOR               ${NC}"
echo -e "${CYAN}=================================================${NC}"
echo -e "Source:           $HUMID1_DIR"
echo -e "Destination:      $SNAPSHOT_PATH"
echo -e "Snapshot Type:    ${SNAPSHOT_TYPE^^}"
echo -e "Volumes Included: $INCLUDE_VOLUMES\n"

if [ "$INCLUDE_VOLUMES" = true ]; then
    echo -e "${CYAN}[*] MODE: FULL SYSTEM BACKUP (Configs, Databases & Persistent Volumes)${NC}"
    TEMP_VOL_DIR="${BACKUP_DIR}/temp_volumes_${TIMESTAMP}"
    mkdir -p "$TEMP_VOL_DIR"
    trap 'rm -rf "$TEMP_VOL_DIR"' EXIT INT TERM

    # Current active volumes across the compose configuration
    VOLUMES=(
        "tb-postgres-data"
        "postgres-data"
        "humid1_postgres-data"
        "authentik-data"
        "humid1_authentik-data"
        "tb-ce-kafka-data"
        "kafka-data"
        "humid1_kafka-data"
        "nats-data"
        "humid1_nats-data"
        "cap-valkey-data"
        "valkey-data"
        "humid1_valkey-data"
        "caddy_data"
        "humid1_caddy_data"
        "caddy_config"
        "humid1_caddy_config"
    )

    ARCHIVED_COUNT=0
    for vol in "${VOLUMES[@]}"; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            echo -e "    -> Archiving volume: ${GREEN}$vol${NC}"
            docker run --rm \
                -v "${vol}:/volume:ro" \
                -v "${TEMP_VOL_DIR}:/backup" \
                alpine tar -czf "/backup/${vol}.tar.gz" -C /volume .
            ARCHIVED_COUNT=$((ARCHIVED_COUNT + 1))
        fi
    done

    echo -e "\n${CYAN}[*] Packaging project directory and $ARCHIVED_COUNT persistent volumes together...${NC}"
    tar -czf "$SNAPSHOT_PATH" \
        --exclude='.git' \
        -C "$(dirname "$HUMID1_DIR")" "$(basename "$HUMID1_DIR")" \
        -C "$BACKUP_DIR" "temp_volumes_${TIMESTAMP}"

    rm -rf "$TEMP_VOL_DIR"
    trap - EXIT INT TERM
else
    echo -e "${CYAN}[*] MODE: CONFIG & CODE SNAPSHOT (Deployment State & Secrets)${NC}"
    tar -czf "$SNAPSHOT_PATH" \
        --exclude='.git' \
        -C "$(dirname "$HUMID1_DIR")" "$(basename "$HUMID1_DIR")"
fi

echo -e "\n${GREEN}[+] Snapshot created successfully!${NC}"
echo -e "    File: $SNAPSHOT_NAME"
echo -e "    Size: $(du -h "$SNAPSHOT_PATH" | cut -f1)"

# SFTP Remote Upload Execution
if [ "$UPLOAD_SFTP" = true ]; then
    echo -e "\n${CYAN}=================================================${NC}"
    echo -e "${CYAN}        SFTP REMOTE ARCHIVE DISPATCH             ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo -e "Host:     $SFTP_HOST:$SFTP_PORT"
    echo -e "User:     $SFTP_USER"
    echo -e "Key:      $SFTP_KEY\n"

    if [ ! -f "$SFTP_KEY" ]; then
        echo -e "${RED}[-] Error: SSH Keyfile '$SFTP_KEY' was not found.${NC}"
        exit 1
    fi

    sftp -P "$SFTP_PORT" -i "$SFTP_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "${SFTP_USER}@${SFTP_HOST}" <<EOF
cd /
put "$SNAPSHOT_PATH"
bye
EOF
    echo -e "${GREEN}[+] Remote transfer to $SFTP_HOST complete!${NC}"
fi

echo -e "${CYAN}=================================================${NC}\n"