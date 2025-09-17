#!/bin/bash

# Directory of this script (set early so dependent paths are correct)
CURRENT_DIR=$(dirname "${0}")

DEL_THRESHOLD=100
UP_THRESHOLD=500
ADD_DEL_THRESHOLD=0
SYNC_WARN_THRESHOLD=2
SCRUB_PERCENT=15
SCRUB_AGE=7
SCRUB_NEW=1
SCRUB_DELAYED_RUN=0
PREHASH=0
FORCE_ZERO=1
SPINDOWN=0
RETENTION_DAYS=1
SNAPRAID_LOG_DIR="$HOME"
SNAPRAID_CONF="/etc/snapraid.conf"
MANAGE_SERVICES=1
DOCKER_MODE=2
DOCKER_LOCAL=1
SERVICES=""
SNAPRAID_BIN="/usr/bin/snapraid"
CHK_FAIL=0
DO_SYNC=0
SERVICES_STOPPED=0
SYNC_WARN_FILE="$CURRENT_DIR/snapRAID.warnCount"
SCRUB_COUNT_FILE="$CURRENT_DIR/snapRAID.scrubCount"
TMP_OUTPUT="/tmp/snapRAID.out"
SNAPRAID_LOG="/var/log/snapraid.log"
SECONDS=0 #Capture time
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
IONICE_BIN="/usr/bin/ionice"
NICE_BIN="/usr/bin/nice"
IONICE_CLASS="${IONICE_CLASS:-idle}"
IONICE_PRIORITY="${IONICE_PRIORITY:-7}"
NICE_LEVEL="${NICE_LEVEL:-10}"
SNAPSCRIPTVERSION="3.3.3"
SNAPRAIDVERSION="$("$SNAPRAID_BIN" -V | sed -e 's/snapraid v\(.*\)by.*/\1/')"
SYNC_MARKER="SYNC -"
SCRUB_MARKER="SCRUB -"

function main() {
  true > "$TMP_OUTPUT"

  output_to_file_screen
  : > "$SNAPRAID_LOG"

  echo "SnapRAID Script Job started [$(date)]"
  echo "Running SnapRAID version $SNAPRAIDVERSION"
  echo "SnapRAID Script version $SNAPSCRIPTVERSION"
  echo "----------------------------------------"
  mklog "INFO: ----------------------------------------"
  mklog "INFO: SnapRAID Script Job started"
  mklog "INFO: Running SnapRAID version $SNAPRAIDVERSION"
  mklog "INFO: SnapRAID Script version $SNAPSCRIPTVERSION"

  echo "## Preprocessing"

  # Check for basic dependencies
  check_and_install bc

  ### Check if SnapRAID is already running
  if pgrep -x snapraid >/dev/null; then
    echo "The script has detected SnapRAID is already running. Please check the status of the previous SnapRAID job before running this script again."
    mklog "WARN: The script has detected SnapRAID is already running. Please check the status of the previous SnapRAID job before running this script again."
    exit 1;
  else
    echo "SnapRAID is not running, proceeding."
    mklog "INFO: SnapRAID is not running, proceeding."
  fi

  if [ "$RETENTION_DAYS" -gt 0 ]; then
    echo "SnapRAID output retention is enabled. Detailed logs will be kept in $SNAPRAID_LOG_DIR for $RETENTION_DAYS days."
  fi

  # Check if Snapraid configuration file has been found, if not, notify and exit
  if [ ! -f "$SNAPRAID_CONF" ]; then
    # if running on OMV7, try to find the SnapRAID conf file automatically
    check_omv_version
    if [ "$OMV_VERSION" -ge 7 ]; then
      pick_snapraid_conf_file
    else
      echo "SnapRAID configuration file not found. The script cannot be run! Please check your settings, because the specified file $SNAPRAID_CONF does not exist."
      mklog "WARN: SnapRAID configuration file not found. The script cannot be run! Please check your settings, because the specified file $SNAPRAID_CONF does not exist."
      exit 1;
    fi
        fi

        parse_snapraid_conf

  if [ ${#CONTENT_FILES[@]} -eq 0 ] || [ ${#PARITY_FILES[@]} -eq 0 ]; then
    echo "ERROR: no content/parity entries found in $SNAPRAID_CONF"
    exit 1
  fi

  mklog "INFO: Checking SnapRAID disks"
  sanity_check

  # pause configured containers
  if [ "$MANAGE_SERVICES" -eq 1 ]; then
    service_array_setup
    if [ "$DOCKERALLOK" = YES ]; then
      echo
      pause_services
      echo
    fi
  fi

  echo "----------------------------------------"
  echo "## Processing"

  chk_zero

  # run the snapraid DIFF command
  echo "### SnapRAID DIFF [$(date)]"
  mklog "INFO: SnapRAID DIFF started"
  echo "\`\`\`"
  run_snapraid diff
  close_output_and_wait
  output_to_file_screen
  echo "\`\`\`"
  echo "DIFF finished [$(date)]"
  mklog "INFO: SnapRAID DIFF finished"
  JOBS_DONE="DIFF"

  get_counts

  if [ -z "$DEL_COUNT" ] || [ -z "$ADD_COUNT" ] || [ -z "$MOVE_COUNT" ] || [ -z "$COPY_COUNT" ] || [ -z "$UPDATE_COUNT" ]; then
    # failed to get one or more of the count values, lets report to user and
    # exit with error code
    echo "**ERROR** - Failed to get one or more count values. Unable to continue."
    mklog "WARN: Failed to get one or more count values. Unable to continue."
    echo "Exiting script. [$(date)]"
    exit 1;
  fi
  echo "**SUMMARY: Equal [$EQ_COUNT] - Added [$ADD_COUNT] - Deleted [$DEL_COUNT] - Moved [$MOVE_COUNT] - Copied [$COPY_COUNT] - Updated [$UPDATE_COUNT]**"
  mklog "INFO: SUMMARY: Equal [$EQ_COUNT] - Added [$ADD_COUNT] - Deleted [$DEL_COUNT] - Moved [$MOVE_COUNT] - Copied [$COPY_COUNT] - Updated [$UPDATE_COUNT]"

  # check if the conditions to run SYNC are met
  # CHK 1 - if files have changed
  if [ "$DEL_COUNT" -gt 0 ] || [ "$ADD_COUNT" -gt 0 ] || [ "$MOVE_COUNT" -gt 0 ] || [ "$COPY_COUNT" -gt 0 ] || [ "$UPDATE_COUNT" -gt 0 ]; then
    chk_del
    if [ "$CHK_FAIL" -eq 0 ]; then
      chk_updated
    fi
    if [ "$CHK_FAIL" -eq 1 ]; then
      chk_sync_warn
    fi
  else
    # NO, so let's skip SYNC
    echo "No change detected. Not running SYNC job. [$(date)]"
    mklog "INFO: No change detected. Not running SYNC job."
    DO_SYNC=0
  fi

  # Now run sync if conditions are met
  if [ "$DO_SYNC" -eq 1 ]; then
    echo "SYNC is authorized. [$(date)]"
    echo "### SnapRAID SYNC [$(date)]"
    mklog "INFO: SnapRAID SYNC Job started"
    echo "\`\`\`"
    if [ "$PREHASH" -eq 1 ] && [ "$FORCE_ZERO" -eq 1 ]; then
      run_snapraid -h --force-zero -q sync
    elif [ "$PREHASH" -eq 1 ]; then
      run_snapraid -h -q sync
    elif [ "$FORCE_ZERO" -eq 1 ]; then
      run_snapraid --force-zero -q sync
    else
      run_snapraid -q sync
    fi
    close_output_and_wait
    output_to_file_screen
    echo "\`\`\`"
    echo "SYNC finished [$(date)]"
    mklog "INFO: SnapRAID SYNC Job finished"
    JOBS_DONE="$JOBS_DONE + SYNC"
    # insert SYNC marker to 'Everything OK' or 'Nothing to do' string to
    # differentiate it from SCRUB job later
    sed_me "
      s/^Everything OK/${SYNC_MARKER} Everything OK/g;
      s/^Nothing to do/${SYNC_MARKER} Nothing to do/g" "$TMP_OUTPUT"
    # Remove any warning flags if set previously. This is done in this step to
    # take care of scenarios when user has manually synced or restored deleted
    # files and we will have missed it in the checks above.
    if [ -e "$SYNC_WARN_FILE" ]; then
      rm "$SYNC_WARN_FILE"
    fi
  fi

  # Moving onto scrub now. Check if user has enabled scrub
  echo "### SnapRAID SCRUB [$(date)]"
  mklog "INFO: SnapRAID SCRUB Job started"

  # One-time catch-up if coverage got behind (e.g., after big maintenance)
  NSPCT=$(percent_not_scrubbed)
  if [ -n "$NSPCT" ] && [ "$NSPCT" -ge 25 ]; then
    echo "Not-scrubbed coverage is ${NSPCT}% (>=25%). Running a one-time heavier scrub window."
    mklog "INFO: Not-scrubbed ${NSPCT}%. Forcing larger scrub window."
    # temporarily bump scrub to 35% for this run, age 3 days
    SAVED_P="$SCRUB_PERCENT"; SAVED_O="$SCRUB_AGE"
    SCRUB_PERCENT=35; SCRUB_AGE=3
    chk_scrub_settings
    SCRUB_PERCENT="$SAVED_P"; SCRUB_AGE="$SAVED_O"
    # Skip the normal chk_scrub_settings path afterwards
    continue_after_scrub=1
  fi

  if [ "$SCRUB_PERCENT" -gt 0 ]; then
    # YES, first let's check if delete threshold has been breached and we have
    # not forced a sync.
    if [ "$CHK_FAIL" -eq 1 ] && [ "$DO_SYNC" -eq 0 ]; then
      # YES, parity is out of sync so let's not run scrub job
      echo "Parity info is out of sync (deleted or changed files threshold has been breached)."
      echo "Not running SCRUB job. [$(date)]"
      mklog "INFO: Parity info is out of sync (deleted or changed files threshold has been breached). Not running SCRUB job."
    else
      # NO, delete threshold has not been breached OR we forced a sync, but we
      # have one last test - let's make sure if sync ran, it completed
      # successfully (by checking for the marker text in the output).
      if [ "$DO_SYNC" -eq 1 ] && ! grep -qw "$SYNC_MARKER" "$TMP_OUTPUT"; then
        # Sync ran but did not complete successfully so lets not run scrub to
        # be safe
        echo "**WARNING!** - Check output of SYNC job. Could not detect marker."
        echo "Not running SCRUB job. [$(date)]"
        mklog "WARN: Check output of SYNC job. Could not detect marker. Not running SCRUB job."
      else
        # Everything ok - ready to run the scrub job!
        # The function will check if scrub delayed run is enabled and run scrub
        # based on configured conditions
        if [ "${continue_after_scrub:-0}" -ne 1 ]; then
          chk_scrub_settings
        fi
        unset continue_after_scrub
      fi
    fi
  else
    echo "Scrub job is not enabled. "
    echo "Not running SCRUB job. [$(date)]"
    mklog "INFO: Scrub job is not enabled. Not running SCRUB job."
  fi

  echo "----------------------------------------"
  echo "## Postprocessing"

  if [ "$SPINDOWN" -eq 1 ]; then
   for DRIVE in $(lsblk -d -o name | tail -n +2)
     do
       if [[ $(smartctl -a /dev/"$DRIVE" | grep 'Rotation Rate' | grep rpm) ]]; then
          echo "spinning down /dev/$DRIVE"
          hd-idle -t /dev/"$DRIVE"
       fi
     done
   fi

  # Resume Docker containers
  if [ "$SERVICES_STOPPED" -eq 1 ]; then
    echo
    resume_services
    echo
  fi

  echo "All jobs ended. [$(date)]"
  mklog "INFO: Snapraid: all jobs ended."

  # all jobs done
  # check snapraid output and build the message output
  # if notification services are enabled, messages will be sent now
  ELAPSED="$((SECONDS / 3600))hrs $(((SECONDS / 60) % 60))min $((SECONDS % 60))sec"
  echo "----------------------------------------"
  echo "## Total time elapsed for SnapRAID: $ELAPSED"
  mklog "INFO: Total time elapsed for SnapRAID: $ELAPSED"

  # Save and rotate logs if enabled
  if [ "$RETENTION_DAYS" -gt 0 ]; then
    find "$SNAPRAID_LOG_DIR"/SnapRAID-* -mtime +"$RETENTION_DAYS" -delete  # delete old logs
    cp "$TMP_OUTPUT" "$SNAPRAID_LOG_DIR"/SnapRAID-"$(date +"%Y_%m_%d-%H%M")".out
  fi

  # exit with success, letting the trap handle cleanup of file descriptors
  exit 0;
}

function sanity_check() {
  echo "Checking if all parity and content files are present."
  mklog "INFO: Checking if all parity and content files are present."
  for i in "${PARITY_FILES[@]}"; do
    if [ ! -e "$i" ]; then
    echo "[$(date)] ERROR - Parity file ($i) not found!"
    echo "ERROR - Parity file ($i) not found!" >> "$TMP_OUTPUT"
    echo "**ERROR**: Please check the status of your disks! The script exits here due to missing file or disk."
    mklog "WARN: Parity file ($i) not found!"
    mklog "WARN: Please check the status of your disks! The script exits here due to missing file or disk."
    exit 1;
  fi
  done
  echo "All parity files found."
  mklog "INFO: All parity files found."

  for i in "${CONTENT_FILES[@]}"; do
    if [ ! -e "$i" ]; then
      echo "[$(date)] ERROR - Content file ($i) not found!"
      echo "ERROR - Content file ($i) not found!" >> "$TMP_OUTPUT"
      echo "**ERROR**: Please check the status of your disks! The script exits here due to missing file or disk."
      mklog "WARN: Content file ($i) not found!"
      mklog "WARN: Please check the status of your disks! The script exits here due to missing file or disk."
    exit 1;
    fi
  done
  echo "All content files found."
  mklog "INFO: All content files found."
}

function get_counts() {
  EQ_COUNT=$(grep -w '^ \{1,\}[0-9]* equal' "$TMP_OUTPUT" | sed 's/^ *//g' | cut -d ' ' -f1)
  ADD_COUNT=$(grep -w '^ \{1,\}[0-9]* added' "$TMP_OUTPUT" | sed 's/^ *//g' | cut -d ' ' -f1)
  DEL_COUNT=$(grep -w '^ \{1,\}[0-9]* removed' "$TMP_OUTPUT" | sed 's/^ *//g' | cut -d ' ' -f1)
  UPDATE_COUNT=$(grep -w '^ \{1,\}[0-9]* updated' "$TMP_OUTPUT" | sed 's/^ *//g' | cut -d ' ' -f1)
  MOVE_COUNT=$(grep -w '^ \{1,\}[0-9]* moved' "$TMP_OUTPUT" | sed 's/^ *//g' | cut -d ' ' -f1)
  COPY_COUNT=$(grep -w '^ \{1,\}[0-9]* copied' "$TMP_OUTPUT" | sed 's/^ *//g' | cut -d ' ' -f1)
}

function sed_me() {
  exec 1>&"$OUT" 2>&"$ERROR"
  sed -i "$1" "$2"
  output_to_file_screen
}

function chk_del() {
  if [ "$DEL_COUNT" -eq 0 ]; then
    echo "There are no deleted files, that's fine."
    DO_SYNC=1
  elif [ "$DEL_COUNT" -lt "$DEL_THRESHOLD" ]; then
    echo "There are deleted files. The number of deleted files ($DEL_COUNT) is below the threshold of ($DEL_THRESHOLD)."
    DO_SYNC=1
  # check if ADD_DEL_THRESHOLD is greater than zero before attempting to use it
  elif [ "$(echo "$ADD_DEL_THRESHOLD > 0" | bc -l)" -eq 1 ]; then
    ADD_DEL_RATIO=$(echo "scale=2; $ADD_COUNT / $DEL_COUNT" | bc)
    if [ "$(echo "$ADD_DEL_RATIO >= $ADD_DEL_THRESHOLD" | bc -l)" -eq 1 ]; then
      echo "There are deleted files. The number of deleted files ($DEL_COUNT) is above the threshold of ($DEL_THRESHOLD)"
      echo "but the add/delete ratio of ($ADD_DEL_RATIO) is above the threshold of ($ADD_DEL_THRESHOLD), sync will proceed."
      DO_SYNC=1
    else
      echo "**WARNING!** Deleted files ($DEL_COUNT) reached/exceeded threshold ($DEL_THRESHOLD) and add/delete threshold ($ADD_DEL_THRESHOLD) was not met."
      mklog "WARN: Deleted files ($DEL_COUNT) reached/exceeded threshold ($DEL_THRESHOLD) and add/delete threshold ($ADD_DEL_THRESHOLD) was not met."
      CHK_FAIL=1
    fi
  else
    if [ "$RETENTION_DAYS" -gt 0 ]; then
      echo "**WARNING!** Deleted files ($DEL_COUNT) reached/exceeded threshold ($DEL_THRESHOLD)."
      echo "For more information, please check the DIFF output saved in $SNAPRAID_LOG_DIR."
      mklog "WARN: Deleted files ($DEL_COUNT) reached/exceeded threshold ($DEL_THRESHOLD)."
      CHK_FAIL=1
    else
      echo "**WARNING!** Deleted files ($DEL_COUNT) reached/exceeded threshold ($DEL_THRESHOLD)."
      mklog "WARN: Deleted files ($DEL_COUNT) reached/exceeded threshold ($DEL_THRESHOLD)."
      CHK_FAIL=1
    fi
  fi
}

function chk_updated() {
  if [ "$UPDATE_COUNT" -lt "$UP_THRESHOLD" ]; then
    if [ "$UPDATE_COUNT" -eq 0 ]; then
      echo "There are no updated files, that's fine."
      DO_SYNC=1
    else
      echo "There are updated files. The number of updated files ($UPDATE_COUNT) is below the threshold of ($UP_THRESHOLD)."
      DO_SYNC=1
    fi
  else
    if [ "$RETENTION_DAYS" -gt 0 ]; then
      echo "**WARNING!** Updated files ($UPDATE_COUNT) reached/exceeded threshold ($UP_THRESHOLD)."
      echo "For more information, please check the DIFF output saved in $SNAPRAID_LOG_DIR."
      mklog "WARN: Updated files ($UPDATE_COUNT) reached/exceeded threshold ($UP_THRESHOLD)."
      CHK_FAIL=1
    else
      echo "**WARNING!** Updated files ($UPDATE_COUNT) reached/exceeded threshold ($UP_THRESHOLD)."
      mklog "WARN: Updated files ($UPDATE_COUNT) reached/exceeded threshold ($UP_THRESHOLD)."
      CHK_FAIL=1
    fi
  fi
}

function chk_sync_warn() {
  if [ "$SYNC_WARN_THRESHOLD" -gt -1 ]; then
    if [ "$SYNC_WARN_THRESHOLD" -eq 0 ]; then
      echo "Forced sync is enabled."
      mklog "INFO: Forced sync is enabled."
    else
      echo "Sync after threshold warning(s) is enabled."
      mklog "INFO: Sync after threshold warning(s) is enabled."
    fi

    local sync_warn_count
    sync_warn_count=$(sed '/^[0-9]*$/!d' "$SYNC_WARN_FILE" 2>/dev/null)
    # zero if file does not exist or did not contain a number
    : "${sync_warn_count:=0}"

    if [ "$sync_warn_count" -ge "$SYNC_WARN_THRESHOLD" ]; then
      # Force a sync. If the warn count is zero it means the sync was already
      # forced, do not output a dumb message and continue with the sync job.
      if [ "$sync_warn_count" -eq 0 ]; then
        DO_SYNC=1
      else
        # If there is at least one warn count, output a message and force a
        # sync job. Do not need to remove warning marker here as it is
        # automatically removed when the sync job is run by this script
        echo "Number of threshold warning(s) ($sync_warn_count) has reached/exceeded threshold ($SYNC_WARN_THRESHOLD). Forcing a SYNC job to run."
        mklog "INFO: Number of threshold warning(s) ($sync_warn_count) has reached/exceeded threshold ($SYNC_WARN_THRESHOLD). Forcing a SYNC job to run."
        DO_SYNC=1
      fi
    else
      # NO, so let's increment the warning count and skip the sync job
      ((sync_warn_count += 1))
      echo "$sync_warn_count" > "$SYNC_WARN_FILE"
      if [ "$sync_warn_count" == "$SYNC_WARN_THRESHOLD" ]; then
        echo  "This is the **last** warning left. **NOT** proceeding with SYNC job. [$(date)]"
        mklog "INFO: This is the **last** warning left. **NOT** proceeding with SYNC job. [$(date)]"
        DO_SYNC=0
      else
        echo "$((SYNC_WARN_THRESHOLD - sync_warn_count)) threshold warning(s) until the next forced sync. **NOT** proceeding with SYNC job. [$(date)]"
        mklog "INFO: $((SYNC_WARN_THRESHOLD - sync_warn_count)) threshold warning(s) until the next forced sync. **NOT** proceeding with SYNC job."
        DO_SYNC=0
      fi
    fi
  else
    # NO, so let's skip SYNC
    if [ "$RETENTION_DAYS" -gt 0 ]; then
    echo "Forced sync is not enabled. **NOT** proceeding with SYNC job. [$(date)]"
    mklog "INFO: Forced sync is not enabled. **NOT** proceeding with SYNC job."
    DO_SYNC=0
    else
    echo "Forced sync is not enabled. Check $TMP_OUTPUT for details. **NOT** proceeding with SYNC job. [$(date)]"
    mklog "INFO: Forced sync is not enabled. Check $TMP_OUTPUT for details. **NOT** proceeding with SYNC job."
    DO_SYNC=0
    fi
  fi
}

function chk_zero() {
  echo "### SnapRAID TOUCH [$(date)]"
  echo "Checking for zero sub-second files."
  TIMESTATUS=$(run_snapraid status | grep -E 'You have [1-9][0-9]* files with( a)? zero sub-second timestamp\.' | sed 's/^You have/Found/g')
  if [ -n "$TIMESTATUS" ]; then
    echo "$TIMESTATUS"
    echo "Running TOUCH job to timestamp. [$(date)]"
    echo "\`\`\`"
    run_snapraid touch
    close_output_and_wait
    output_to_file_screen
    echo "\`\`\`"
  else
    echo "No zero sub-second timestamp files found."
  fi
  echo "TOUCH finished [$(date)]"
}

function chk_scrub_settings() {
  if [ "$SCRUB_DELAYED_RUN" -gt 0 ]; then
    echo "Delayed scrub is enabled."
    mklog "INFO: Delayed scrub is enabled."
  fi

  local scrub_count
  scrub_count=$(sed '/^[0-9]*$/!d' "$SCRUB_COUNT_FILE" 2>/dev/null)
  # zero if file does not exist or did not contain a number
  : "${scrub_count:=0}"

  if [ "$scrub_count" -ge "$SCRUB_DELAYED_RUN" ]; then
  # Run a scrub job. if the warn count is zero it means the scrub was already
  # forced, do not output a dumb message and continue with the scrub job.
    if [ "$scrub_count" -eq 0 ]; then
      echo
      run_scrub
    else
      # if there is at least one warn count, output a message and force a scrub
      # job. Do not need to remove warning marker here as it is automatically
      # removed when the scrub job is run by this script
      echo "Number of delayed runs has reached/exceeded threshold ($SCRUB_DELAYED_RUN). A SCRUB job will run."
      mklog "INFO: Number of delayed runs has reached/exceeded threshold ($SCRUB_DELAYED_RUN). A SCRUB job will run."
      echo
      run_scrub
    fi
    else
    # NO, so let's increment the warning count and skip the scrub job
    ((scrub_count += 1))
    echo "$scrub_count" > "$SCRUB_COUNT_FILE"
    if [ "$scrub_count" == "$SCRUB_DELAYED_RUN" ]; then
      echo  "This is the **last** run left before running scrub job next time. [$(date)]"
      mklog "INFO: This is the **last** run left before running scrub job next time. [$(date)]"
    else
      echo "$((SCRUB_DELAYED_RUN - scrub_count)) runs until the next scrub. **NOT** proceeding with SCRUB job. [$(date)]"
      mklog "INFO: $((SCRUB_DELAYED_RUN - scrub_count)) runs until the next scrub. **NOT** proceeding with SCRUB job. [$(date)]"
    fi
  fi
}

function percent_not_scrubbed() {
  # parse "X% of the array is not scrubbed." from status
  local pct
  pct="$(run_snapraid status | awk '/not scrubbed\./{print $1}' | tr -d '%')"
  echo "${pct:-0}"
}

function run_scrub() {
  if [ "$SCRUB_NEW" -eq 1 ]; then
  echo "SCRUB New Blocks [$(date)]"
    echo "\`\`\`"
    run_snapraid -p new -q scrub
    close_output_and_wait
    output_to_file_screen
    echo "\`\`\`"
  fi
  echo "SCRUB Previous Blocks [$(date)]"
  echo "\`\`\`"
  run_snapraid -p "$SCRUB_PERCENT" -o "$SCRUB_AGE" -q scrub
  close_output_and_wait
  output_to_file_screen
  echo "\`\`\`"
  echo "SCRUB finished [$(date)]"
  mklog "INFO: SnapRAID SCRUB Job(s) finished"
  JOBS_DONE="$JOBS_DONE + SCRUB"
  # insert SCRUB marker to 'Everything OK' or 'Nothing to do' string to
  # differentiate it from SYNC job above
  sed_me "
    s/^Everything OK/${SCRUB_MARKER} Everything OK/g;
    s/^Nothing to do/${SCRUB_MARKER} Nothing to do/g" "$TMP_OUTPUT"
  # Remove the warning flag if set previously. This is done now to
  # take care of scenarios when user has manually synced or restored
  # deleted files and we will have missed it in the checks above.
  if [ -e "$SCRUB_COUNT_FILE" ]; then
    rm "$SCRUB_COUNT_FILE"
  fi
}

function service_array_setup() {
  # check if container names are set correctly
  if [ -z "$SERVICES" ] && [ -z "$DOCKER_HOST_SERVICES" ]; then
    echo "Please configure Containers. Unable to manage containers."
    ARRAY_VALIDATED=NO
  else
    echo "Docker containers management is enabled."
    ARRAY_VALIDATED=YES
  fi

  # check what docker mode is set
  if [ "$DOCKER_MODE" = 1 ]; then
    DOCKER_CMD1=pause
    DOCKER_CMD1_LOG="Pausing"
    DOCKER_CMD2=unpause
    DOCKER_CMD2_LOG="Unpausing"
    DOCKERCMD_VALIDATED=YES
  elif [ "$DOCKER_MODE" = 2 ]; then
    DOCKER_CMD1=stop
    DOCKER_CMD1_LOG="Stopping"
    DOCKER_CMD2=start
    DOCKER_CMD2_LOG="Starting"
    DOCKERCMD_VALIDATED=YES
  else
    echo "Please check your command configuration. Unable to manage containers."
    DOCKERCMD_VALIDATED=NO
  fi

  # validate docker configuration
  if [ "$ARRAY_VALIDATED" = YES ] && [ "$DOCKERCMD_VALIDATED" = YES ]; then
    DOCKERALLOK=YES
  else
    DOCKERALLOK=NO
  fi
}

function pause_services() {
  echo "### $DOCKER_CMD1_LOG Containers [$(date)]";
  if [ "$DOCKER_LOCAL" -eq 1 ]; then
    echo "$DOCKER_CMD1_LOG Local Container(s)";
    xargs -r -n1 -I{} docker "$DOCKER_CMD1" --time 60 {} <<< "$SERVICES" || true
  fi
  SERVICES_STOPPED=1
}

function resume_services() {
  if [ "$SERVICES_STOPPED" -eq 1 ]; then
    echo "### $DOCKER_CMD2_LOG Containers [$(date)]";
    if [ "$DOCKER_LOCAL" -eq 1 ]; then
      echo "$DOCKER_CMD2_LOG Local Container(s)";
      xargs -r -n1 -I{} docker "$DOCKER_CMD2" {} <<< "$SERVICES" || true
    fi
    SERVICES_STOPPED=0
  fi
}

function clean_desc() {
  [[ $- == *i* ]] && exec &>/dev/tty
 }

function final_cleanup() {
  resume_services
  clean_desc
  exit
}

function close_output_and_wait() {
  exec 1>&"$OUT" 2>&"$ERROR"
  CHILD_PID=$(pgrep -P $$)
  if [ -n "$CHILD_PID" ]; then
    wait "$CHILD_PID"
  fi
}

function output_to_file_screen() {
  # redirect all output to screen and file
  exec {OUT}>&1 {ERROR}>&2
  # NOTE: Not preferred format but valid: exec &> >(tee -ia "${TMP_OUTPUT}" )
  exec > >(tee -a "${TMP_OUTPUT}") 2>&1
}

function mklog() {
  [[ "$*" =~ ^([A-Za-z]*):\ (.*) ]] &&
  {
    PRIORITY=${BASH_REMATCH[1]} # INFO, DEBUG, WARN
    LOGMESSAGE=${BASH_REMATCH[2]} # the Log-Message
  }
  echo "$(date '+[%Y-%m-%d %H:%M:%S]') $(basename "$0"): $PRIORITY: '$LOGMESSAGE'" >> "$SNAPRAID_LOG"
}

function check_and_install() {
  PACKAGE_NAME=$1
  if [ "$(dpkg-query -W -f='${Status}' "$PACKAGE_NAME" 2>/dev/null | grep -c "ok installed")" -eq 0 ]; then
    echo "$PACKAGE_NAME has not been found and will be installed..."
    sudo apt-get install -y "$PACKAGE_NAME" > /dev/null 2>&1
    echo "$PACKAGE_NAME installed successfully."
  fi
}

function check_omv_version() {
    if dpkg -l | grep -q "openmediavault"; then
        version=$(dpkg-query -W -f='${Version}' openmediavault)
        if [[ $version ]]; then
            if dpkg --compare-versions "$version" "ge" "7"; then
                OMV_VERSION=7
            else
                OMV_VERSION=6
            fi
        else
            OMV_VERSION=0
        fi
    else
        OMV_VERSION=0
    fi
}

function pick_snapraid_conf_file() {
  search_conf_files "/etc/snapraid"
  result=$?
  if [ $result -eq 0 ]; then
      # Only one SnapRAID config file found, proceeding
      echo "Proceeding with the omv-snapraid-.conf file: $SNAPRAID_CONF"

  elif [ $result -eq 2 ]; then
      # Multiple SnapRAID config files found, stopping the script
      echo "Stopping the script due to multiple SnapRAID configuration files. Please choose one config file and update your settings in the script-config file at ""$CONFIG_FILE"". Available SnapRAID config files:"
          for file in "${conf_files[@]}"; do
              echo "$file"
          done
      mklog "WARN: Stopping the script due to multiple SnapRAID configuration files. Please choose one config file and update your settings."
    exit 1;

  else
    # No SnapRAID conf file found, stopping the script
      echo "SnapRAID configuration file not found. The script cannot be run! Please check your settings, because the specified file ""$SNAPRAID_CONF"" does not exist."
      mklog "WARN: SnapRAID configuration file not found. The script cannot be run! Please check your settings, because the specified file ""$SNAPRAID_CONF"" does not exist."
    exit 1;
  fi
}

function search_conf_files() {
    folder="$1"

    # Check if the directory exists
    if [ ! -d "$folder" ]; then
        echo "Directory $folder does not exist."
        return 1
    fi

    conf_files=("$folder"/omv-snapraid-*.conf)

    # Handle the case where the glob doesn't match anything (nullglob not set)
    if [ "${conf_files[0]}" = "$folder/omv-snapraid-*.conf" ] || [ ! -e "${conf_files[0]}" ]; then
        return 1
    fi

    # if one file is found
    if [ ${#conf_files[@]} -eq 1 ]; then
        SNAPRAID_CONF="${conf_files[0]}"
        return 0
    # if multiple files are found
    else
        return 2
    fi
}

function parse_snapraid_conf() {
  # content lines: keep everything after the first word "content"
  mapfile -t CONTENT_FILES < <(
    awk '
      /^[[:space:]]*(#|;|$)/ {next}                              # skip comments/blank
      /^[[:space:]]*content[[:space:]]+/ {
        sub(/^[[:space:]]*content[[:space:]]+/, "", $0)          # drop directive
        sub(/[[:space:]]*[#;].*$/, "", $0)                       # strip inline comments
        sub(/^[[:space:]]*/, "", $0); sub(/[[:space:]]*$/, "", $0)
        if (length($0)) print
      }
    ' "$SNAPRAID_CONF"
  )

  # parity (parity, 2-parity, 3-parity, ... z-parity); may be comma-separated
  mapfile -t PARITY_FILES < <(
    awk '
      /^[[:space:]]*(#|;|$)/ {next}
      /^[[:space:]]*([2-6z]-)?parity[[:space:]]+/ {
        sub(/^[[:space:]]*([2-6z]-)?parity[[:space:]]+/, "", $0) # drop directive
        sub(/[[:space:]]*[#;].*$/, "", $0)                       # strip inline comments
        sub(/^[[:space:]]*/, "", $0); sub(/[[:space:]]*$/, "", $0)
        gsub(/[[:space:]]*,[[:space:]]*/, "\n")                  # split comma list into lines
        print                                                    # one path per line
      }
    ' "$SNAPRAID_CONF"
  )
}

function ionice_args() {
  case "${IONICE_CLASS,,}" in
    idle)        echo "-c3" ;;
    besteffort|be)
                 echo "-c2 -n ${IONICE_PRIORITY:-7}" ;;
    realtime|rt) echo "-c1 -n ${IONICE_PRIORITY:-4}" ;;  # needs root, risky
    *)           echo "-c3" ;;  # default to idle
  esac
}

function run_snapraid() {
  local args=("$@")
  if command -v "$IONICE_BIN" >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    $IONICE_BIN $(ionice_args) "$NICE_BIN" -n "${NICE_LEVEL}" \
      "$SNAPRAID_BIN" -c "$SNAPRAID_CONF" "${args[@]}"
  else
    "$NICE_BIN" -n "${NICE_LEVEL}" \
      "$SNAPRAID_BIN" -c "$SNAPRAID_CONF" "${args[@]}"
  fi
}

# Set TRAP
trap final_cleanup INT EXIT

main "$@"