#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — System Uninstaller for GridBackup
# =============================================================================
# Reverses the installation performed by install.sh.
#
# Usage:
#   sudo ./uninstall.sh          # Removes everything except /etc/resticprofile/.env
#   sudo ./uninstall.sh --purge  # Removes everything including secrets
# =============================================================================
set -euo pipefail

# 1. Root Guard
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This uninstaller must be run as root (use: sudo ./uninstall.sh)" >&2
    exit 1
fi

PURGE=false
if [[ "${1:-}" == "--purge" ]]; then
    PURGE=true
    echo "!!! PURGE MODE ENABLED: Secrets in .env will be deleted !!!"
fi

echo ""
echo "--- Stopping and disabling backup timers..."
# Stop and disable known timers
systemctl stop resticprofile-backup@local.timer 2>/dev/null || true
systemctl disable resticprofile-backup@local.timer 2>/dev/null || true
systemctl stop resticprofile-backup@cloud.timer 2>/dev/null || true
systemctl disable resticprofile-backup@cloud.timer 2>/dev/null || true

echo "--- Removing systemd unit files..."
rm -f /etc/systemd/system/resticprofile-backup@.service
rm -f /etc/systemd/system/resticprofile-backup@.timer
rm -f /etc/systemd/system/resticprofile-backup@local.timer
rm -f /etc/systemd/system/resticprofile-backup@cloud.timer

echo "--- Removing global binary aliases..."
rm -f /usr/local/bin/agent-restore

echo "--- Cleaning up staging directory..."
rm -rf /var/tmp/backup_stage

echo "--- Removing configuration directory..."
if [ "$PURGE" = true ]; then
    rm -rf /etc/resticprofile
    echo "  [OK] /etc/resticprofile completely removed."
else
    # Delete everything in the config dir except the .env file
    if [ -d /etc/resticprofile ]; then
        find /etc/resticprofile -mindepth 1 -not -name ".env" -delete 2>/dev/null || true
        echo "  [OK] /etc/resticprofile contents removed. (.env preserved)"
    fi
fi

echo "--- Purging systemd memory..."
systemctl daemon-reload
systemctl reset-failed

echo ""
echo "=== Uninstallation Completed Successfully ==="
echo ""
