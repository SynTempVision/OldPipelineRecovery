#!/bin/bash
# pipeline_watchdog.sh - actively monitors rtsp-seek-server for the "alive
# but stuck" failure mode that the old while-loop can't catch (no exit
# event to react to). Reuses camera-check-v2.sh's own proven detection
# logic rather than inventing new checks - confirmed against a real
# broken example (sv-191, 2026-10-20): a 17-byte header-only image.pgm
# that BOTH the kernel-log USB-error check AND a naive pixel-variance
# check completely missed. Only a size check caught it.
#
# Stale-PID-file handling (the imgserv EEXIST bug class) is NOT this
# script's job - it's handled by rtsp-seek-server.service's own
# ExecStartPre, since it's a start-time concern, not an ongoing-monitoring
# one. This script only decides WHEN to restart, never how.

# Which systemd service to restart on detection - a camera only ever runs
# ONE pipeline type (Seek or Boson), never both, so this is the one thing
# that needs to change per deployment. Set to "rtsp-ir-server.service" on
# Boson/FLIR cameras instead.
PIPELINE_SERVICE="rtsp-seek-server.service"

RAMDISK="/usr/local/bin/camera/ramdisk/image.pgm"
MIN_BYTES=1000          # same threshold as camera-check-v2.sh
STALE_SECS=60           # same threshold as camera-check-v2.sh
CHECK_INTERVAL=30
GRACE_PERIOD=120
USB_ERR_THRESHOLD=5
REPEAT_THRESHOLD=2       # consecutive identical hashes = frozen at pixel level

LAST_RESTART_EPOCH=0
LAST_HASH=""
REPEAT_COUNT=0

while true; do
    sleep "$CHECK_INTERVAL"
    NOW=$(date +%s)
    [ $((NOW - LAST_RESTART_EPOCH)) -lt "$GRACE_PERIOD" ] && continue

    REASON=""

    # Layer 1: does the file even exist / have real data (catches the
    # sv-191 case - this must run FIRST, before any pixel-level check,
    # since a tiny header-only file can fool a variance check)
    if [ ! -f "$RAMDISK" ]; then
        REASON="image.pgm MISSING"
    else
        SIZE=$(stat -c %s "$RAMDISK" 2>/dev/null || echo 0)
        if [ "$SIZE" -lt "$MIN_BYTES" ]; then
            REASON="image.pgm EMPTY (${SIZE} bytes, header only)"
        else
            AGE=$(( $(date +%s) - $(stat -c %Y "$RAMDISK") ))
            if [ "$AGE" -gt "$STALE_SECS" ]; then
                REASON="image.pgm STALE (${AGE}s)"
            else
                # Layer 2: frozen-at-pixel-level via hash comparison across
                # polls (catches a real frame stuck re-writing the same
                # buffer, even while mtime keeps advancing)
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

    # Layer 3: kernel/USB error spam (won't catch sv-191's case, but
    # does catch the sv-31-style failure - different failure mode,
    # same action)
    USB_ERRS=$(dmesg | tail -2000 | grep -cE "usb.*error|cannot enumerate|device not accepting|usbdevfs_control failed|did not claim interface|usb disconnect|attempt power cycle|unable to enumerate")
    if [ "$USB_ERRS" -ge "$USB_ERR_THRESHOLD" ]; then
        REASON="${REASON:+$REASON, }usb_errors ($USB_ERRS)"
    fi

    if [ -n "$REASON" ]; then
        echo "$(date -Iseconds) WATCHDOG: restarting $PIPELINE_SERVICE - reason: $REASON" | sudo tee -a /var/log/pipeline_watchdog.log
        sudo systemctl restart "$PIPELINE_SERVICE"
        LAST_RESTART_EPOCH=$(date +%s)
        REPEAT_COUNT=0
    fi
done
