SnapRAID Automated Script (v3.3.3)

This repository contains a single Bash script, snapraid-automated.sh, that automates typical SnapRAID maintenance tasks: diff, optional sync (based on safety thresholds), and scrub. It can also pause/resume Docker services while maintenance runs, rotate logs, and perform a one-time touch of files that have a zero sub‑second timestamp.

What’s new in 3.3.3
- Fix: CURRENT_DIR was referenced before being set. It is now initialized at the top so SYNC_WARN_FILE and SCRUB_COUNT_FILE are created next to the script (not at filesystem root).
- Fix: search_conf_files now properly handles the case where no omv-snapraid-*.conf files exist (avoids false positive when shell globbing doesn’t match).
- Fix: Typos in messages ("ouput" -> "output"), grammar cleanup, and a minor duplicate period in a log line.
- Improvement: SNAPRAIDVERSION now uses the configured SNAPRAID_BIN path instead of assuming snapraid is in PATH.

Features
- Diff, Sync, Scrub automation driven by thresholds:
  - DEL_THRESHOLD, UP_THRESHOLD, ADD_DEL_THRESHOLD, SYNC_WARN_THRESHOLD
- Scrub scheduling helpers:
  - SCRUB_PERCENT, SCRUB_AGE, SCRUB_NEW, SCRUB_DELAYED_RUN
  - One-time catch-up when "not scrubbed" coverage is high
- Optional touch for zero sub-second timestamp files
- Optional Docker service management (pause/stop and resume/start)
- Ionice/Nice integration to reduce system impact
- Output and logging with optional retention and rotation

Quick Start
1) Place the script on the SnapRAID host and make it executable:
   chmod +x snapraid-automated.sh

2) Adjust configuration values near the top of the script as needed, especially:
   - SNAPRAID_CONF: path to your snapraid.conf
   - SNAPRAID_BIN: path to the snapraid binary
   - SNAPRAID_LOG_DIR: where to retain detailed logs (if RETENTION_DAYS > 0)
   - Thresholds (DEL_THRESHOLD, UP_THRESHOLD, etc.)
   - Docker options if you want containers paused/stopped during maintenance

3) Run it manually to verify behavior:
   ./snapraid-automated.sh

4) Schedule via cron (example: run nightly at 2:30):
   30 2 * * * /path/to/snapraid-automated.sh >> /var/log/snapraid-aio-cron.log 2>&1

Key Configuration Options
- Safety thresholds
  - DEL_THRESHOLD: Maximum deletions to allow before halting sync.
  - ADD_DEL_THRESHOLD: If > 0, requires an add/delete ratio >= ADD_DEL_THRESHOLD to allow sync when deletions exceed DEL_THRESHOLD.
  - UP_THRESHOLD: Maximum updated files before halting sync.
  - SYNC_WARN_THRESHOLD: Number of consecutive "warnings" before forcing a sync (0 = always force; -1 = never force).

- Scrub behavior
  - SCRUB_PERCENT: Percent of blocks to scrub for the main scrub phase (0 disables scrub).
  - SCRUB_AGE: Only scrub blocks older than this many days.
  - SCRUB_NEW: If 1, runs a new-blocks scrub pass before the main scrub.
  - SCRUB_DELAYED_RUN: Run scrub only every N executions (uses a small state file alongside the script).

- Performance/priority
  - IONICE_CLASS (idle|besteffort|realtime) and IONICE_PRIORITY
  - NICE_LEVEL

- Docker integration (optional)
  - MANAGE_SERVICES=1 to enable
  - SERVICES: whitespace-separated container names (local)
  - DOCKER_MODE: 1=pause/unpause, 2=stop/start
  - DOCKER_LOCAL: 1 to manage local Docker engine

- Logging and retention
  - RETENTION_DAYS: If > 0, rotate and keep SnapRAID output logs for this many days in SNAPRAID_LOG_DIR
  - SNAPRAID_LOG: A compact, timestamped log (default /var/log/snapraid.log)

Dependencies
- SnapRAID installed (SNAPRAID_BIN should point to the executable)
- awk, sed, grep, tee
- Optionally ionice and nice
- Optionally Docker CLI if MANAGE_SERVICES=1
- The script attempts to install bc via apt when missing (Debian/Ubuntu environments). On non-Debian systems, install an equivalent calculator or adjust the math logic accordingly.

Notes and Tips
- The script is conservative by default; it avoids syncing when large deletions or updates are detected unless thresholds are met.
- If SYNC_WARN_THRESHOLD >= 0, the script keeps a small counter file next to the script (snapRAID.warnCount). After the configured number of warnings, it forces a sync.
- For scrub, a similar counter (snapRAID.scrubCount) is used when SCRUB_DELAYED_RUN > 0 to space out scrub runs.
- The script parses content and parity paths from SNAPRAID_CONF and validates that the referenced files exist before proceeding.

Troubleshooting
- "SnapRAID is already running" – The script exits if it detects another snapraid instance.
- "configuration file not found" – Ensure SNAPRAID_CONF points to a valid config. On OMV 7 hosts, the script will attempt to auto-detect omv-snapraid-*.conf under /etc/snapraid.
- Logs: The full combined output (including SnapRAID output) is written to /tmp/snapRAID.out for the current run and optionally to SNAPRAID_LOG_DIR with timestamps if retention is enabled.

License
This script is provided as-is. Review thresholds and behavior before enabling unattended runs.
