#!/bin/bash
# pipeline_watchdog.sh - actively monitors the old pipeline (rtsp-seek-
# server/rtsp-ir-server) AND imgserv for the "alive but stuck/down"
# failure modes nothing else catches automatically. Confirmed live
# against two real broken cameras (sv-191, sv-200, 2026-10-20).
#
# DELIBERATELY additive only: system_init.sh and the existing pipeline/
# imgserv startup lines are untouched. This script only detects problems
# and calls the camera's own already-working fix scripts
# (pipeline_restart.sh, restart_imgserv.sh) - no reimplementation of
# startup logic, no systemd takeover of anything. Removing this watchdog
# is just stopping one process; nothing else needs to change.
#
# Two independent check loops, different intervals since the two checks
# have very different cost: imgserv's port check is cheap (a few ms), so
# it runs every tick (5s) for fast reaction; image.pgm/USB checks are
# heavier (stat/md5sum/dmesg scan) and run every 6th tick (30s). Each has
# its own debounce + circuit breaker - they're unrelated failure domains,
# so one shouldn't affect the other's state.

PIPELINE_RESTART_SCRIPT="/usr/local/bin/camera/pipeline_restart.sh"
IMGSERV_RESTART_SCRIPT="/usr/local/bin/camera/restart_imgserv.sh"
RAMDISK="/usr/local/bin/camera/ramdisk/image.pgm"
MIN_BYTES=1000          # same threshold as camera-check-v2.sh
STALE_SECS=60           # same threshold as camera-check-v2.sh

TICK_INTERVAL=5                                              # base loop tick
PIPELINE_TICKS_PER_CHECK=6                                    # 6 * 5s = 30s for the heavier checks
GRACE_PERIOD=120
USB_ERR_THRESHOLD=5
REPEAT_THRESHOLD=2       # consecutive identical hashes = frozen at pixel level
BAD_STATE_THRESHOLD=2    # consecutive MISSING/EMPTY/STALE checks before acting
IMGSERV_BAD_THRESHOLD=2  # consecutive down-port checks before acting (~10s of real downtime)
MAX_RESTARTS=3           # circuit breaker: stop auto-restarting after this many...
RESTART_WINDOW_SECS=1800 # ...within this time window (30 min) - needs a human instead

# Both start equal to "now," not 0 - a watchdog that just started needs
# the same grace period a just-triggered restart gets, otherwise it'd
# judge things before the pipeline/imgserv have had a chance to come up.
LAST_PIPELINE_RESTART_EPOCH=$(date +%s)
LAST_IMGSERV_RESTART_EPOCH=$(date +%s)
LAST_HASH=""
REPEAT_COUNT=0
BAD_STATE_COUNT=0
IMGSERV_BAD_COUNT=0
PIPELINE_RESTART_HISTORY=()
IMGSERV_RESTART_HISTORY=()

TICK=0
while true; do
    sleep "$TICK_INTERVAL"
    TICK=$((TICK + 1))
    NOW=$(date +%s)

    # ---------------- imgserv check (every tick, ~5s) ----------------
    if [ $((NOW - LAST_IMGSERV_RESTART_EPOCH)) -ge "$GRACE_PERIOD" ]; then
        if ! ss -tln 2>/dev/null | grep -q ":2105 "; then
            IMGSERV_BAD_COUNT=$((IMGSERV_BAD_COUNT + 1))
        else
            IMGSERV_BAD_COUNT=0
        fi

        if [ "$IMGSERV_BAD_COUNT" -ge "$IMGSERV_BAD_THRESHOLD" ]; then
            PRUNED=()
            for ts in "${IMGSERV_RESTART_HISTORY[@]}"; do
                [ $((NOW - ts)) -lt "$RESTART_WINDOW_SECS" ] && PRUNED+=("$ts")
            done
            IMGSERV_RESTART_HISTORY=("${PRUNED[@]}")

            if [ "${#IMGSERV_RESTART_HISTORY[@]}" -ge "$MAX_RESTARTS" ]; then
                echo "$(date -Iseconds) WATCHDOG: CIRCUIT BREAKER - imgserv restarted ${#IMGSERV_RESTART_HISTORY[@]}x in ${RESTART_WINDOW_SECS}s, not retrying automatically. Needs a human." | sudo tee -a /var/log/pipeline_watchdog.log
            else
                echo "$(date -Iseconds) WATCHDOG: running $IMGSERV_RESTART_SCRIPT - reason: port 2105 down (${IMGSERV_BAD_COUNT}x consecutive)" | sudo tee -a /var/log/pipeline_watchdog.log
                sudo bash "$IMGSERV_RESTART_SCRIPT"
                IMGSERV_RESTART_HISTORY+=("$NOW")
                LAST_IMGSERV_RESTART_EPOCH="$NOW"
            fi
            IMGSERV_BAD_COUNT=0
        fi
    fi

    # -------- pipeline / image.pgm / USB checks (every 30s) --------
    [ $((TICK % PIPELINE_TICKS_PER_CHECK)) -ne 0 ] && continue
    [ $((NOW - LAST_PIPELINE_RESTART_EPOCH)) -lt "$GRACE_PERIOD" ] && continue

    REASON=""
    BAD_STATE=0

    # Layer 1: does the file even exist / have real data (catches the
    # sv-191 case - must run FIRST, before any pixel-level check, since
    # a tiny header-only file can fool a variance check)
    if [ ! -f "$RAMDISK" ]; then
        REASON="image.pgm MISSING"
        BAD_STATE=1
    else
        SIZE=$(stat -c %s "$RAMDISK" 2>/dev/null || echo 0)
        if [ "$SIZE" -lt "$MIN_BYTES" ]; then
            REASON="image.pgm EMPTY (${SIZE} bytes, header only)"
            BAD_STATE=1
        else
            AGE=$(( $(date +%s) - $(stat -c %Y "$RAMDISK") ))
            if [ "$AGE" -gt "$STALE_SECS" ]; then
                REASON="image.pgm STALE (${AGE}s)"
                BAD_STATE=1
            else
                # Layer 2: frozen-at-pixel-level via hash comparison across
                # polls (catches a real frame stuck re-writing the same
                # buffer, even while mtime keeps advancing).
                HASH=$(md5sum "$RAMDISK" 2>/dev/null | cut -d' ' -f1)
                if [ -n "$HASH" ] && [ "$HASH" = "$LAST_HASH" ]; then
                    REPEAT_COUNT=$((REPEAT_COUNT + 1))
                else
                    REPEAT_COUNT=0
                fi
                LAST_HASH="$HASH"
                if [ "$REPEAT_COUNT" -ge "$REPEAT_THRESHOLD" ]; then
                    REASON="image.pgm REPEATING (${REPEAT_COUNT}x unchanged)"
                fi
            fi
        fi
    fi

    # MISSING/EMPTY/STALE debounce - require the same kind of bad reading
    # on consecutive checks before acting, so a single noisy/transient
    # check doesn't trigger an unnecessary restart. REPEATING already has
    # its own equivalent debounce above.
    if [ "$BAD_STATE" -eq 1 ]; then
        BAD_STATE_COUNT=$((BAD_STATE_COUNT + 1))
        if [ "$BAD_STATE_COUNT" -lt "$BAD_STATE_THRESHOLD" ]; then
            REASON=""   # seen once so far - not enough to act on yet
        fi
    else
        BAD_STATE_COUNT=0
    fi

    # Layer 3: kernel/USB error spam (won't catch sv-191/sv-200's case,
    # but does catch the sv-31-style failure - different failure mode,
    # same action). Self-debounced by the >=5-in-2000-lines threshold.
    USB_ERRS=$(dmesg | tail -2000 | grep -cE "usb.*error|cannot enumerate|device not accepting|usbdevfs_control failed|did not claim interface|usb disconnect|attempt power cycle|unable to enumerate")
    if [ "$USB_ERRS" -ge "$USB_ERR_THRESHOLD" ]; then
        REASON="${REASON:+$REASON, }usb_errors ($USB_ERRS)"
    fi

    if [ -n "$REASON" ]; then
        PRUNED=()
        for ts in "${PIPELINE_RESTART_HISTORY[@]}"; do
            [ $((NOW - ts)) -lt "$RESTART_WINDOW_SECS" ] && PRUNED+=("$ts")
        done
        PIPELINE_RESTART_HISTORY=("${PRUNED[@]}")

        if [ "${#PIPELINE_RESTART_HISTORY[@]}" -ge "$MAX_RESTARTS" ]; then
            echo "$(date -Iseconds) WATCHDOG: CIRCUIT BREAKER - pipeline restarted ${#PIPELINE_RESTART_HISTORY[@]}x in ${RESTART_WINDOW_SECS}s, not retrying automatically. Needs a human. Last reason: $REASON" | sudo tee -a /var/log/pipeline_watchdog.log
        else
            echo "$(date -Iseconds) WATCHDOG: running $PIPELINE_RESTART_SCRIPT - reason: $REASON" | sudo tee -a /var/log/pipeline_watchdog.log
            sudo bash "$PIPELINE_RESTART_SCRIPT"
            PIPELINE_RESTART_HISTORY+=("$NOW")
            LAST_PIPELINE_RESTART_EPOCH="$NOW"
            REPEAT_COUNT=0
            BAD_STATE_COUNT=0
        fi
    fi
done
