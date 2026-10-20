# pipeline_recovery

Automatic detection + recovery for the old pipeline's known failure modes, matching the
new pipeline's self-recovery behavior as closely as practical.

**Everything here is purely additive.** `system_init.sh` and the existing pipeline/imgserv wrapper
scripts on every camera are completely untouched. `pipeline_watchdog.sh` only detects problems and
calls the camera's own already-working fix scripts (`pipeline_restart.sh`, `restart_imgserv.sh`) -
no reimplementation of startup logic, no systemd takeover of anything that already exists. Removing
this later is just stopping one process (`pipeline-watchdog.service`), nothing else to undo.

## Course correction (2026-10-20, important for anyone picking this up later)

The first design replaced the pipeline's own startup with dedicated systemd services
(`rtsp-seek-server.service`, `rtsp-ir-server.service`, each porting `usbreset`/PID-clear into
`ExecStartPre`), and separately gave imgserv its own systemd service too. That was the wrong scope
for what was actually asked - "add automatic recovery," not "rebuild how the pipeline/imgserv
start." It also kept surfacing new gaps from re-implementing logic the existing wrappers already
do correctly (missing `GST_PLUGIN_PATH`, missing the `image.head.seek`/`image.head.boson` copy
step, a boot-grace-period bug) - each one only found by accident, not by design review. **Pulled
back to one unified watchdog script that only calls already-existing, already-proven fix scripts.**
No pipeline- or imgserv-specific systemd units exist in this repo anymore.

## Failure modes (identified 2026-10-20)

| Failure mode | Fix | Automated today? |
|---|---|---|
| Clean process exit | `usbreset` + restart | Yes — `rtsp-seek-server.sh`'s own while-loop |
| Hang / continuous error-loop without exit (the common real-world case — sv-31, sv-139, sv-159, confirmed live on sv-191/sv-200) | `pipeline_restart.sh` (already existed) | **Watchdog built this session** — see below |
| imgserv down (separate process from the main pipeline) | `restart_imgserv.sh` (already existed, already proven on sv-143/sv-154) | **Watchdog built this session** — see below |
| USB instability (>=5 resets/errors) | reboot | No — warning only, reboot is always manual |
| Full USB enumeration failure at boot (hardware-level) | reboot, sometimes physical | No |

## `pipeline_watchdog.sh` - one script, two independent check loops

Runs as `pipeline-watchdog.service` (systemd here only supervises the watchdog script itself -
`Restart=on-failure` if *it* crashes - no dependency on any pipeline/imgserv-specific unit, since
none exist).

**Loop 1 - imgserv, every 5s (tick interval):** checks port 2105 via `ss -tln`. This check is cheap
(a few ms), so it runs on a tight interval for fast reaction - considered wrapping imgserv in its
own systemd service instead (near-instant `Restart=on-failure`), but decided against it for
consistency: one unified mechanism (detect + call the existing fix script) across both failure
domains, instead of two different philosophies for two parts of the same project. A 2-consecutive-
check debounce (~10s of real downtime) avoids reacting to a single momentary blip. Calls
`restart_imgserv.sh` on trigger - the same script already verified working on sv-143/sv-154
(2026-09-24), previously only triggered manually via `run_fix.py`'s Command Menu "Run" button.

**Loop 2 - pipeline (image.pgm + USB), every 30s (6 ticks):** heavier checks (`stat`/`md5sum`/a
`dmesg` scan), so it runs less often. Detection reuses `camera-check-v2.sh`'s own already-proven
categories rather than inventing new ones: MISSING, EMPTY (size < 1000 bytes), STALE (mtime > 60s
old), REPEATING (md5sum unchanged across consecutive polls - catches a frame frozen at the pixel
level even while mtime keeps advancing), plus a separate USB/kernel-error-log layer (>=5 matches,
same threshold already used elsewhere) for the sv-31-style failure class. Calls `pipeline_restart.sh`
on trigger.

Each loop has its own independent debounce, grace period, and circuit breaker (3 restarts / 30 min,
then stop and log "needs a human" instead of retrying forever) - they're unrelated failure domains,
so one shouldn't affect the other's state.

### Validated against two real live examples (2026-10-20), not just theory

- **sv-191 (Seek):** `image.pgm` stuck at 17 bytes - a complete PGM header (`P5 320 240\n65535\n`)
  with ZERO pixel data ever appended, despite a fresh mtime. Kernel/USB-error check MISSED this
  completely (`dmesg` showed 0 matches, `lsusb` showed the camera fully enumerated/healthy) - pure
  software failure. A naive pixel-variance check (an earlier draft) ALSO missed it, since
  `tail -c 200` on a 17-byte file just reads the header text, which has plenty of natural byte
  variety and reads as "not frozen." This is why the EMPTY/size check must run **before and
  independently of** any pixel-level check, never as a secondary/redundant signal.
- **sv-200 (Boson):** found frozen too, confirming the underlying "alive but stuck, nothing exits"
  problem isn't Seek-specific - it's a general old-pipeline-architecture gap across both camera
  types. `rtsp-ir-server`'s wrapper (live-checked on sv-200) has no `usbreset` equivalent at all and
  resolves its device via `/dev/v4l/by-id/usb-FLIR_Boson*` instead of a fixed VID:PID - confirmed
  architectural difference, not assumed parity with Seek (this is also why there's no
  Boson-specific systemd unit to maintain parity for anymore - `pipeline_restart.sh` already
  handles whichever pipeline is actually installed).
- Together these confirm multiple independent detection layers are genuinely necessary: sv-191's
  silent EMPTY state and sv-31's loud USB-error spam are each invisible to the other's method.

### Real bug caught by actually running it, not by review

The first live test on `Lab 103.155` (`sv-155`) failed immediately with
`$'\r': command not found` - **the deployed script had Windows (CRLF) line endings**, because this
machine's git `autocrlf` setting converts LF to CRLF on checkout, and `scp` sends whatever's on
disk as-is. The repo's stored blobs were always LF; the working-tree files on disk were not.
Fixed via `.gitattributes` (`eol=lf` for `.sh`/`.service`/`.logrotate`), which forces LF on checkout
regardless of the machine's global setting. **This almost certainly affected every file this repo
deployed to any camera before this fix landed** - worth re-deploying anywhere that happened.

### Log rotation

Neither `/var/log/pipeline_watchdog.log` (new) nor `/var/log/rtsp-seek-server.log`/
`rtsp-ir-server.log` (pre-existing, already documented elsewhere as reaching 100MB+ during bad
periods) had any rotation configured. More frequent automated restarts (vs. the old rare-manual
reality) means faster growth of the pre-existing logs too, not just the new one. Three
`.logrotate` configs added, matching the exact pattern already used elsewhere in this fleet
(`newSDK/newsdk-install/vcgencmd/logrotate-vcgencmd`): daily, 7-day retention, compressed.

### Safety additions (discussed before building, not added reactively)

- MISSING/EMPTY/STALE require the same bad reading on 2 consecutive checks before acting.
- imgserv's port-down check requires 2 consecutive checks too (added specifically because polling
  every 5s instead of 30s raises the chance of catching a momentary, self-resolving blip).
- Circuit breaker per loop: 3 restarts / 30 min, then stop and flag for a human.
- Boot-grace-period bug fixed: both loops' "last restart" timestamps start at the current time
  instead of `0`, so a freshly-started watchdog gets the same grace period a just-triggered restart
  does, instead of judging state before the pipeline/imgserv have had a chance to come up.

### Explicit scope decision carried over from existing tooling

`camera-check-v2.sh`'s REPEATING check is deliberately detection-only today (auto-restart on it
"wasn't approved, 2026-09-24" per its own code comment) - this watchdog currently DOES act on
REPEATING (unlike the old script). Worth confirming this is the intended change before fleet
deployment, not just inherited silently.

## Status as of this write-up

- **`Lab 103.155` (sv-155):** `pipeline-watchdog.service` installed, enabled, and confirmed
  running persistently (survived a real check: `systemctl status` showed `active (running)`,
  correct PID tree). No false positives on this healthy camera - no intervention log created,
  `image.pgm` confirmed fresh/full-size (153,617 bytes) throughout. imgserv cutover was discussed
  but explicitly NOT done - imgserv stays on its original `system_init.sh` startup, now also
  monitored by the watchdog's port-check loop instead of switching startup mechanisms.
- **sv-191, sv-200:** still sitting in their confirmed-broken state - not yet deployed to, so not
  yet fixed. Would be the real end-to-end test of the detection-and-restart path, since their
  current state is already known independently.
