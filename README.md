# pipeline_recovery

Automatic detection + recovery for the old pipeline's known failure modes, matching the
new pipeline's self-recovery behavior as closely as practical.

## Failure modes (identified 2026-10-20)

| Failure mode | Fix | Automated today? |
|---|---|---|
| Clean process exit | `usbreset` + restart | Yes — `rtsp-seek-server.sh`'s own while-loop |
| Hang / continuous error-loop without exit (the common real-world case — sv-31, sv-139, sv-159, and confirmed live on sv-191/sv-200 today) | `pipeline_restart.sh` (already existed) | **Watchdog built this session** — see below; not yet deployed/enabled anywhere |
| imgserv dies (separate process from the main pipeline) | restart imgserv, clearing a stale `/run/imgserv.pid` first | **Fixed this session** — see below |
| USB instability (>=5 resets/errors) | reboot | No — warning only, reboot is always manual |
| Full USB enumeration failure at boot (hardware-level) | reboot, sometimes physical | No |

## imgserv: done this session

`restart_imgserv.sh` (`sandbox\deploy\ImgservRestart\restart_imgserv.sh`) already existed with
correct detection (port 2105 state + stale-PID check) and fix logic, verified working on sv-143
and sv-154 (2026-09-24) — but it required manual triggering via `run_fix.py`'s Command Menu "Run"
button. Nothing ran it automatically.

**Decision: don't cron-poll it. Wrap imgserv in its own systemd service instead** (`imgserv.service`,
this directory) — reuses the same self-recovery mechanism the new pipeline already has
(`Restart=on-failure`), reacts to the actual process-death event instead of polling on a timer, and
needs no custom watcher script to build or maintain.

- `Type=forking` + `PIDFile=/run/imgserv.pid` — matches imgserv's confirmed self-daemonizing
  behavior (checked for a foreground flag via `--help`/`-h`/`strings`/forcing an error - none found,
  `opt_isdaemon` string exists in the binary but its exact flag letter couldn't be determined without
  disassembly, not worth pursuing further).
- `ExecStartPre=` clears a stale PID file before every start attempt (same stale-PID bug that broke
  every previous restart attempt, now handled unconditionally instead of only when someone manually
  runs the fix script).
- `Restart=on-failure` + `RestartSec=5` is the actual automation - systemd restarts it within ~5s of
  a crash, no cron, no external SSH trigger.

**Not yet done:** tested live on a camera. Next step is sv-143 or sv-154 (both already proven safe
for `restart_imgserv.sh`): disable the old `imgserv -p 2105 &` line in `system_init.sh`, install this
unit, `systemctl enable --now imgserv`, then confirm it survives a manual `sudo kill` of the imgserv
process (should respawn within ~5s). Not yet deployed anywhere.

## The hang/continuous-error-loop case: `pipeline_watchdog.sh`

**Course correction (2026-10-20, important for anyone picking this up later):** the first design
replaced the pipeline's own startup with a systemd service (`Type=simple`, porting `usbreset` +
PID-file-clear into `ExecStartPre`). That was the wrong scope for what was actually asked -
"add automatic recovery," not "rebuild how the pipeline starts." It also kept surfacing new gaps
from re-implementing logic the existing wrapper already does correctly (missing
`GST_PLUGIN_PATH`, missing the `image.head.seek`/`image.head.boson` copy step, a boot-grace-period
bug). **Pulled back to a purely additive design instead:** `system_init.sh` and the existing
pipeline wrapper scripts are completely untouched. `pipeline_watchdog.sh` only detects problems and
calls the camera's own already-working `pipeline_restart.sh` when it finds one - no reimplementation
of startup logic, no risk to the proven startup sequence, and removing the watchdog later is just
stopping one process, nothing else to undo.

`pipeline-watchdog.service` runs `pipeline_watchdog.sh` continuously (systemd here only supervises
the watchdog script itself - `Restart=on-failure` if the watchdog crashes - it has no dependency on
any pipeline-specific unit). Polling (every 30s) is unavoidable - unlike imgserv, there's no
process-exit event for a stuck-but-alive pipeline to react to.

**Detection reuses `camera-check-v2.sh`'s own already-proven categories** rather than inventing new
ones: MISSING, EMPTY (size < 1000 bytes), STALE (mtime > 60s old), REPEATING (md5sum unchanged
across consecutive polls - catches a frame frozen at the pixel level even while mtime keeps
advancing), plus a separate USB/kernel-error-log layer (>=5 matches, same threshold already used
elsewhere) for the sv-31-style failure class.

**Validated against two real live examples (2026-10-20), not just theory:**
- **sv-191 (Seek):** `image.pgm` stuck at 17 bytes - a complete PGM header (`P5 320 240\n65535\n`)
  with ZERO pixel data ever appended, despite a fresh mtime. Kernel/USB-error check MISSED this
  completely (`dmesg` showed 0 matches, `lsusb` showed the camera fully enumerated/healthy) - pure
  software failure. A naive pixel-variance check (an earlier draft) ALSO missed it, since
  `tail -c 200` on a 17-byte file just reads the header text, which has plenty of natural byte
  variety and reads as "not frozen." This is why the EMPTY/size check must run **before and
  independently of** any pixel-level check, never as a secondary/redundant signal.
- **sv-200 (Boson):** found frozen too, confirming the underlying "alive but stuck, nothing exits"
  problem isn't Seek-specific - it's a general old-pipeline-architecture gap across both camera
  types. `rtsp-ir-server`'s wrapper (`sv-200`, live-checked) has no `usbreset` equivalent at all and
  resolves its device via `/dev/v4l/by-id/usb-FLIR_Boson*` instead of a fixed VID:PID - confirmed
  architectural differences, not assumed parity with Seek.
- Together these confirm multiple independent detection layers are genuinely necessary: sv-191's
  silent EMPTY state and sv-31's loud USB-error spam are each invisible to the other's method.

**Safety additions after discussing the risk of false positives / restart loops:**
- MISSING/EMPTY/STALE now require the same bad reading on **2 consecutive checks** before acting
  (REPEATING already had an equivalent debounce via its hash-comparison design) - filters a single
  noisy/transient reading instead of restarting an otherwise-healthy pipeline.
- **Circuit breaker:** stops auto-restarting after 3 restarts within a 30-minute window, logging
  that it needs a human instead of retrying forever - matches the existing
  warn-then-stop-and-flag pattern already used in `camera-check-v2.sh`'s "REBOOT NEEDED" status.
- Fixed the boot-grace-period bug: `LAST_RESTART_EPOCH` now starts at the current time instead of
  `0`, so a freshly-started watchdog gets the same grace period a just-triggered restart does,
  instead of judging `image.pgm` before the pipeline has had a chance to produce its first frame.

**Explicit scope decision carried over from existing tooling:** `camera-check-v2.sh`'s REPEATING
check is deliberately detection-only today (auto-restart on it "wasn't approved, 2026-09-24" per
its own code comment) - this watchdog currently DOES act on REPEATING (unlike the old script).
Worth confirming this is the intended change before fleet deployment, not just inherited silently.

**Not yet done:** deployed or enabled live anywhere. `deploy_pipeline_recovery.ps1` installs the
files but deliberately does not enable/start them - sv-191 and sv-200 are both sitting in their
confirmed-broken state, not yet fixed.
