# Client Backup Agent

> **Enterprise-grade, host-native backup appliance powered by [Restic](https://restic.net) + [resticprofile](https://github.com/creativeprojects/resticprofile). Automated, secure, and production-ready from a single install command.**

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Security Model](#3-security-model)
4. [Prerequisites](#4-prerequisites)
5. [Repository Layout](#5-repository-layout)
6. [Quick-Start Guide](#6-quick-start-guide)
7. [Configuration Reference](#7-configuration-reference)
   - [`.env` — Environment Variables](#env--environment-variables)
   - [`config/profiles.yaml` — Backup Profiles](#configprofilesyaml--backup-profiles)
   - [`config/excludes` — Exclusion Patterns](#configexcludes--exclusion-patterns)
8. [Hook Scripts](#8-hook-scripts)
   - [`pre-backup.sh`](#pre-backupsh)
   - [`post-backup.sh`](#post-backupsh)
   - [`restore.sh` — Interactive Disaster Recovery](#restoresh--interactive-disaster-recovery)
     - [Step-by-Step Flow](#step-by-step-flow)
     - [Database Conflict Resolution](#database-conflict-resolution)
9. [Database Container Labelling](#9-database-container-labelling)
10. [Systemd Integration](#10-systemd-integration)
11. [Monitoring & Alerting](#11-monitoring--alerting)
12. [Operational Runbook](#12-operational-runbook)
    - [Initialise Repositories](#initialise-repositories)
    - [Trigger a Manual Backup](#trigger-a-manual-backup)
    - [View Logs](#view-logs)
    - [List Snapshots](#list-snapshots)
    - [Browse a Snapshot](#browse-a-snapshot)
    - [Restore Files](#restore-files)
    - [Verify Backup Integrity](#verify-backup-integrity)
    - [Run the Interactive Recovery Wizard](#run-the-interactive-recovery-wizard)
13. [Upgrade Guide](#13-upgrade-guide)
14. [Troubleshooting](#14-troubleshooting)
15. [Glossary](#15-glossary)

---

## 1. Overview

This agent provides a complete, automated backup solution for production Linux hosts. It runs **natively on the host operating system** — not inside a container — giving it unrestricted access to every file, volume, and configuration artefact on the machine without the security hazards of exposing the Docker socket to a networked process.

**Key capabilities:**

| Capability | Detail |
|---|---|
| Incremental snapshots | Restic content-addressed storage eliminates redundant data |
| Database autodiscovery | Auto-detects PostgreSQL, MySQL, and MariaDB containers and dumps them atomically before snapshotting |
| Dual-destination backup | Local disk (fast recovery) + immutable S3-compatible object store (ransomware protection) |
| Automated scheduling | Native systemd timers — no cron, no fragile shell loops |
| Resource-bounded | Runs inside systemd cgroup limits (CPU 40%, RAM 2 GB) to protect production workloads |
| Push notifications | Real-time success/failure alerts via ntfy.sh |
| Uptime monitoring | Integrates with Healthchecks.io heartbeat monitoring |
| Idempotent installation | Safe to re-run `install.sh` after any configuration change |
| Interactive disaster recovery | Guided `agent-restore` wizard with dry-run, container isolation, and three-mode DB conflict resolution |

---

## 2. Architecture

```
+------------------------------------------------------------------------+
|                            HOST OPERATING SYSTEM                       |
|                                                                        |
|   +-----------------------+                    +-------------------+   |
|   |   Systemd Engine      |                    |  Docker Engine    |   |
|   |  (Timers & Services)  |                    | (Client Stacks)   |   |
|   +-----------+-----------+                    +---------+---------+   |
|               | (Triggers)                               |             |
|               v                                          | (Queries)   |
|   +-----------+-----------+                              |             |
|   |     resticprofile     +------------------------------+             |
|   |   Execution Engine    |                                            |
|   +-----+-----------+-----+                                            |
|         |           |                                                  |
| (Hooks) |           | (Direct File Reads)                              |
|         v           v                                                  |
|  +------+--+    +---+---------------------+                            |
|  | Bash    |    | /var/lib/docker/volumes |                            |
|  | Hooks   |    | /etc, /opt, etc.        |                            |
|  +---------+    +-------------------------+                            |
|                                                                        |
+-----------------------------------+------------------------------------+
                                    |
                                    | (Secure Uploads via TLS)
                                    v
                 +------------------+------------------+
                 |            REMOTE STORAGE           |
                 |  (S3 / Wasabi Object-Locked Repo)   |
                 +-------------------------------------+
```

### Execution flow per backup run

1. **systemd timer** fires and starts `resticprofile-backup@{profile}.service`
2. **resticprofile** reads `profiles.yaml` and the injected `.env` file
3. **`pre-backup.sh`** runs:
   - Checks free disk space against the configured threshold
   - Wipes and re-creates the staging directory
   - Iterates all running containers, identifies databases, and dumps them into the staging directory
4. **restic backup** snapshots the declared source paths (volumes, `/opt`, `/etc`, staging dir)
5. **restic forget + prune** applies the retention policy
6. **`post-backup.sh success|failure`** runs:
   - Pings Healthchecks.io
   - Sends a push notification via ntfy.sh
   - Wipes the staging directory

---

## 3. Security Model

| Threat Vector | Mitigation |
|---|---|
| Container escape | Agent runs on bare metal; no elevated container privileges needed |
| Docker socket exposure | Agent calls `docker` CLI as root on the host; socket never shared into any container |
| Credential exfiltration | `.env` is stored at `chmod 600` under `/etc/resticprofile/`; readable only by root |
| Ransomware / accidental deletion | Cloud repo uses S3 Object Lock (WORM); restic uses content-addressed, append-only packs |
| Resource exhaustion | systemd cgroup enforces `MemoryMax=2G` and `CPUQuota=40%` per backup job |
| Filesystem inconsistency | `--one-file-system` prevents cross-mount traversal; DB dumps are atomic (pg_dumpall / mysqldump `--single-transaction`) |

> [!CAUTION]
> The `/etc/resticprofile/.env` file contains your S3 credentials and restic repository password. **Never commit this file to version control.** The `.env.template` is the only file that should be committed.

---

## 4. Prerequisites

### Host requirements

| Requirement | Minimum |
|---|---|
| OS | Any systemd-based Linux (Ubuntu 22.04+, Debian 12+, RHEL 9+) |
| Architecture | x86_64 (`amd64`) or ARM64 (adjust `ARCH` variable in `install.sh`) |
| RAM | 512 MB free during backup window |
| Disk | Enough local free space to hold database dumps (configured via `MIN_FREE_DISK_PERCENT`) |

### Required host tools (validated by installer)

```
curl  jq  docker  sed  grep  awk  bzip2
```

All of these are present by default on any Docker host running Ubuntu/Debian. Install missing tools via your package manager before running `install.sh`.

### External accounts

| Service | Purpose | URL |
|---|---|---|
| Wasabi / AWS S3 | Remote immutable backup repository | https://wasabi.com |
| Healthchecks.io | Heartbeat uptime monitoring | https://healthchecks.io |
| ntfy.sh | Push notification channel | https://ntfy.sh |

---

## 5. Repository Layout

```text
client-backup-agent/
├── install.sh                       # Idempotent system installer and supervisor
├── .env.template                    # Raw client configuration environment blueprint
├── README.md                        # This document
└── config/
    ├── profiles.yaml                # Core resticprofile orchestration blueprint
    ├── excludes                     # Global rule definitions for dropped patterns
    └── scripts/
        ├── pre-backup.sh            # Discovery, isolation, sizing, and atomic dump parsing
        ├── post-backup.sh           # Error routing, metrics generation, notification parsing
        └── restore.sh               # Interactive disaster recovery orchestrator
```

After installation, the agent's runtime configuration lives at:

```text
/etc/resticprofile/
├── .env                             # Populated secrets (chmod 600, root-only)
├── profiles.yaml                    # Backup profile definitions
├── excludes                         # Exclusion pattern file
└── scripts/
    ├── pre-backup.sh
    ├── post-backup.sh
    └── restore.sh                   # Symlinked to /usr/local/bin/agent-restore
```

`install.sh` creates a global symlink so the wizard is reachable from any directory during an active emergency:

```bash
/usr/local/bin/agent-restore → /etc/resticprofile/scripts/restore.sh
```

---

## 6. Quick-Start Guide

> [!IMPORTANT]
> All commands must be run as **root** (or via `sudo`). The installer will exit if run without privileges.

### Step 1 — Clone the repository

```bash
git clone https://github.com/a-defaultt/GridBackup.git
cd GridBackup
```

### Step 2 — Create your `.env` file

```bash
cp .env.template .env
nano .env        # or your preferred editor
```

Populate every `REPLACE_WITH_*` value. See [Configuration Reference](#7-configuration-reference) for full details on each variable.

### Step 3 — Run the installer

```bash
sudo ./install.sh
```

The installer will:
- Validate host dependencies
- Download `restic` and `resticprofile` binaries if not already present
- Deploy config files to `/etc/resticprofile/`
- Generate and enable systemd service and timer units

### Step 4 — Initialise the repositories

> **Run these exactly once** per deployment. They create the restic metadata structures in each storage backend.

```bash
# Initialise the local repository
resticprofile --config /etc/resticprofile/profiles.yaml --name local init

# Initialise the remote S3 repository
resticprofile --config /etc/resticprofile/profiles.yaml --name cloud init
```

### Step 5 — Run a smoke test

```bash
# Trigger the local backup immediately
systemctl start resticprofile-backup@local.service

# Follow the live log output
journalctl -u resticprofile-backup@local.service -f
```

A successful run ends with output similar to:
```
[2026-06-11 02:00:15] Pre-backup processing successfully finished.
snapshot abc123de saved
[2026-06-11 02:03:42] Backup executed successfully. Dispatching telemetry pings.
```

---

## 7. Configuration Reference

### `.env` — Environment Variables

The `.env` file is the single source of truth for all client-specific settings. It lives at `/etc/resticprofile/.env` on the host (mode `600`).

| Variable | Required | Description |
|---|---|---|
| `CLIENT_NAME` | ✓ | Human-readable client identifier used in notification titles |
| `HOST_IDENTIFIER` | ✓ | Hostname or role label included in alert messages |
| `RESTIC_PASSWORD` | ✓ | Encryption passphrase for all restic repositories. Generate with `openssl rand -base64 48` |
| `LOCAL_REPO_PATH` | ✓ | Absolute filesystem path for the local restic repository (e.g. `/mnt/backups/local-restic-repo`) |
| `REMOTE_S3_REPO` | ✓ | Full restic S3 URI (e.g. `s3:s3.us-east-1.wasabisys.com/my-bucket`) |
| `AWS_ACCESS_KEY_ID` | ✓ | S3-compatible access key |
| `AWS_SECRET_ACCESS_KEY` | ✓ | S3-compatible secret key |
| `HEALTHCHECKS_IO_URL` | ✓ | Full ping URL from your Healthchecks.io check (e.g. `https://hc-ping.com/your-uuid`) |
| `NOTIFY_WEBHOOK_URL` | ✓ | ntfy.sh topic URL (e.g. `https://ntfy.sh/my-secure-topic`) |
| `MAX_DB_DUMP_DURATION_MINUTES` | ✓ | Timeout in minutes before a database dump is killed and the backup aborted (default: `20`) |
| `MIN_FREE_DISK_PERCENT` | ✓ | Minimum required free disk percentage on `/`; backup aborts if below this (default: `15`) |
| `TEMPORARY_DUMP_DIR` | ✓ | Staging directory for database dumps; created fresh before each run and wiped after (default: `/var/tmp/backup_stage`) |

> [!TIP]
> Generate a strong password: `openssl rand -base64 48`
>
> Store it in a password manager immediately — **a lost restic password means permanent data loss**.

---

### `config/profiles.yaml` — Backup Profiles

The profiles file is the resticprofile orchestration blueprint. It defines three profiles:

#### `base` (abstract — never run directly)

Shared parameters inherited by all concrete profiles:
- Injects S3 credentials from environment
- Registers pre/post hook scripts
- Declares backup sources: Docker named volumes, `/opt`, `/etc`, and the DB staging dir
- Applies the global exclude file
- Tags every snapshot with `automated-system-backup`

#### `local` (inherits `base`)

| Setting | Value | Rationale |
|---|---|---|
| Repository | `local:${LOCAL_REPO_PATH}` | NVMe/SSD local disk for instant restores |
| `keep-daily` | 14 | Two weeks of granular daily recovery points |
| `keep-weekly` | 4 | One month of weekly recovery points |
| `keep-monthly` | 12 | One year of monthly recovery points |
| `check.read-data-subset` | 5% | Stochastic integrity check on a random 5% of pack data per run |

#### `cloud` (inherits `base`)

| Setting | Value | Rationale |
|---|---|---|
| Repository | `${REMOTE_S3_REPO}` | Off-site immutable object store |
| `keep-daily` | 7 | Lean daily set to control egress costs |
| `keep-weekly` | 4 | One month of weeklies |
| `keep-monthly` | 2 | Two months of monthlies |

> [!NOTE]
> The `global` block sets `ionice-class: 2 / ionice-level: 6` and `nice: 10` so backup I/O is always lower priority than production application I/O.

---

### `config/excludes` — Exclusion Patterns

The exclusions file prevents restic from snapshotting paths that are either unsafe to read (pseudo-filesystems) or wasteful to back up (dependency trees, build caches).

| Pattern | Reason |
|---|---|
| `/proc/*`, `/sys/*`, `/dev/*`, `/run/*` | Virtual kernel filesystems — not real files |
| `/tmp/*`, `/var/tmp/backup_stage/*` | Transient data; staging dir is wiped per run |
| `**/.cache`, `**/Cache`, `**/caches` | Application caches — easily regenerated |
| `**/node_modules`, `**/bower_components` | Dependency trees — restored from lockfiles |
| `/var/lib/docker/overlay2/*` | Container layer storage — not needed (volumes are backed up) |
| `/var/lib/docker/containers/*` | Container runtime metadata — regenerated on start |

---

## 8. Hook Scripts

### `pre-backup.sh`

**Location on host:** `/etc/resticprofile/scripts/pre-backup.sh`
**Triggered by:** `run-before` hook in `profiles.yaml`

#### Disk space check

```bash
FREE_SPACE_PCT=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
```

Reads the used-space percentage of the root filesystem. If free space falls below `MIN_FREE_DISK_PERCENT`, the script exits with code `1`, immediately aborting the backup and triggering `run-after-fail`.

#### Staging directory initialisation

The `TEMPORARY_DUMP_DIR` is deleted and recreated with mode `700` (root-only access) before every run, ensuring no stale dumps from a previous failed run interfere.

#### Database autodiscovery

The script iterates over every running container reported by `docker ps`. For each container, it inspects:
1. **Image name** — matched against `postgres`, `mysql`, or `mariadb` (substring match)
2. **`backup.db` label** — determines the dump strategy

See [Database Container Labelling](#9-database-container-labelling) for how to configure containers.

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | All checks passed, backup proceeds |
| `1` | Disk space below threshold |
| `2` | PostgreSQL dump failed or timed out |
| `3` | MySQL/MariaDB dump failed or timed out |

---

### `post-backup.sh`

**Location on host:** `/etc/resticprofile/scripts/post-backup.sh`
**Triggered by:** `run-after` (success path) and `run-after-fail` (failure path)

Accepts a single argument: `success` or `failure`.

#### Success path

```
1. Ping HEALTHCHECKS_IO_URL               → marks check as alive
2. POST to NOTIFY_WEBHOOK_URL (ntfy.sh)   → ✅ "Backup Successful — {CLIENT_NAME}"
3. Wipe TEMPORARY_DUMP_DIR/*              → clean staging area
```

#### Failure path

```
1. Ping HEALTHCHECKS_IO_URL/fail          → marks check as failed → triggers its own alerts
2. POST to NOTIFY_WEBHOOK_URL (ntfy.sh)   → 🔥 "BACKUP CRITICAL FAILURE — {CLIENT_NAME}"
3. Wipe TEMPORARY_DUMP_DIR/*              → always clean up, even on failure
```

> [!NOTE]
> Both curl calls use `|| true` — notification failures are **non-fatal**. A broken webhook will never cause a backup to be recorded as failed.

---

### `restore.sh` — Interactive Disaster Recovery

**Location on host:** `/etc/resticprofile/scripts/restore.sh`
**Global alias:** `sudo agent-restore` (symlinked to `/usr/local/bin/agent-restore` by the installer)

The recovery wizard provides a guided, multi-stage shell interface for safe, auditable restoration from any restic snapshot. It is designed to be used under pressure — every dangerous action requires explicit typed confirmation.

#### Step-by-Step Flow

| Step | What happens |
|---|---|
| **1 — Profile selection** | Choose `local` (on-disk) or `cloud` (S3) repository |
| **2 — Snapshot selection** | Lists all available snapshots; operator enters a snapshot ID or `latest` |
| **3 — Target path** | Choose the destination directory; live system paths (`/`, `/etc`, `/usr`) require typing `I UNDERSTAND` |
| **4 — Dry-run gate** | Option to execute a dry-run first — lists all files that *would* be written without touching the disk |
| **5 — Container isolation** | Lists all running containers; optionally stops them to prevent split-brain state during volume restoration |
| **6 — Restore execution** | Runs `resticprofile restore` with the selected parameters |
| **7 — Database reinsertion** | Discovers SQL dumps in the restored staging area and reinserts them into live containers |

#### Database Conflict Resolution

When restored database dumps are found, the operator is presented with **three conflict resolution modes** that apply to all reinserted databases in that session:

| Mode | Behaviour | When to use |
|---|---|---|
| `TIMESTAMP_COPY` **(default)** | Creates a new database named `<original>_restored_<YYYYMMDD_HHMMSS>` and imports the dump there | Always the safest choice — existing live data is never touched. Operator can inspect the restored copy and manually merge or promote it. |
| `OVERWRITE` | Drops the existing database cluster and reimports from the dump | Only when the live database is corrupted or the snapshot is the authoritative source. Requires typing `OVERWRITE` to confirm. |
| `SKIP` | Leaves all databases untouched; only flat files are restored | When only filesystem files are needed and database state is healthy |

> [!CAUTION]
> `OVERWRITE` permanently destroys all live transaction data that was written between the snapshot timestamp and the moment you run the wizard. Use `TIMESTAMP_COPY` and manually validate the restored data before promoting it to production.

#### Exit codes

| Code | Meaning |
|---|---|
| `0` | Recovery completed (or dry-run completed cleanly) |
| `1` | Missing root privileges or required binary not in PATH |
| `2` | Invalid operator input (blank snapshot ID, unconfirmed risk) |
| `3` | `resticprofile restore` command failed |
| `4` | SQL reinsertion encountered one or more errors |

#### Usage

```bash
# Run the interactive wizard (always requires root)
sudo agent-restore

# The wizard is fully interactive — no flags are needed.
# For scripted / non-interactive restores, call resticprofile directly:
resticprofile --config /etc/resticprofile/profiles.yaml \
              --name local \
              restore latest \
              --target /var/tmp/restore_stage
```

---

## 9. Database Container Labelling

The backup agent autodiscovers databases via Docker container labels. You **must** label every database container with `backup.db` so the agent knows what to do with it.

### Supported label values

| Label | Behaviour |
|---|---|
| `backup.db=postgres` | Runs `pg_dumpall` inside the container |
| `backup.db=mysql` | Runs `mysqldump --all-databases --single-transaction` inside the container |
| `backup.db=mariadb` | Same as `mysql` |
| `backup.db=skip` | Silences the "unprotected database" warning — no dump taken |

### Docker Compose example

```yaml
# docker-compose.yml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_USER: myapp
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: myapp
    volumes:
      - postgres_data:/var/lib/postgresql/data
    labels:
      backup.db: "postgres"          # ← Required for autodiscovery

  cache:
    image: redis:7
    labels:
      backup.db: "skip"              # ← Silence warning; Redis uses AOF/RDB files in volumes
```

> [!WARNING]
> Any container whose image name contains `postgres`, `mysql`, or `mariadb` but **lacks** a `backup.db` label will trigger:
> - A warning written to stderr (visible in `journalctl`)
> - A high-priority ntfy.sh push notification

This is intentional — an unlabelled database is likely an oversight and should never be silently skipped.

---

## 10. Systemd Integration

The installer creates a **template service** and **per-profile timer** units.

### Unit files

| File | Purpose |
|---|---|
| `/etc/systemd/system/resticprofile-backup@.service` | Template service; `%i` / `%I` are replaced by the profile name at runtime |
| `/etc/systemd/system/resticprofile-backup@local.timer` | Fires daily at **02:00** (local backup) |
| `/etc/systemd/system/resticprofile-backup@cloud.timer` | Fires daily at **04:00** (cloud upload) |

### Service resource limits

```ini
MemoryMax=2G      # Backup process may not use more than 2 GB RAM
CPUQuota=40%      # Backup process limited to 40% of one CPU core
```

### Useful systemctl commands

```bash
# Check timer status and next run time
systemctl list-timers --all | grep resticprofile

# View the service unit definition
systemctl cat resticprofile-backup@local.service

# Disable a profile temporarily (re-enable with enable --now)
systemctl disable resticprofile-backup@cloud.timer

# Check if a timer is active
systemctl is-active resticprofile-backup@local.timer
```

---

## 11. Monitoring & Alerting

### Healthchecks.io

1. Create a new check at https://healthchecks.io
2. Set the **period** to `24h` and **grace** to `2h` (backup runs have up to 2 hours before the check signals dead)
3. Copy the ping URL into `.env` as `HEALTHCHECKS_IO_URL`

The agent pings:
- `HEALTHCHECKS_IO_URL` → success
- `HEALTHCHECKS_IO_URL/fail` → explicit failure signal

### ntfy.sh

1. Choose a hard-to-guess topic name (treat it like a secret)
2. Subscribe via the [ntfy.sh app](https://ntfy.sh) or browser
3. Set the topic URL in `.env` as `NOTIFY_WEBHOOK_URL`

| Event | Priority | Tags |
|---|---|---|
| Backup success | `default` | `white_check_mark`, `automated` |
| Unlabelled database found | `high` | `warning`, `database` |
| Backup failure | `max` | `x`, `skull`, `fire` |

---

## 12. Operational Runbook

### Initialise Repositories

> Run once per fresh deployment or when pointing to a new storage backend.

```bash
# Local repository
resticprofile --config /etc/resticprofile/profiles.yaml --name local init

# Remote S3 repository
resticprofile --config /etc/resticprofile/profiles.yaml --name cloud init
```

---

### Trigger a Manual Backup

```bash
# Local profile
systemctl start resticprofile-backup@local.service

# Cloud profile
systemctl start resticprofile-backup@cloud.service
```

---

### View Logs

```bash
# Follow live output from the local backup service
journalctl -u resticprofile-backup@local.service -f

# Show last 200 lines from the cloud service
journalctl -u resticprofile-backup@cloud.service -n 200 --no-pager

# Show all backup journal entries since yesterday
journalctl -u "resticprofile-backup@*.service" --since yesterday
```

---

### List Snapshots

```bash
# List all snapshots in the local repository
resticprofile --config /etc/resticprofile/profiles.yaml --name local snapshots

# List cloud snapshots, most recent first
resticprofile --config /etc/resticprofile/profiles.yaml --name cloud snapshots --latest 10
```

---

### Browse a Snapshot

Mount a snapshot read-only for inspection before restoring:

```bash
mkdir -p /mnt/restic-recovery

# Mount (will stay mounted until umount)
resticprofile --config /etc/resticprofile/profiles.yaml --name local mount /mnt/restic-recovery

# In another terminal, browse the mounted snapshot tree
ls -la /mnt/restic-recovery/snapshots/latest/

# Unmount when done
umount /mnt/restic-recovery
```

---

### Restore Files

```bash
# Restore the entire latest snapshot to a target directory
restic --repo "${LOCAL_REPO_PATH}" \
       --password-file <(echo "$RESTIC_PASSWORD") \
       restore latest \
       --target /mnt/restore-target

# Restore a specific path from the latest snapshot
restic --repo "${LOCAL_REPO_PATH}" \
       --password-file <(echo "$RESTIC_PASSWORD") \
       restore latest \
       --include /etc/nginx \
       --target /mnt/restore-target

# Restore from a specific snapshot ID
restic --repo "${LOCAL_REPO_PATH}" \
       --password-file <(echo "$RESTIC_PASSWORD") \
       restore abc123de \
       --target /mnt/restore-target
```

> [!TIP]
> Use `resticprofile --name local snapshots` to find snapshot IDs. The `latest` keyword always refers to the most recent snapshot.

---

### Verify Backup Integrity

```bash
# Quick structural check (index + pack file existence)
resticprofile --config /etc/resticprofile/profiles.yaml --name local check

# Full data verification (reads and verifies every byte — slow but thorough)
resticprofile --config /etc/resticprofile/profiles.yaml --name local check --read-data

# Partial verification (random 10% sample — good for large repos)
resticprofile --config /etc/resticprofile/profiles.yaml --name local check --read-data-subset=10%
```

---

### Run the Interactive Recovery Wizard

The `agent-restore` wizard guides you through the complete recovery process step-by-step. Always run a dry-run first.

```bash
# Launch the interactive recovery wizard
sudo agent-restore
```

The wizard will prompt you through:
1. Choosing a repository (`local` or `cloud`)
2. Selecting a snapshot ID (or `latest`)
3. Setting the restore destination path
4. Running a dry-run preview
5. Optionally stopping running containers
6. Executing the restore
7. Reinjecting database dumps with your chosen conflict resolution mode

> [!TIP]
> For a quick, non-interactive file restore, use resticprofile directly:
> ```bash
> resticprofile --config /etc/resticprofile/profiles.yaml \
>               --name local restore latest \
>               --include /etc/nginx \
>               --target /var/tmp/restore_stage
> ```

---

## 13. Upgrade Guide

### Upgrading restic or resticprofile binaries

Edit the version variables at the top of `install.sh`:

```bash
RESTIC_VERSION="0.17.1"            # ← bump to new version
RESTICPROFILE_VERSION="0.31.1"     # ← bump to new version
```

Then force a reinstall by removing the existing binaries and re-running:

```bash
rm -f /usr/local/bin/restic /usr/local/bin/resticprofile
sudo ./install.sh
```

### Updating configuration files

After editing any file in `config/`, re-run the installer to sync changes to `/etc/resticprofile/`:

```bash
sudo ./install.sh
```

The installer is idempotent — it will not touch your `.env` or remove existing repository data.

---

## 14. Troubleshooting

### `install.sh` fails: "Missing essential system primitive: bzip2"

```bash
# Debian / Ubuntu
apt-get install -y bzip2

# RHEL / Fedora
dnf install -y bzip2
```

---

### Backup fails: "CRITICAL ERROR: Host storage space has fallen below critical threshold"

The filesystem reported less than `MIN_FREE_DISK_PERCENT` free space. Resolve by:

1. Pruning old snapshots: `resticprofile --name local forget --prune`
2. Clearing large files in `/var/log/`, old Docker images: `docker image prune -a`
3. Lowering `MIN_FREE_DISK_PERCENT` in `.env` (not recommended for production)

---

### Database dump fails or times out

- Increase `MAX_DB_DUMP_DURATION_MINUTES` in `.env` for very large databases
- Check that the container is healthy: `docker ps` and `docker logs <container>`
- Ensure the container has sufficient CPU/RAM to run a dump during backup hours

---

### ntfy.sh or Healthchecks.io notifications not arriving

- Test the webhook manually: `curl -d "test" "${NOTIFY_WEBHOOK_URL}"`
- Verify the URLs in `/etc/resticprofile/.env` are correct
- Check network connectivity from the host: `curl -I https://ntfy.sh`

---

### Restic `repo already exists` on `init`

This means the repository was previously initialised. **Do not re-initialise** — it will not overwrite data, but it confirms the repo is ready. Simply proceed to running a backup.

---

### journalctl shows permission errors on `/var/lib/docker/volumes`

Ensure the backup service runs as `root` (confirmed in the unit file via `User=root`). Re-run `install.sh` to ensure the service unit file is correctly deployed.

---

## 15. Glossary

| Term | Definition |
|---|---|
| **Restic** | A fast, secure, deduplicated backup program that stores data in content-addressed repositories |
| **resticprofile** | A YAML-based orchestration wrapper around restic that adds profile inheritance, scheduling, and lifecycle hooks |
| **Snapshot** | An immutable point-in-time copy of all backed-up data, identified by a unique hash |
| **Repository** | An encrypted, deduplicated store of backup data. Each storage destination (local, cloud) has its own repository |
| **Pack file** | A compressed, encrypted bundle of data blocks stored within the repository |
| **Retention policy** | Rules that determine how many snapshots to keep (`keep-daily`, `keep-weekly`, etc.) before pruning |
| **Prune** | The process of removing pack files that are no longer referenced by any kept snapshot |
| **Object Lock (WORM)** | S3 feature that prevents any stored object from being deleted or overwritten for a set retention period — protects against ransomware |
| **pg_dumpall** | PostgreSQL utility that produces a plain SQL dump of all databases in a cluster — transactionally consistent |
| **mysqldump --single-transaction** | MySQL utility flag that opens a consistent read transaction before dumping, avoiding table locks on InnoDB |
| **Healthchecks.io** | Cron monitoring SaaS — alerts if an expected ping is not received within the configured period |
| **ntfy.sh** | Open-source push notification service accessible via simple HTTP POST requests |
| **ionice** | Linux utility to set the I/O scheduling class and priority of a process |
| **cgroup** | Linux kernel mechanism for limiting, accounting, and isolating resource usage of a group of processes |
| **systemd template unit** | A unit file containing `@` in its name, allowing multiple instances to be created by passing a parameter (e.g., `@local`, `@cloud`) |
| **agent-restore** | Global shell alias (`/usr/local/bin/agent-restore`) created by the installer that launches the interactive disaster recovery wizard |
| **TIMESTAMP_COPY** | DB conflict resolution mode that imports restored data into a new database named `<db>_restored_<YYYYMMDD_HHMMSS>`, preserving existing live data |
| **OVERWRITE** | DB conflict resolution mode that drops the existing database and reimports from the snapshot dump — requires explicit typed confirmation |
| **Split-brain** | A state where two copies of the same data diverge because a live process wrote to a database while its volume was simultaneously being restored |

---

*Maintained by the infrastructure team. For issues, open a ticket or check the systemd journal first.*
