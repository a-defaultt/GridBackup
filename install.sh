#!/usr/bin/env bash
# =============================================================================
# install.sh — Idempotent System Installer & Supervisor
# =============================================================================
# Installs and configures the client backup agent on any Debian/Ubuntu-family
# or RHEL/Fedora-family host running systemd and Docker.
#
# This script is fully IDEMPOTENT — safe to re-run after configuration
# changes or binary upgrades without destroying existing state.
#
# What it does:
#   1. Validates the required host primitives are present (curl, jq, docker …)
#   2. Downloads and installs restic + resticprofile if not already present
#   3. Copies config files into /etc/resticprofile/ with correct permissions
#   4. Deploys .env from local .env file (or .env.template as a first-run stub)
#   5. Generates systemd template service + per-profile timer units
#   6. Enables and starts the local (02:00) and cloud (04:00) backup timers
#
# Usage:
#   sudo ./install.sh
#
# Requirements:
#   - Root / sudo access
#   - systemd-based Linux distribution
#   - Docker installed and daemon running
#   - Internet access for binary downloads (or pre-placed binaries in PATH)
# =============================================================================
set -euo pipefail

# =============================================================================
# 0. Privilege Guard
# =============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This installer must be run as root (use: sudo ./install.sh)" >&2
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║       Client Backup Agent — System Installer                    ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# 1. Dependency Validation Grid
# =============================================================================
echo "--- [1/6] Validating host dependencies..."
DEPENDENCIES=(curl jq docker sed grep awk bzip2)

for CMD in "${DEPENDENCIES[@]}"; do
    if ! command -v "$CMD" &>/dev/null; then
        echo "ERROR: Missing required system primitive: '$CMD'." >&2
        echo "       Install it via your package manager before running this script." >&2
        exit 1
    fi
    echo "  ✓ $CMD"
done

# =============================================================================
# 2. Binary Acquisition — restic + resticprofile
# =============================================================================
echo ""
echo "--- [2/6] Deploying backup engine binaries..."

RESTIC_VERSION="0.17.0"
RESTICPROFILE_VERSION="0.31.0"

ARCH="amd64"  # Adjust to arm64 if deploying on ARM hardware

# --- restic -----------------------------------------------------------------
if command -v restic &>/dev/null; then
    INSTALLED_RESTIC=$(restic version 2>/dev/null | awk '{print $2}' | head -n1)
    echo "  ✓ restic already installed (version: ${INSTALLED_RESTIC})"
else
    echo "  ↓ Downloading restic v${RESTIC_VERSION}..."
    curl -fsSL \
        "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${ARCH}.bz2" \
        | bunzip2 > /usr/local/bin/restic
    chmod +x /usr/local/bin/restic
    echo "  ✓ restic v${RESTIC_VERSION} installed to /usr/local/bin/restic"
fi

# --- resticprofile -----------------------------------------------------------
if command -v resticprofile &>/dev/null; then
    INSTALLED_RP=$(resticprofile version 2>/dev/null | head -n1)
    echo "  ✓ resticprofile already installed (${INSTALLED_RP})"
else
    echo "  ↓ Downloading resticprofile v${RESTICPROFILE_VERSION}..."
    curl -fsSL \
        "https://github.com/creativeprojects/resticprofile/releases/download/v${RESTICPROFILE_VERSION}/resticprofile_${RESTICPROFILE_VERSION}_linux_${ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin/ resticprofile
    chmod +x /usr/local/bin/resticprofile
    echo "  ✓ resticprofile v${RESTICPROFILE_VERSION} installed to /usr/local/bin/resticprofile"
fi

# =============================================================================
# 3. Directory & Configuration Provisioning
# =============================================================================
echo ""
echo "--- [3/6] Provisioning configuration directories..."

mkdir -p /etc/resticprofile/scripts
mkdir -p /var/tmp/backup_stage
chmod 700 /var/tmp/backup_stage

echo "  ✓ /etc/resticprofile/scripts"
echo "  ✓ /var/tmp/backup_stage (mode 700)"

# Copy configuration modules — overwrite to apply any updates
cp -f config/profiles.yaml  /etc/resticprofile/profiles.yaml
cp -f config/excludes        /etc/resticprofile/excludes
cp -f config/scripts/*.sh    /etc/resticprofile/scripts/
chmod +x /etc/resticprofile/scripts/*.sh

# Lock down config directory so only root can read secrets
chmod 750 /etc/resticprofile
chmod 640 /etc/resticprofile/profiles.yaml
chmod 640 /etc/resticprofile/excludes

echo "  ✓ profiles.yaml, excludes, and hook scripts deployed"

# Link the recovery framework globally for immediate access during emergencies
ln -sf /etc/resticprofile/scripts/restore.sh /usr/local/bin/agent-restore
chmod +x /usr/local/bin/agent-restore
echo "  ✓ agent-restore global alias → /etc/resticprofile/scripts/restore.sh"

# =============================================================================
# 4. Environment File Injection
# =============================================================================
echo ""
echo "--- [4/6] Configuring environment secrets..."

if [ ! -f /etc/resticprofile/.env ]; then
    if [ -f .env ]; then
        cp .env /etc/resticprofile/.env
        echo "  ✓ .env copied from local .env file"
    else
        cp .env.template /etc/resticprofile/.env
        echo ""
        echo "  ⚠ ALERT: No .env file found. The template has been copied to"
        echo "    /etc/resticprofile/.env — you MUST populate all REPLACE_WITH_*"
        echo "    values and run the repository init commands before backups start."
        echo ""
    fi
    chmod 600 /etc/resticprofile/.env
else
    echo "  ✓ /etc/resticprofile/.env already exists — not overwritten"
    echo "    (delete it manually and re-run to force an update)"
fi

# =============================================================================
# 5. Systemd Unit Generation
# =============================================================================
echo ""
echo "--- [5/6] Generating systemd service and timer units..."

# --- Template service unit (parameterised by profile name via %i/%I) --------
cat << 'EOF' > /etc/systemd/system/resticprofile-backup@.service
[Unit]
Description=Resticprofile Backup Agent (Profile: %I)
Documentation=https://github.com/creativeprojects/resticprofile
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
# Resource constraints — protect host from RAM / CPU exhaustion
MemoryMax=2G
CPUQuota=40%
# Load secrets from the environment file
EnvironmentFile=-/etc/resticprofile/.env
# Run the backup for the specified profile
ExecStart=/usr/local/bin/resticprofile \
    --config /etc/resticprofile/profiles.yaml \
    --name %i \
    backup
StandardOutput=journal
StandardError=journal
SyslogIdentifier=resticprofile-%i
User=root
# Restart on transient failures; do not restart on non-zero exit (backup error)
Restart=no
EOF

# --- Template timer unit (schedule is set per instance below) ---------------
cat << 'EOF' > /etc/systemd/system/resticprofile-backup@.timer
[Unit]
Description=Resticprofile Backup Schedule (Profile: %I)
Documentation=https://github.com/creativeprojects/resticprofile

[Timer]
# OnCalendar will be overridden per-instance by the sed commands below
OnCalendar=daily
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF

echo "  ✓ resticprofile-backup@.service"
echo "  ✓ resticprofile-backup@.timer"

systemctl daemon-reload

# =============================================================================
# 6. Timer Activation
# =============================================================================
echo ""
echo "--- [6/6] Enabling and activating backup timers..."

# Create discrete, per-profile copies of the timer so each can hold its
# own OnCalendar value without colliding through the template mechanism.
#
# local  — Daily at 02:00 local time (fast on-disk snapshot)
# cloud  — Daily at 04:00 local time (S3 upload; after local completes)

for PROFILE in local cloud; do
    TIMER_FILE="/etc/systemd/system/resticprofile-backup@${PROFILE}.timer"
    # Write a dedicated timer file for each profile
    SCHEDULE="*-*-* 02:00:00"
    [ "$PROFILE" == "cloud" ] && SCHEDULE="*-*-* 04:00:00"

    cat > "$TIMER_FILE" << UNITEOF
[Unit]
Description=Resticprofile Backup Schedule (Profile: ${PROFILE})
Documentation=https://github.com/creativeprojects/resticprofile

[Timer]
OnCalendar=${SCHEDULE}
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
UNITEOF

    echo "  ✓ Timer for '${PROFILE}' set to: ${SCHEDULE}"
done

systemctl daemon-reload

# Stop existing timers before re-enabling (safe no-op if not running)
systemctl stop  "resticprofile-backup@local.timer" 2>/dev/null || true
systemctl stop  "resticprofile-backup@cloud.timer" 2>/dev/null || true

systemctl enable --now resticprofile-backup@local.timer
systemctl enable --now resticprofile-backup@cloud.timer

echo "  ✓ resticprofile-backup@local.timer — enabled (02:00 daily)"
echo "  ✓ resticprofile-backup@cloud.timer — enabled (04:00 daily)"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║   Installation Completed Successfully                           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Edit /etc/resticprofile/.env and populate all secret values."
echo ""
echo "  2. Initialise the backup repositories (run once per deployment):"
echo "       resticprofile --config /etc/resticprofile/profiles.yaml --name local init"
echo "       resticprofile --config /etc/resticprofile/profiles.yaml --name cloud init"
echo ""
echo "  3. Verify the schedule:"
echo "       systemctl list-timers --all | grep resticprofile"
echo ""
echo "  4. Trigger a manual test run:"
echo "       systemctl start resticprofile-backup@local.service"
echo "       journalctl -u resticprofile-backup@local.service -f"
echo ""
echo "  5. Run the interactive disaster recovery wizard:"
echo "       sudo agent-restore"
echo ""
