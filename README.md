# pipeline_recovery

Automatic detection + recovery for the old pipeline's known failure modes, matching the
new pipeline's self-recovery behavior as closely as practical.

## Failure modes (identified 2026-10-20)

| Failure mode | Fix | Automated today? |
|---|---|---|
| Clean process exit | `usbreset` + restart | Yes — `rtsp-seek-server.sh`'s own while-loop |
| Hang / continuous error-loop without exit (the common real-world case — sv-31, sv-139, sv-159) | kill + `pipeline_restart.sh` | Not reliably — depends on periodic external health-check, which doesn't always catch it (sv-31 stuck 8+ days, recovery loop never fired) |
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

## The hang/continuous-error-loop case: designed and validated against a real example

`pipeline_watchdog.sh` + `rtsp-seek-server.service` + `pipeline-watchdog.service` (this directory).

**Design:** `rtsp-seek-server` moves from the old shell while-loop into its own systemd service
(`Type=simple` - it runs in the foreground, no daemonizing, so no `PIDFile=` needed for systemd's
own tracking; the `/var/run/rtsp-seek-server.pid` file it still clears via `ExecStartPre` is a
separate concern - whatever the binary itself checks internally on startup, same bug class as
imgserv's stale-PID issue). `usbreset 289d:0011` also runs as an `ExecStartPre`, since Seek Thermal
USB devices have documented history of getting stuck at the bus level, not just the process level
(see [[project_sv126_frozen_seek_usb]]) - keeping this step is cheap insurance even without proof
it's required on every restart.

A second, separate service (`pipeline-watchdog.service`) runs `pipeline_watchdog.sh` continuously,
polling every 30s (polling is unavoidable here - unlike imgserv, there's no process-exit event for
a stuck-but-alive pipeline to react to). When it detects a problem, its only action is
`systemctl restart rtsp-seek-server.service` - all the "how to restart cleanly" logic lives in the
service definition, not duplicated in the watchdog.

**Detection reuses `camera-check-v2.sh`'s own already-proven categories** rather than inventing new
ones: MISSING, EMPTY (size < 1000 bytes), STALE (mtime > 60s old), REPEATING (md5sum unchanged
across consecutive polls - catches a frame frozen at the pixel level even while mtime keeps
advancing), plus a separate USB/kernel-error-log layer (>=5 matches, same threshold already used
elsewhere) for the sv-31-style failure class.

**Validated against a real live example (sv-191, 2026-10-20), not just theory:**
- Found `image.pgm` stuck at 17 bytes - a complete PGM header (`P5 320 240\n65535\n`) with ZERO
  pixel data ever appended, despite a fresh mtime (something keeps rewriting the header, never
  the body).
- `getimage.sh` (the tool the 2026-05-21 architecture doc describes as writing this file) is NOT
  running, NOT in `system_init.sh`, NOT in either crontab - the real write mechanism on this
  camera's current setup wasn't identified.
- **Kernel/USB-error check: MISSED this failure completely** - `dmesg` showed 0 matching errors,
  `lsusb` showed the Seek camera fully enumerated and healthy. The failure is pure software, not
  hardware/USB.
- **A naive pixel-variance check (my first draft) ALSO MISSED it** - `tail -c 200` on a 17-byte
  file just reads the whole file, and the header text (`P5 320 240...`) has plenty of natural byte
  variety, so it reads as "not frozen." This is exactly why the EMPTY/size check must run
  **before and independently of** any pixel-level check, never as a secondary/redundant signal -
  for this real failure, size was the ONLY signal of the ones tested that caught it.
- This confirms multiple independent layers are genuinely necessary, not just thorough-for-
  thoroughness's-sake: at least two different real fleet failures (sv-191's silent EMPTY state,
  sv-31's loud USB-error spam) are each invisible to the other's detection method.

**Explicit scope decision carried over from existing tooling:** `camera-check-v2.sh`'s REPEATING
check is deliberately detection-only today (auto-restart on it "wasn't approved, 2026-09-24" per
its own code comment) - the new watchdog currently DOES act on REPEATING (unlike the old script).
Worth confirming this is the intended change before fleet deployment, not just inherited silently.

**Not yet done:** deployed or tested live anywhere. sv-191 is sitting in its confirmed-broken state,
not yet fixed (manual `pipeline_restart.sh` was proposed as both a live fix and an end-to-end test
of the recovery action, not yet run as of this write-up).
