# ================================================================
# deploy_pipeline_recovery.ps1 - Deploy the pipeline recovery set to a
# camera: pipeline_watchdog.sh, pipeline-watchdog.service, the three
# logrotate configs, restart_imgserv.sh, and pipeline_restart.sh (the
# latter two pulled from their real homes at deploy\ImgservRestart\ and
# deploy\PipelineRestart\ - the watchdog depends on BOTH being present,
# and NEITHER can be assumed to already be on a given camera - confirmed
# 2026-10-20 that pipeline_restart.sh is only on cameras where someone
# manually put it before, not a standard part of every camera's image).
#
# No Seek-vs-Boson detection needed - pipeline_watchdog.sh calls
# pipeline_restart.sh when it detects a problem, and that script already
# knows how to restart whichever pipeline is actually installed. Same
# files work on either camera type unchanged.
#
# SAFETY: purely additive. Does NOT touch system_init.sh or the existing
# pipeline/imgserv wrapper scripts at all. Installs pipeline-watchdog.service
# but does not enable/start it - that's a deliberate manual step.
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
$ScriptDir      = $PSScriptRoot
$CamerasJson    = "$PSScriptRoot\..\SiteCameraChecks\cameras.json"
$ImgservRestart  = "$PSScriptRoot\..\deploy\ImgservRestart\restart_imgserv.sh"
$PipelineRestart = "$PSScriptRoot\..\deploy\PipelineRestart\pipeline_restart.sh"

if ($Camera -eq "" -and $IP -eq "") {
    Write-Host "ERROR: must supply -Camera <name> or -IP <address>" -ForegroundColor Red; exit 1
}
if (-not (Test-Path $ImgservRestart)) {
    Write-Host "ERROR: restart_imgserv.sh not found at $ImgservRestart" -ForegroundColor Red; exit 1
}
if (-not (Test-Path $PipelineRestart)) {
    Write-Host "ERROR: pipeline_restart.sh not found at $PipelineRestart" -ForegroundColor Red; exit 1
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

if ($Preview) {
    Write-Host "Preview only - would:" -ForegroundColor Yellow
    Write-Host "  1. Check whether /usr/local/bin/camera/pipeline_restart.sh already exists on the camera" -ForegroundColor Yellow
    Write-Host "  2. Copy pipeline_watchdog.sh, pipeline-watchdog.service, restart_imgserv.sh, pipeline_restart.sh (only if missing - never overwrite an existing camera-specific copy), and 3 logrotate configs to $($target.ip):~/" -ForegroundColor Yellow
    Write-Host "  3. sudo mv pipeline-watchdog.service into /etc/systemd/system/" -ForegroundColor Yellow
    Write-Host "  4. sudo mv pipeline_watchdog.sh, restart_imgserv.sh into /usr/local/bin/camera/ (chmod +x); pipeline_restart.sh too, only if it wasn't already there" -ForegroundColor Yellow
    Write-Host "  5. sudo mv the 3 logrotate configs into /etc/logrotate.d/" -ForegroundColor Yellow
    Write-Host "  6. sudo systemctl daemon-reload" -ForegroundColor Yellow
    Write-Host "  (pipeline-watchdog.service is installed but NOT enabled/started; system_init.sh and the existing wrappers are NOT touched)" -ForegroundColor Yellow
    exit
}

$SshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL")

$status = "OK"
try {
    Write-Host "[1/5] Checking whether pipeline_restart.sh already exists on the camera..." -ForegroundColor Yellow
    $existsCmd = "test -f /usr/local/bin/camera/pipeline_restart.sh && echo YES || echo NO"
    $pipelineRestartExists = (& ssh @SshOpts "$($target.user)@$($target.ip)" $existsCmd).Trim()
    if ($pipelineRestartExists -eq "YES") {
        Write-Host "      Already present - will NOT overwrite (may be camera-specific)." -ForegroundColor Green
    } else {
        Write-Host "      Not found - will deploy our copy." -ForegroundColor Yellow
    }

    Write-Host "[2/5] Copying files to home directory..." -ForegroundColor Yellow
    $filesToCopy = @(
        "$ScriptDir\pipeline_watchdog.sh",
        "$ScriptDir\pipeline-watchdog.service",
        "$ImgservRestart",
        "$ScriptDir\pipeline_watchdog.logrotate",
        "$ScriptDir\rtsp-seek-server.logrotate",
        "$ScriptDir\rtsp-ir-server.logrotate"
    )
    if ($pipelineRestartExists -ne "YES") { $filesToCopy += $PipelineRestart }
    & scp @SshOpts @filesToCopy "$($target.user)@$($target.ip):~/"
    if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host "[3/5] Moving service unit into place..." -ForegroundColor Yellow
    & ssh @SshOpts "$($target.user)@$($target.ip)" "sudo mv ~/pipeline-watchdog.service /etc/systemd/system/"
    if ($LASTEXITCODE -ne 0) { throw "move failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host "[4/5] Moving scripts + logrotate configs into place..." -ForegroundColor Yellow
    $moveCmd = "sudo mv ~/pipeline_watchdog.sh ~/restart_imgserv.sh /usr/local/bin/camera/ && " +
               "sudo chmod +x /usr/local/bin/camera/pipeline_watchdog.sh /usr/local/bin/camera/restart_imgserv.sh && "
    if ($pipelineRestartExists -ne "YES") {
        $moveCmd += "sudo mv ~/pipeline_restart.sh /usr/local/bin/camera/ && sudo chmod +x /usr/local/bin/camera/pipeline_restart.sh && "
    }
    $moveCmd += "sudo mv ~/pipeline_watchdog.logrotate /etc/logrotate.d/pipeline_watchdog && " +
               "sudo mv ~/rtsp-seek-server.logrotate /etc/logrotate.d/rtsp-seek-server && " +
               "sudo mv ~/rtsp-ir-server.logrotate /etc/logrotate.d/rtsp-ir-server"
    & ssh @SshOpts "$($target.user)@$($target.ip)" $moveCmd
    if ($LASTEXITCODE -ne 0) { throw "move/chmod failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host "[5/5] Reloading systemd..." -ForegroundColor Yellow
    & ssh @SshOpts "$($target.user)@$($target.ip)" "sudo systemctl daemon-reload"
    if ($LASTEXITCODE -ne 0) { throw "daemon-reload failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host ""
    Write-Host "      Done - files installed, service NOT enabled/started. Nothing existing was touched." -ForegroundColor Yellow
    Write-Host "      To actually turn it on:" -ForegroundColor Yellow
    Write-Host "        sudo systemctl enable --now pipeline-watchdog.service" -ForegroundColor Yellow
}
catch {
    Write-Host "  FAILED: $_" -ForegroundColor Red
    $status = "FAILED: $_"
}

$LogFile = "$ScriptDir\deploy_log.csv"
if (-not (Test-Path $LogFile)) {
    "Timestamp,Camera,IP,Status" | Out-File $LogFile -Encoding utf8
}
$ts = Get-Date -Format "yyyy-MM-dd HH:mm"
"$ts,$($target.name),$($target.ip),$status" | Out-File $LogFile -Encoding utf8 -Append

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
$color = if ($status -eq "OK") { "Green" } else { "Red" }
Write-Host "  Result: $status" -ForegroundColor $color
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
