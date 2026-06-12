#!/usr/bin/env bash
# =============================================================================
# restore.sh — Interactive Disaster Recovery Orchestrator
# =============================================================================
# Provides a guided, interactive recovery workflow for the client-backup-agent.
# Handles snapshot exploration, dry-runs, target path routing, container
# lifecycle isolation, and SQL reinsertion for PostgreSQL and MySQL/MariaDB.
#
# Global alias (created by install.sh):
#   sudo agent-restore
#
# Responsibilities:
#   1. Privilege and environment validation
#   2. Backend profile selection (local / cloud)
#   3. Snapshot listing and selection
#   4. Restore target path configuration
#   5. Dry-run verification gate
#   6. Service impact analysis — optional container shutdown
#   7. resticprofile restore execution
#   8. Database SQL reinsertion with conflict resolution:
#        - OVERWRITE    : drop and reimport (destructive, explicit consent required)
#        - TIMESTAMP    : import into a new database named <db>_restored_<timestamp>
#        - SKIP         : leave databases untouched
#
# Exit codes:
#   0  — Recovery completed successfully (or dry-run completed cleanly)
#   1  — Missing privileges or environment
#   2  — Invalid user input
#   3  — resticprofile restore command failed
#   4  — SQL reinsertion failed for one or more containers
# =============================================================================
set -euo pipefail

# =============================================================================
# Colour helpers (degrade gracefully in non-TTY environments)
# =============================================================================
if [ -t 1 ]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

log_info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_step()  { echo -e "\n${BOLD}--- $* ---${RESET}"; }

# =============================================================================
# 0. Environment Import
# =============================================================================
if [ -f /etc/resticprofile/.env ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' /etc/resticprofile/.env | xargs)
fi

# =============================================================================
# Banner
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}=================================================================${RESET}"
echo -e "${BOLD}${CYAN}        RESTIC BACKUP AGENT — DISASTER RECOVERY MATRIX          ${RESET}"
echo -e "${BOLD}${CYAN}=================================================================${RESET}"
echo ""
echo "  Client   : ${CLIENT_NAME:-unknown}"
echo "  Host     : ${HOST_IDENTIFIER:-$(hostname)}"
echo "  Started  : $(date +'%Y-%m-%d %H:%M:%S %Z')"
echo ""

# =============================================================================
# 1. Privilege Guard
# =============================================================================
if [ "$EUID" -ne 0 ]; then
    log_error "Recovery matrix requires root privileges."
    log_error "Re-run with: sudo agent-restore"
    exit 1
fi

# Verify critical binaries are available
for BIN in resticprofile docker curl; do
    if ! command -v "$BIN" &>/dev/null; then
        log_error "Required binary not found in PATH: $BIN"
        exit 1
    fi
done

# =============================================================================
# 2. Backend Profile Selection
# =============================================================================
log_step "Step 1 of 7 — Select Backup Repository"
echo ""
echo "  1) local  — On-disk repository (${LOCAL_REPO_PATH:-not configured})"
echo "  2) cloud  — Remote S3 repository (${REMOTE_S3_REPO:-not configured})"
echo ""

PROFILE=""
while true; do
    read -r -p "Select profile [1/2]: " PROFILE_CHOICE
    case "$PROFILE_CHOICE" in
        1) PROFILE="local";  break ;;
        2) PROFILE="cloud";  break ;;
        *) log_warn "Invalid selection. Enter 1 for local or 2 for cloud." ;;
    esac
done

log_ok "Using profile: ${BOLD}${PROFILE}${RESET}"

# =============================================================================
# 3. Snapshot Listing & Selection
# =============================================================================
log_step "Step 2 of 7 — Select Snapshot"
echo ""
log_info "Fetching snapshots for profile [${PROFILE}]..."
echo ""

if ! /usr/local/bin/resticprofile \
        --config /etc/resticprofile/profiles.yaml \
        --name "$PROFILE" \
        snapshots 2>&1; then
    log_error "Failed to retrieve snapshots. Verify repository is initialised and credentials are correct."
    exit 3
fi

echo ""
read -r -p "Enter Snapshot ID to restore (or type 'latest'): " SNAPSHOT_ID
SNAPSHOT_ID="${SNAPSHOT_ID// /}"  # strip accidental whitespace

if [ -z "$SNAPSHOT_ID" ]; then
    log_error "Snapshot ID cannot be blank."
    exit 2
fi

log_ok "Target snapshot: ${BOLD}${SNAPSHOT_ID}${RESET}"

# =============================================================================
# 4. Restore Target Path
# =============================================================================
log_step "Step 3 of 7 — Configure Restore Destination"
echo ""
log_warn "Restoring directly to '/' can overwrite active system binaries!"
log_info "Safe default: /var/tmp/restore_stage — inspect files before moving."
echo ""

read -r -p "Target destination path [/var/tmp/restore_stage]: " TARGET_DEST
TARGET_DEST="${TARGET_DEST:-/var/tmp/restore_stage}"

# Detect risky targets
RISKY_TARGET=false
if [[ "$TARGET_DEST" == "/" || "$TARGET_DEST" == "/etc" || "$TARGET_DEST" == "/usr"* || "$TARGET_DEST" == "/bin"* ]]; then
    RISKY_TARGET=true
    echo ""
    log_warn "${BOLD}HIGH RISK:${RESET} You have selected a live system path: ${TARGET_DEST}"
    log_warn "This can overwrite running binaries and corrupt the system."
    read -r -p "Type 'I UNDERSTAND' to confirm this high-risk restore: " RISK_CONFIRM
    if [ "$RISK_CONFIRM" != "I UNDERSTAND" ]; then
        log_error "Risk confirmation not accepted. Aborting."
        exit 2
    fi
fi

mkdir -p "$TARGET_DEST"
log_ok "Restore destination: ${BOLD}${TARGET_DEST}${RESET}"

# =============================================================================
# 5. Dry-Run Gate
# =============================================================================
log_step "Step 4 of 7 — Dry-Run Verification"
echo ""
echo "  1) YES — Execute a dry-run first (recommended: lists files without writing)"
echo "  2) NO  — Write directly to the target destination"
echo ""

DR_FLAG=""
while true; do
    read -r -p "Execute dry-run first? [1/2]: " DR_CHOICE
    case "$DR_CHOICE" in
        1) DR_FLAG="--dry-run"; break ;;
        2) DR_FLAG="";           break ;;
        *) log_warn "Enter 1 (dry-run) or 2 (live write)." ;;
    esac
done

# =============================================================================
# 6. Container Lifecycle Isolation
# =============================================================================
STOP_DOCKER="n"
CONTAINERS_STOPPED=()

if [ -z "$DR_FLAG" ]; then
    log_step "Step 5 of 7 — Service Impact Analysis"
    echo ""

    RUNNING_CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
    CONTAINER_COUNT=$(echo "$RUNNING_CONTAINERS" | grep -c '\S' || true)

    if [ "$CONTAINER_COUNT" -gt 0 ]; then
        log_warn "${CONTAINER_COUNT} running container(s) detected:"
        echo "$RUNNING_CONTAINERS" | sed 's/^/    → /'
        echo ""

        if [[ "$TARGET_DEST" == "/" || "$TARGET_DEST" == "/var/lib/docker/volumes"* ]] || [ "$RISKY_TARGET" == "true" ]; then
            log_warn "Destructive target path detected. Stopping containers is strongly recommended"
            log_warn "to prevent split-brain database states during volume restoration."
        fi

        echo ""
        read -r -p "Stop all running containers before restoration? (y/N): " STOP_DOCKER
        STOP_DOCKER="${STOP_DOCKER:-n}"

        if [[ "$STOP_DOCKER" =~ ^[Yy]$ ]]; then
            log_info "Suspending all running application stacks..."
            while IFS= read -r CNAME; do
                [ -z "$CNAME" ] && continue
                docker stop "$CNAME" && CONTAINERS_STOPPED+=("$CNAME")
                log_ok "Stopped: $CNAME"
            done <<< "$RUNNING_CONTAINERS"
        fi
    else
        log_info "No running containers detected. Skipping isolation step."
    fi
else
    log_step "Step 5 of 7 — Service Impact Analysis"
    log_info "Dry-run mode: container isolation skipped."
fi

# =============================================================================
# 7. Execute Restore
# =============================================================================
log_step "Step 6 of 7 — Restore Execution"
echo ""

RESTORE_CMD=(
    /usr/local/bin/resticprofile
    --config /etc/resticprofile/profiles.yaml
    --name "$PROFILE"
    restore "$SNAPSHOT_ID"
    --target "$TARGET_DEST"
)

[ -n "$DR_FLAG" ] && RESTORE_CMD+=(--dry-run)

log_info "Running: ${RESTORE_CMD[*]}"
echo ""

if ! "${RESTORE_CMD[@]}"; then
    log_error "resticprofile restore command failed."

    # Restart stopped containers so the system is not left in a half-state
    if [ "${#CONTAINERS_STOPPED[@]}" -gt 0 ]; then
        log_warn "Restarting previously stopped containers after failed restore..."
        for CNAME in "${CONTAINERS_STOPPED[@]}"; do
            docker start "$CNAME" && log_ok "Restarted: $CNAME" || log_warn "Could not restart: $CNAME"
        done
    fi
    exit 3
fi

if [ -n "$DR_FLAG" ]; then
    echo ""
    log_ok "DRY-RUN COMPLETE. No data was written to the host filesystem."
    echo ""
    echo -e "${BOLD}${CYAN}=================================================================${RESET}"
    echo -e "${BOLD}${CYAN}   DRY-RUN FINISHED — Re-run without dry-run to apply changes   ${RESET}"
    echo -e "${BOLD}${CYAN}=================================================================${RESET}"
    exit 0
fi

log_ok "File blocks successfully written to: ${TARGET_DEST}"

# =============================================================================
# 8. Database SQL Reinsertion
# =============================================================================
STAGE_PATH="${TARGET_DEST}/var/tmp/backup_stage"

log_step "Step 7 of 7 — Database Reinsertion"
echo ""

if [ ! -d "$STAGE_PATH" ]; then
    log_info "No database dump staging area found in the restored snapshot."
    log_info "Expected path: ${STAGE_PATH}"
    log_info "Skipping database reinsertion."
else
    DUMP_COUNT=$(find "$STAGE_PATH" -maxdepth 1 -name '*.sql' 2>/dev/null | wc -l)

    if [ "$DUMP_COUNT" -eq 0 ]; then
        log_info "Staging directory exists but contains no .sql dump files."
    else
        log_info "Found ${DUMP_COUNT} SQL dump file(s) in: ${STAGE_PATH}"
        find "$STAGE_PATH" -maxdepth 1 -name '*.sql' | sed 's/^/    → /'
        echo ""

        read -r -p "Reinject SQL dumps into running database containers? (y/N): " RESTORE_DBS
        RESTORE_DBS="${RESTORE_DBS:-n}"

        if [[ "$RESTORE_DBS" =~ ^[Yy]$ ]]; then

            # ------------------------------------------------------------------
            # Conflict resolution strategy — asked once, applied to all databases
            # ------------------------------------------------------------------
            echo ""
            echo "  How should conflicts be handled if the target database already exists?"
            echo ""
            echo "  1) TIMESTAMP_COPY  — Import into a new database named <db>_restored_<timestamp>"
            echo "                       Safe default: existing data is never touched."
            echo "  2) OVERWRITE       — Drop the existing database and reimport from the dump."
            echo "                       ${RED}DESTRUCTIVE${RESET}: all live data changes since the snapshot"
            echo "                       will be permanently lost."
            echo "  3) SKIP            — Leave all databases untouched; only restore flat files."
            echo ""

            DB_CONFLICT_MODE=""
            RESTORE_TIMESTAMP=$(date +'%Y%m%d_%H%M%S')

            while true; do
                read -r -p "Select conflict resolution [1/2/3]: " CONFLICT_CHOICE
                case "$CONFLICT_CHOICE" in
                    1) DB_CONFLICT_MODE="TIMESTAMP_COPY"; break ;;
                    2) DB_CONFLICT_MODE="OVERWRITE";
                       echo ""
                       log_warn "${BOLD}OVERWRITE mode selected.${RESET}"
                       read -r -p "Type 'OVERWRITE' to confirm destruction of existing database data: " OW_CONFIRM
                       if [ "$OW_CONFIRM" == "OVERWRITE" ]; then
                           break
                       else
                           log_warn "Confirmation not accepted. Please re-select."
                       fi
                       ;;
                    3) DB_CONFLICT_MODE="SKIP"; break ;;
                    *) log_warn "Enter 1, 2, or 3." ;;
                esac
            done

            if [ "$DB_CONFLICT_MODE" == "SKIP" ]; then
                log_info "Database reinsertion skipped by operator choice."
            else
                # Restart stopped containers so DB listeners are available
                if [ "${#CONTAINERS_STOPPED[@]}" -gt 0 ]; then
                    log_info "Restarting containers to open database listener sockets..."
                    for CNAME in "${CONTAINERS_STOPPED[@]}"; do
                        docker start "$CNAME" && log_ok "Started: $CNAME" || log_warn "Could not start: $CNAME"
                    done
                    log_info "Waiting 15 seconds for engines to initialise..."
                    sleep 15
                fi

                DB_ERRORS=0

                # --------------------------------------------------------------
                # PostgreSQL Reinsertion
                # --------------------------------------------------------------
                while IFS= read -r -d '' DUMP_FILE; do
                    CONTAINER_NAME=$(basename "$DUMP_FILE" _postgres.sql)

                    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
                        log_warn "SKIPPED: Container [$CONTAINER_NAME] is not running."
                        continue
                    fi

                    log_info "Processing PostgreSQL dump for container: ${CONTAINER_NAME}"

                    # Resolve superuser
                    DB_USER=$(docker inspect \
                        --format='{{range .Config.Env}}{{.}} {{end}}' "$CONTAINER_NAME" \
                        | tr ' ' '\n' \
                        | grep '^POSTGRES_USER=' \
                        | cut -d= -f2 \
                        | head -n1)
                    DB_USER="${DB_USER:-postgres}"

                    case "$DB_CONFLICT_MODE" in
                        TIMESTAMP_COPY)
                            # Create a new empty database with a timestamp suffix
                            RESTORED_DB="restored_${RESTORE_TIMESTAMP}"
                            log_info "Creating target database: ${RESTORED_DB}"
                            docker exec "$CONTAINER_NAME" \
                                psql -U "$DB_USER" -c "CREATE DATABASE \"${RESTORED_DB}\";" 2>/dev/null || true

                            # pg_dumpall produces a cluster dump; filter to non-role SQL
                            # and pipe into the new database for a best-effort import
                            if ! docker exec -i "$CONTAINER_NAME" \
                                    psql -U "$DB_USER" -d "$RESTORED_DB" \
                                    < "$DUMP_FILE"; then
                                log_warn "PostgreSQL reinsertion produced errors for [$CONTAINER_NAME]. \
Check container logs."
                                DB_ERRORS=$((DB_ERRORS + 1))
                            else
                                log_ok "PostgreSQL data imported → ${RESTORED_DB} in [${CONTAINER_NAME}]"
                            fi
                            ;;

                        OVERWRITE)
                            log_warn "OVERWRITE: Dropping all databases in [${CONTAINER_NAME}] and reimporting..."
                            if ! docker exec -i "$CONTAINER_NAME" \
                                    psql -U "$DB_USER" < "$DUMP_FILE"; then
                                log_error "PostgreSQL OVERWRITE failed for [$CONTAINER_NAME]."
                                DB_ERRORS=$((DB_ERRORS + 1))
                            else
                                log_ok "PostgreSQL cluster reimported into [${CONTAINER_NAME}]"
                            fi
                            ;;
                    esac

                done < <(find "$STAGE_PATH" -maxdepth 1 -name '*_postgres.sql' -print0 2>/dev/null)

                # --------------------------------------------------------------
                # MySQL / MariaDB Reinsertion
                # --------------------------------------------------------------
                while IFS= read -r -d '' DUMP_FILE; do
                    CONTAINER_NAME=$(basename "$DUMP_FILE" _mysql.sql)

                    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
                        log_warn "SKIPPED: Container [$CONTAINER_NAME] is not running."
                        continue
                    fi

                    log_info "Processing MySQL/MariaDB dump for container: ${CONTAINER_NAME}"

                    # Resolve root password from the container's environment
                    DB_PASS=$(docker inspect \
                        --format='{{range .Config.Env}}{{.}} {{end}}' "$CONTAINER_NAME" \
                        | tr ' ' '\n' \
                        | grep -E '^(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD)=' \
                        | cut -d= -f2 \
                        | head -n1 || true)

                    # Build mysql exec prefix
                    if [ -n "$DB_PASS" ]; then
                        MYSQL_EXEC=(docker exec -i "$CONTAINER_NAME" mysql -uroot -p"${DB_PASS}")
                    else
                        # Fall back to socket / env-injected auth inside the container
                        MYSQL_EXEC=(docker exec -i "$CONTAINER_NAME" \
                            sh -c 'exec mysql -uroot -p"${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}"')
                    fi

                    case "$DB_CONFLICT_MODE" in
                        TIMESTAMP_COPY)
                            RESTORED_DB="restored_${RESTORE_TIMESTAMP}"
                            log_info "Creating target database: ${RESTORED_DB}"
                            "${MYSQL_EXEC[@]}" \
                                -e "CREATE DATABASE IF NOT EXISTS \`${RESTORED_DB}\`;" 2>/dev/null || true

                            # Filter to per-database statements and import into the new DB
                            if ! "${MYSQL_EXEC[@]}" "$RESTORED_DB" < "$DUMP_FILE"; then
                                log_warn "MySQL/MariaDB reinsertion produced errors for [$CONTAINER_NAME]."
                                DB_ERRORS=$((DB_ERRORS + 1))
                            else
                                log_ok "MySQL/MariaDB data imported → ${RESTORED_DB} in [${CONTAINER_NAME}]"
                            fi
                            ;;

                        OVERWRITE)
                            log_warn "OVERWRITE: Reimporting all databases into [${CONTAINER_NAME}]..."
                            if ! "${MYSQL_EXEC[@]}" < "$DUMP_FILE"; then
                                log_error "MySQL/MariaDB OVERWRITE failed for [$CONTAINER_NAME]."
                                DB_ERRORS=$((DB_ERRORS + 1))
                            else
                                log_ok "MySQL/MariaDB cluster reimported into [${CONTAINER_NAME}]"
                            fi
                            ;;
                    esac

                done < <(find "$STAGE_PATH" -maxdepth 1 -name '*_mysql.sql' -print0 2>/dev/null)

                # Report aggregate DB errors
                if [ "$DB_ERRORS" -gt 0 ]; then
                    log_warn "${DB_ERRORS} database reinsertion error(s) encountered."
                    log_warn "Check container logs: docker logs <container-name>"
                fi
            fi  # end SKIP guard
        fi  # end RESTORE_DBS guard
    fi  # end DUMP_COUNT guard
fi  # end STAGE_PATH guard

# =============================================================================
# Final Summary
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}=================================================================${RESET}"
echo -e "${BOLD}${GREEN}       DISASTER RECOVERY COMPLETED SUCCESSFULLY                 ${RESET}"
echo -e "${BOLD}${GREEN}=================================================================${RESET}"
echo ""
echo "  Profile      : ${PROFILE}"
echo "  Snapshot     : ${SNAPSHOT_ID}"
echo "  Destination  : ${TARGET_DEST}"
echo "  DB mode      : ${DB_CONFLICT_MODE:-N/A}"
echo "  Completed    : $(date +'%Y-%m-%d %H:%M:%S %Z')"
echo ""

if [ "$TARGET_DEST" != "/" ]; then
    log_info "Next steps:"
    echo "    1. Inspect restored files at: ${TARGET_DEST}"
    echo "    2. Move or rsync files to their live paths after verification:"
    echo "       rsync -avP ${TARGET_DEST}/etc/ /etc/"
    echo "    3. Restart any application stacks as needed:"
    echo "       docker compose -f /opt/myapp/docker-compose.yml up -d"
fi
