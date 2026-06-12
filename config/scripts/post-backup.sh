#!/usr/bin/env bash
# =============================================================================
# post-backup.sh — Rich Telemetry Routing & Notifications
# =============================================================================
# Upgraded for headless automation and deep status reporting.
# =============================================================================
set -euo pipefail

# 0. Import Environment Directives
if [ -f /etc/resticprofile/.env ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' /etc/resticprofile/.env | xargs)
fi

# Captured from resticprofile environment
PROFILE="${RESTICPROFILE_NAME:-unknown}"
EXIT_CODE="${PROFILE_COMMAND_EXIT_CODE:-0}"
ERROR_COUNT="${PROFILE_ERROR_COUNT:-0}"
REPO="${RESTIC_REPOSITORY:-unknown}"
TIMESTAMP="[$(date +'%Y-%m-%d %H:%M:%S')]"

# 1. Failure Detection Gate
if [ "$EXIT_CODE" -ne 0 ] || [ "$ERROR_COUNT" -gt 0 ]; then
    echo "${TIMESTAMP} CRITICAL: Profile [${PROFILE}] reported failure (Exit: ${EXIT_CODE}, Errors: ${ERROR_COUNT})" >&2

    # Ping Healthchecks.io Failure
    curl -fsS --retry 3 "${HEALTHCHECKS_IO_URL}/fail" || true

    # Dispatch High-Priority Notification (Priority 5)
    curl -s \
         -H "Title: BACKUP FAILED - ${CLIENT_NAME}" \
         -H "Priority: 5" \
         -d "Host [${HOST_IDENTIFIER}] backup pipeline reported a failure.
Status: FAILED
Profile: ${PROFILE}
Exit Code: ${EXIT_CODE}
Errors: ${ERROR_COUNT}
Time: $(date +'%Y-%m-%d %H:%M %Z')" \
         "${NOTIFY_WEBHOOK_URL}" || true
else
    # 2. Success Path — Metadata Extraction
    echo "${TIMESTAMP} SUCCESS: Profile [${PROFILE}] completed cleanly."

    # Ping Healthchecks.io Success
    curl -fsS --retry 3 "${HEALTHCHECKS_IO_URL}" || true

    # Race Condition Guard — allow engine to release locks
    sleep 3

    # Extract Metadata
    SNAPSHOT_ID=$(resticprofile --config /etc/resticprofile/profiles.yaml --name "$PROFILE" snapshots --latest 1 --json | jq -r '.[0].short_id // "unknown"')
    COMPLETION_TIME=$(date +'%Y-%m-%d %H:%M %Z')

    # Dispatch Rich Telemetry Notification
    curl -s \
         -H "Title: Backup Successful - ${CLIENT_NAME}" \
         -H "Priority: default" \
         -d "Host [${HOST_IDENTIFIER}] completed a scheduled backup.
Status: SUCCESS
Profile: ${PROFILE}
Repository: ${REPO}
Snapshot ID: ${SNAPSHOT_ID}
Duration: See systemd logs for exact timing
Completed At: ${COMPLETION_TIME}" \
         "${NOTIFY_WEBHOOK_URL}" || true
fi

# 3. Wipe Staging Area (Always Cleanup)
if [ -n "${TEMPORARY_DUMP_DIR:-}" ]; then
    rm -rf "${TEMPORARY_DUMP_DIR:?}"/*
fi
