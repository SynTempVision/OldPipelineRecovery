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

## Still open: the hang/continuous-error-loop case

This is the bigger, harder gap (see table above) - no detection or fix has been designed for it yet.
Real unknown before designing it: does sv-31's documented failure (continuous
`USBDEVFS_CONTROL ETIMEDOUT` errors, PID never changing for 8+ days) actually freeze `image.pgm`
(the existing pixel-variance frozen-frame check would catch it), or do frames keep nominally
updating despite the error spam (frozen-frame detection alone would miss it, need a second signal
like watching the error rate directly)? Not yet checked against a live example.
