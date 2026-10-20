# ================================================================
# deploy_pipeline_recovery.ps1 - Deploy the pipeline recovery set
# (imgserv.service, pipeline-watchdog.service, pipeline_watchdog.sh) to
# a camera.
#
# No Seek-vs-Boson detection needed anymore - pipeline_watchdog.sh calls
# the camera's own existing pipeline_restart.sh when it detects a
# problem, and that script already knows how to restart whichever
# pipeline is actually installed. Same 3 files work on either camera
# type unchanged.
#
# SAFETY: this installs imgserv.service and pipeline-watchdog.service but
# does NOT enable/start them, and does NOT touch system_init.sh or the
# existing pipeline wrapper scripts at all - this is purely additive.
# Enabling the units (and, separately, deciding whether to cut imgserv
# over from its old startup line) is a deliberate manual step.
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

if ($Preview) {
    Write-Host "Preview only - would:" -ForegroundColor Yellow
    Write-Host "  1. Copy imgserv.service, pipeline-watchdog.service, pipeline_watchdog.sh to $($target.ip):~/" -ForegroundColor Yellow
    Write-Host "  2. sudo mv the two .service files into /etc/systemd/system/, pipeline_watchdog.sh into /usr/local/bin/camera/ (chmod +x)" -ForegroundColor Yellow
    Write-Host "  3. sudo systemctl daemon-reload" -ForegroundColor Yellow
    Write-Host "  (units are installed but NOT enabled/started; system_init.sh and the existing pipeline wrapper are NOT touched at all)" -ForegroundColor Yellow
    exit
}

$SshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL")

$status = "OK"
try {
    Write-Host "[1/3] Copying files to home directory..." -ForegroundColor Yellow
    & scp @SshOpts "$ScriptDir\imgserv.service" "$ScriptDir\pipeline-watchdog.service" "$ScriptDir\pipeline_watchdog.sh" "$($target.user)@$($target.ip):~/"
    if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host "[2/3] Moving units + script into place..." -ForegroundColor Yellow
    $moveCmd = "sudo mv ~/imgserv.service ~/pipeline-watchdog.service /etc/systemd/system/ && " +
               "sudo mv ~/pipeline_watchdog.sh /usr/local/bin/camera/pipeline_watchdog.sh && " +
               "sudo chmod +x /usr/local/bin/camera/pipeline_watchdog.sh"
    & ssh @SshOpts "$($target.user)@$($target.ip)" $moveCmd
    if ($LASTEXITCODE -ne 0) { throw "move/chmod failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host "[3/3] Reloading systemd..." -ForegroundColor Yellow
    & ssh @SshOpts "$($target.user)@$($target.ip)" "sudo systemctl daemon-reload"
    if ($LASTEXITCODE -ne 0) { throw "daemon-reload failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host ""
    Write-Host "      Done - units installed, NOT enabled/started. Nothing existing was touched." -ForegroundColor Yellow
    Write-Host "      To actually turn these on:" -ForegroundColor Yellow
    Write-Host "        sudo systemctl enable --now pipeline-watchdog.service" -ForegroundColor Yellow
    Write-Host "        (imgserv.service cutover is separate - see deploy_imgserv_service.ps1's own notes)" -ForegroundColor Yellow
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
