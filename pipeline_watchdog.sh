#!/bin/bash
# pipeline_watchdog.sh - actively monitors rtsp-seek-server/rtsp-ir-server
# for the "alive but stuck" failure mode that the old while-loop can't
# catch (no exit event to react to). Reuses camera-check-v2.sh's own
# proven detection logic rather than inventing new checks - confirmed
# against two real broken examples (sv-191, sv-200, 2026-10-20).
#
# DELIBERATELY additive only: this does NOT replace the pipeline's normal
# startup (system_init.sh and the existing wrapper scripts are untouched)
# and does NOT reimplement pipeline_restart.sh's own logic - it just
# calls that already-working script when it detects a problem. To remove
# this watchdog entirely, just stop/remove this one process; nothing else
# about the camera's setup needs to change.

RESTART_SCRIPT="/usr/local/bin/camera/pipeline_restart.sh"
RAMDISK="/usr/local/bin/camera/ramdisk/image.pgm"
MIN_BYTES=1000          # same threshold as camera-check-v2.sh
STALE_SECS=60           # same threshold as camera-check-v2.sh
CHECK_INTERVAL=30
GRACE_PERIOD=120
USB_ERR_THRESHOLD=5
REPEAT_THRESHOLD=2       # consecutive identical hashes = frozen at pixel level
BAD_STATE_THRESHOLD=2    # consecutive MISSING/EMPTY/STALE checks before acting - filters a one-off blip
MAX_RESTARTS=3           # circuit breaker: stop auto-restarting after this many...
RESTART_WINDOW_SECS=1800 # ...within this time window (30 min) - needs a human instead

# Starts equal to "now," not 0 - a camera/watchdog that just booted needs
# the same grace period a just-triggered restart gets, otherwise the
# watchdog would start judging image.pgm before the pipeline has even had
# a chance to produce its first real frame.
LAST_RESTART_EPOCH=$(date +%s)
LAST_HASH=""
REPEAT_COUNT=0
BAD_STATE_COUNT=0
RESTART_HISTORY=()   # epoch timestamps of recent restarts, for the circuit breaker

while true; do
    sleep "$CHECK_INTERVAL"
    NOW=$(date +%s)
    [ $((NOW - LAST_RESTART_EPOCH)) -lt "$GRACE_PERIOD" ] && continue

    REASON=""
    BAD_STATE=0

    # Layer 1: does the file even exist / have real data (catches the
    # sv-191 case - this must run FIRST, before any pixel-level check,
    # since a tiny header-only file can fool a variance check)
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
                # buffer, even while mtime keeps advancing). Already
                # self-debounced via REPEAT_THRESHOLD, same idea as the
                # BAD_STATE debounce below just pre-existing.
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
    # check doesn't trigger an unnecessary restart of an otherwise-healthy
    # pipeline. REPEATING already has its own equivalent debounce above.
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
    # same action). Already self-debounced by the >=5-in-2000-lines
    # threshold itself, no extra consecutive-check logic needed here.
    USB_ERRS=$(dmesg | tail -2000 | grep -cE "usb.*error|cannot enumerate|device not accepting|usbdevfs_control failed|did not claim interface|usb disconnect|attempt power cycle|unable to enumerate")
    if [ "$USB_ERRS" -ge "$USB_ERR_THRESHOLD" ]; then
        REASON="${REASON:+$REASON, }usb_errors ($USB_ERRS)"
    fi

    if [ -n "$REASON" ]; then
        # Circuit breaker - prune restart history older than the window,
        # then check if we're already at the limit before acting again.
        PRUNED=()
        for ts in "${RESTART_HISTORY[@]}"; do
            [ $((NOW - ts)) -lt "$RESTART_WINDOW_SECS" ] && PRUNED+=("$ts")
        done
        RESTART_HISTORY=("${PRUNED[@]}")

        if [ "${#RESTART_HISTORY[@]}" -ge "$MAX_RESTARTS" ]; then
            echo "$(date -Iseconds) WATCHDOG: CIRCUIT BREAKER - ${#RESTART_HISTORY[@]} restarts in the last ${RESTART_WINDOW_SECS}s, not restarting again automatically. Needs a human. Last reason: $REASON" | sudo tee -a /var/log/pipeline_watchdog.log
        else
            echo "$(date -Iseconds) WATCHDOG: running $RESTART_SCRIPT - reason: $REASON" | sudo tee -a /var/log/pipeline_watchdog.log
            sudo bash "$RESTART_SCRIPT"
            RESTART_HISTORY+=("$NOW")
            LAST_RESTART_EPOCH="$NOW"
            REPEAT_COUNT=0
            BAD_STATE_COUNT=0
        fi
    fi
done
