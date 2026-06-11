#!/usr/bin/env bash
# =============================================================================
# post-backup.sh — Telemetry Routing, Notifications & Cleanup
# =============================================================================
# Executed by resticprofile's run-after and run-after-fail hooks.
#
# Usage:
#   post-backup.sh success    # Called via run-after on clean backup completion
#   post-backup.sh failure    # Called via run-after-fail on any pipeline error
#
# Responsibilities:
#   1. Import runtime environment variables from /etc/resticprofile/.env
#   2. Ping Healthchecks.io (pass or fail signal) for uptime monitoring
#   3. Push a human-readable notification to the ntfy.sh webhook channel
#   4. Safely wipe transient database dump files from the staging directory
#
# Exit codes:
#   0  — Post-backup procedures completed (notification failures are non-fatal)
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# 0. Import Environment Directives
# -----------------------------------------------------------------------------
if [ -f /etc/resticprofile/.env ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' /etc/resticprofile/.env | xargs)
fi

STATUS="${1:-failure}"
TIMESTAMP="[$(date +'%Y-%m-%d %H:%M:%S')]"

# -----------------------------------------------------------------------------
# 1. Route on backup outcome
# -----------------------------------------------------------------------------
if [ "$STATUS" == "success" ]; then
    echo "${TIMESTAMP} Backup executed successfully. Dispatching telemetry pings."

    # --- Healthchecks.io: success ping ---------------------------------------
    curl -fsS --retry 3 "${HEALTHCHECKS_IO_URL}" || \
        echo "WARNING: Healthchecks.io success ping failed (non-fatal)." >&2

    # --- ntfy.sh: success notification ---------------------------------------
    curl -s \
         -H "Title: Backup Successful — ${CLIENT_NAME}" \
         -H "Priority: default" \
         -H "Tags: white_check_mark,automated" \
         -d "Host [${HOST_IDENTIFIER}] completed backup to local and cloud \
repositories successfully at $(date +'%Y-%m-%d %H:%M %Z')." \
         "${NOTIFY_WEBHOOK_URL}" || \
        echo "WARNING: ntfy.sh success notification failed (non-fatal)." >&2

else
    echo "${TIMESTAMP} CRITICAL ERROR: Backup pipeline reported an operational failure." >&2

    # --- Healthchecks.io: failure signal -------------------------------------
    curl -fsS --retry 3 "${HEALTHCHECKS_IO_URL}/fail" || \
        echo "WARNING: Healthchecks.io failure signal failed (non-fatal)." >&2

    # --- ntfy.sh: critical failure alert -------------------------------------
    curl -s \
         -H "Title: BACKUP CRITICAL FAILURE — ${CLIENT_NAME}" \
         -H "Priority: max" \
         -H "Tags: x,skull,fire" \
         -d "Host [${HOST_IDENTIFIER}] backup pipeline failed at \
$(date +'%Y-%m-%d %H:%M %Z'). \
Review logs immediately:
  journalctl -u resticprofile-backup@local.service -n 100 --no-pager
  journalctl -u resticprofile-backup@cloud.service -n 100 --no-pager" \
         "${NOTIFY_WEBHOOK_URL}" || \
        echo "WARNING: ntfy.sh failure notification failed (non-fatal)." >&2
fi

# -----------------------------------------------------------------------------
# 2. Wipe Transient Staging Area
# -----------------------------------------------------------------------------
# The :? guard prevents accidental deletion if the variable is unset or empty
if [ -n "${TEMPORARY_DUMP_DIR:-}" ]; then
    rm -rf "${TEMPORARY_DUMP_DIR:?}"/*
    echo "${TIMESTAMP} Staging directory cleared: ${TEMPORARY_DUMP_DIR}"
else
    echo "WARNING: TEMPORARY_DUMP_DIR is not set; skipping cleanup." >&2
fi

echo "${TIMESTAMP} Post-backup procedures completed with status: ${STATUS}"
