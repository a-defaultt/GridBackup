#!/usr/bin/env bash
# =============================================================================
# pre-backup.sh — Pre-flight Checks, DB Autodiscovery & Staging
# =============================================================================
# Executed by resticprofile's run-before hook before every backup snapshot.
#
# Responsibilities:
#   1. Import runtime environment variables from /etc/resticprofile/.env
#   2. Verify the host has sufficient free disk space to proceed safely
#   3. Re-initialise a clean transient staging directory for database dumps
#   4. Autodiscover running database containers via Docker label inspection
#   5. Perform atomic logical dumps for PostgreSQL, MySQL, and MariaDB engines
#   6. Alert on any database containers lacking the mandatory backup.db label
#
# Exit codes:
#   0  — All pre-flight checks passed, backup can proceed
#   1  — Disk space below MIN_FREE_DISK_PERCENT threshold
#   2  — PostgreSQL dump failed or exceeded MAX_DB_DUMP_DURATION_MINUTES
#   3  — MySQL / MariaDB dump failed or exceeded MAX_DB_DUMP_DURATION_MINUTES
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# 0. Import Environment Directives
# -----------------------------------------------------------------------------
if [ -f /etc/resticprofile/.env ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' /etc/resticprofile/.env | xargs)
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting pre-backup procedures..."

# -----------------------------------------------------------------------------
# 1. Host Infrastructure Safety Verification
# -----------------------------------------------------------------------------
FREE_SPACE_PCT=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
USED_THRESHOLD=$((100 - MIN_FREE_DISK_PERCENT))

if [ "$FREE_SPACE_PCT" -gt "$USED_THRESHOLD" ]; then
    echo "CRITICAL ERROR: Host storage space has fallen below critical threshold \
(${MIN_FREE_DISK_PERCENT}% free). Aborting backup sequence." >&2
    exit 1
fi

echo "Disk safety check passed: ${FREE_SPACE_PCT}% used (threshold: ${USED_THRESHOLD}%)"

# Reinitialise the transient staging area safely
rm -rf "${TEMPORARY_DUMP_DIR}"
mkdir -p "${TEMPORARY_DUMP_DIR}"
chmod 700 "${TEMPORARY_DUMP_DIR}"
echo "Staging directory initialised: ${TEMPORARY_DUMP_DIR}"

# -----------------------------------------------------------------------------
# 2. Complete Database Container Autodiscovery Grid
# -----------------------------------------------------------------------------
ALL_CONTAINERS=$(docker ps --format "{{.Names}}")
MUTED_WARNINGS=0

for CONTAINER in $ALL_CONTAINERS; do
    IMAGE_NAME=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER")
    BACKUP_LABEL=$(docker inspect --format='{{index .Config.Labels "backup.db"}}' "$CONTAINER")

    # Match known database runtime image signatures (partial match is intentional)
    if [[ "$IMAGE_NAME" =~ (postgres|postgres:|mysql|mysql:|mariadb|mariadb:) ]]; then

        # ------------------------------------------------------------------
        # Guard Clause: Verify the container carries the explicit declaration
        # ------------------------------------------------------------------
        if [ -z "$BACKUP_LABEL" ] || [ "$BACKUP_LABEL" == "<no value>" ]; then
            echo "WARNING: Untagged database engine discovered in container [$CONTAINER]. \
Backup state is unknown!" >&2

            curl -s \
                 -H "Title: UNPROTECTED DATABASE FOUND" \
                 -H "Priority: high" \
                 -H "Tags: warning,database" \
                 -d "Container [$CONTAINER] matches a database image signature \
but lacks the required 'backup.db' label. Please label it with \
'backup.db=postgres|mysql|mariadb' or 'backup.db=skip' to silence this alert." \
                 "${NOTIFY_WEBHOOK_URL}" || true

            MUTED_WARNINGS=$((MUTED_WARNINGS + 1))
            continue
        fi

        # Skip containers that have been explicitly opted out
        if [ "$BACKUP_LABEL" == "skip" ]; then
            echo "Container [$CONTAINER] explicitly opted out via backup.db=skip. Skipping."
            continue
        fi

        # ------------------------------------------------------------------
        # 3. Parameterised Isolation & Dump Engines
        # ------------------------------------------------------------------
        case "$BACKUP_LABEL" in

            # ----------------------------------------------------------------
            # PostgreSQL — transactional atomic cluster dump via pg_dumpall
            # ----------------------------------------------------------------
            "postgres")
                echo "Executing transactional atomic extraction for Postgres target [$CONTAINER]..."

                # Resolve the database superuser; fall back to the default
                DB_USER=$(docker inspect \
                    --format='{{range .Config.Env}}{{.}} {{end}}' "$CONTAINER" \
                    | tr ' ' '\n' \
                    | grep '^POSTGRES_USER=' \
                    | cut -d= -f2 \
                    | head -n1)
                DB_USER="${DB_USER:-postgres}"

                DUMP_FILE="${TEMPORARY_DUMP_DIR}/${CONTAINER}_postgres.sql"

                if ! timeout "${MAX_DB_DUMP_DURATION_MINUTES}m" \
                     docker exec "$CONTAINER" pg_dumpall -U "$DB_USER" \
                     > "$DUMP_FILE"; then
                    echo "ERROR: PostgreSQL logical dump failed or timed out on \
container [$CONTAINER]" >&2
                    exit 2
                fi

                echo "PostgreSQL dump complete: ${DUMP_FILE} \
($(du -sh "$DUMP_FILE" | cut -f1))"
                ;;

            # ----------------------------------------------------------------
            # MySQL / MariaDB — non-blocking dump with single-transaction
            # ----------------------------------------------------------------
            "mysql"|"mariadb")
                echo "Executing locks-deferred application dump for \
MySQL/MariaDB target [$CONTAINER]..."

                DUMP_FILE="${TEMPORARY_DUMP_DIR}/${CONTAINER}_mysql.sql"

                # Primary strategy: read root password from env inside the container
                if ! timeout "${MAX_DB_DUMP_DURATION_MINUTES}m" \
                     docker exec "$CONTAINER" \
                     sh -c 'exec mysqldump \
                         --all-databases \
                         --single-transaction \
                         --quick \
                         -uroot \
                         -p"${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}"' \
                     > "$DUMP_FILE" 2>/dev/null; then

                    # Fallback: attempt without explicit password (unix socket auth)
                    echo "Primary dump strategy failed; retrying with socket auth..." >&2
                    if ! timeout "${MAX_DB_DUMP_DURATION_MINUTES}m" \
                         docker exec "$CONTAINER" \
                         mysqldump \
                             --all-databases \
                             --single-transaction \
                             --quick \
                         > "$DUMP_FILE"; then
                        echo "ERROR: MySQL/MariaDB dump failed or timed out on \
container [$CONTAINER]" >&2
                        exit 3
                    fi
                fi

                echo "MySQL/MariaDB dump complete: ${DUMP_FILE} \
($(du -sh "$DUMP_FILE" | cut -f1))"
                ;;

            *)
                echo "WARNING: Container [$CONTAINER] has backup.db=${BACKUP_LABEL} \
which is not a recognised engine. Skipping dump." >&2
                ;;
        esac
    fi
done

if [ "$MUTED_WARNINGS" -gt 0 ]; then
    echo "WARNING: ${MUTED_WARNINGS} unlabelled database container(s) detected. \
Review notifications." >&2
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Pre-backup processing successfully finished."
