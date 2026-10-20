# ================================================================
# deploy_pipeline_recovery.ps1 - Deploy the systemd-based pipeline
# recovery set (imgserv.service, the Seek-or-Boson pipeline service,
# pipeline-watchdog.service, pipeline_watchdog.sh) to a camera.
#
# Auto-detects Seek vs Boson by checking which binary actually exists on
# the camera (not a cameras.json field - nothing there tracks this today,
# and a live check can't go stale the way a hand-maintained field could).
#
# SAFETY: this installs the new units but does NOT enable/start them and
# does NOT touch the camera's existing startup mechanism (system_init.sh,
# the old wrapper scripts). That cutover - stopping the old process,
# disabling its startup line, then `systemctl enable --now` on the new
# services - is deliberately a separate, manual step. Flipping a live
# camera's running pipeline automatically as part of a deploy risks an
# unplanned outage on an otherwise-working camera; this has not yet been
# tested end-to-end on a live unit.
#
# Usage:
#   .\deploy_pipeline_recovery.ps1 -Camera sv-191
#   .\deploy_pipeline_recovery.ps1 -IP 172.17.103.200
#   .\deploy_pipeline_recovery.ps1 -Camera sv-191 -Preview
# ================================================================

param(
    [string]$Camera  = "",
    [string]$IP      = "",
    [string]$SshUser = "camera",
    [switch]$Preview
)

$ErrorActionPreference = "Stop"
$ScriptDir   = $PSScriptRoot
$CamerasJson = "$PSScriptRoot\..\SiteCameraChecks\cameras.json"

if ($Camera -eq "" -and $IP -eq "") {
    Write-Host "ERROR: must supply -Camera <name> or -IP <address>" -ForegroundColor Red; exit 1
}

if ($IP -ne "") {
    $target = [PSCustomObject]@{ name = "(ad-hoc)"; ip = $IP; user = $SshUser }
} else {
    if (-not (Test-Path $CamerasJson)) {
        Write-Host "ERROR: cameras.json not found at $CamerasJson" -ForegroundColor Red; exit 1
    }
    $allCameras = Get-Content $CamerasJson | ConvertFrom-Json
    $matched = $allCameras | Where-Object { $_.name -eq $Camera }
    if (-not $matched) {
        Write-Host "ERROR: '$Camera' not found in cameras.json" -ForegroundColor Red; exit 1
    }
    $u = if ($matched.user) { $matched.user } else { $SshUser }
    $target = [PSCustomObject]@{ name = $matched.name; ip = $matched.ip; user = $u }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Pipeline Recovery Deploy"              -ForegroundColor Cyan
Write-Host "  Target   : $($target.name)  ($($target.ip))" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$SshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL")

# -------- detect pipeline type --------
Write-Host "[1/5] Detecting pipeline type..." -ForegroundColor Yellow
$detectCmd = "if [ -f /usr/local/bin/camera/rtsp-seek-server ]; then echo seek; elif [ -f /usr/local/bin/camera/rtsp-ir-server ]; then echo boson; else echo unknown; fi"
$pipelineType = (& ssh @SshOpts "$($target.user)@$($target.ip)" $detectCmd).Trim()

if ($pipelineType -eq "seek") {
    $pipelineService = "rtsp-seek-server.service"
    $pipelineUnitFile = "rtsp-seek-server.service"
    Write-Host "      Detected: Seek Thermal (rtsp-seek-server)" -ForegroundColor Green
} elseif ($pipelineType -eq "boson") {
    $pipelineService = "rtsp-ir-server.service"
    $pipelineUnitFile = "rtsp-ir-server.service"
    Write-Host "      Detected: Boson/FLIR (rtsp-ir-server)" -ForegroundColor Green
} else {
    Write-Host "      ERROR: neither rtsp-seek-server nor rtsp-ir-server found on this camera - aborting." -ForegroundColor Red
    exit 1
}

if ($Preview) {
    Write-Host ""
    Write-Host "Preview only - would:" -ForegroundColor Yellow
    Write-Host "  1. Copy imgserv.service, $pipelineUnitFile, pipeline-watchdog.service, pipeline_watchdog.sh to $($target.ip):~/" -ForegroundColor Yellow
    Write-Host "  2. sudo mv the three .service files into /etc/systemd/system/, pipeline_watchdog.sh into /usr/local/bin/camera/ (chmod +x)" -ForegroundColor Yellow
    Write-Host "  3. Patch pipeline-watchdog.service's After=/Requires= and pipeline_watchdog.sh's PIPELINE_SERVICE to '$pipelineService'" -ForegroundColor Yellow
    Write-Host "  4. sudo systemctl daemon-reload" -ForegroundColor Yellow
    Write-Host "  (units are installed but NOT enabled/started - cutover from the old startup mechanism is a separate manual step)" -ForegroundColor Yellow
    exit
}

# -------- build a locally-patched copy of the generic unit + script --------
$TmpDir = Join-Path $env:TEMP "pipeline_recovery_deploy_$($target.name)"
if (Test-Path $TmpDir) { Remove-Item $TmpDir -Recurse -Force }
New-Item -ItemType Directory -Path $TmpDir | Out-Null

(Get-Content "$ScriptDir\pipeline-watchdog.service") `
    -replace "rtsp-seek-server\.service", $pipelineService |
    Set-Content "$TmpDir\pipeline-watchdog.service" -Encoding utf8

(Get-Content "$ScriptDir\pipeline_watchdog.sh") `
    -replace 'PIPELINE_SERVICE="rtsp-seek-server\.service"', "PIPELINE_SERVICE=`"$pipelineService`"" |
    Set-Content "$TmpDir\pipeline_watchdog.sh" -Encoding utf8

$status = "OK"
try {
    Write-Host "[2/5] Copying files to home directory..." -ForegroundColor Yellow
    & scp @SshOpts "$ScriptDir\imgserv.service" "$ScriptDir\$pipelineUnitFile" "$TmpDir\pipeline-watchdog.service" "$TmpDir\pipeline_watchdog.sh" "$($target.user)@$($target.ip):~/"
    if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host "[3/5] Moving units + script into place..." -ForegroundColor Yellow
    $moveCmd = "sudo mv ~/imgserv.service ~/$pipelineUnitFile ~/pipeline-watchdog.service /etc/systemd/system/ && " +
               "sudo mv ~/pipeline_watchdog.sh /usr/local/bin/camera/pipeline_watchdog.sh && " +
               "sudo chmod +x /usr/local/bin/camera/pipeline_watchdog.sh"
    & ssh @SshOpts "$($target.user)@$($target.ip)" $moveCmd
    if ($LASTEXITCODE -ne 0) { throw "move/chmod failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host "[4/5] Reloading systemd..." -ForegroundColor Yellow
    & ssh @SshOpts "$($target.user)@$($target.ip)" "sudo systemctl daemon-reload"
    if ($LASTEXITCODE -ne 0) { throw "daemon-reload failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host "[5/5] Done - units installed, NOT enabled/started." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "      Manual cutover from the old startup mechanism still needed:" -ForegroundColor Yellow
    Write-Host "        1. Stop/disable whatever currently launches the old pipeline + imgserv at boot (system_init.sh)" -ForegroundColor Yellow
    Write-Host "        2. sudo systemctl enable --now imgserv $pipelineService pipeline-watchdog.service" -ForegroundColor Yellow
    Write-Host "        3. Confirm image.pgm is updating and ports are up before considering it live" -ForegroundColor Yellow
}
catch {
    Write-Host "  FAILED: $_" -ForegroundColor Red
    $status = "FAILED: $_"
}
finally {
    Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

$LogFile = "$ScriptDir\deploy_log.csv"
if (-not (Test-Path $LogFile)) {
    "Timestamp,Camera,IP,PipelineType,Status" | Out-File $LogFile -Encoding utf8
}
$ts = Get-Date -Format "yyyy-MM-dd HH:mm"
"$ts,$($target.name),$($target.ip),$pipelineType,$status" | Out-File $LogFile -Encoding utf8 -Append

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
$color = if ($status -eq "OK") { "Green" } else { "Red" }
Write-Host "  Result: $status" -ForegroundColor $color
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
