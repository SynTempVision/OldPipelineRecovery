# ================================================================
# deploy_imgserv_service.ps1 - Deploy ONLY imgserv.service to a camera,
# standalone - separate from deploy_pipeline_recovery.ps1 since imgserv
# is camera-agnostic (same on Seek and Boson units) and someone may want
# to roll this out independently of the full pipeline/watchdog bundle.
#
# SAFETY: installs the unit but does NOT enable/start it and does NOT
# touch the camera's existing `imgserv -p 2105 &` startup line. That
# cutover - stopping the old imgserv process, disabling its startup line,
# then `systemctl enable --now imgserv` - is a separate, manual step.
#
# Usage:
#   .\deploy_imgserv_service.ps1 -Camera sv-154
#   .\deploy_imgserv_service.ps1 -IP 172.17.103.200
#   .\deploy_imgserv_service.ps1 -Camera sv-154 -Preview
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
Write-Host "  imgserv.service Deploy"                 -ForegroundColor Cyan
Write-Host "  Target   : $($target.name)  ($($target.ip))" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($Preview) {
    Write-Host "Preview only - would:" -ForegroundColor Yellow
    Write-Host "  1. Copy imgserv.service to $($target.ip):~/" -ForegroundColor Yellow
    Write-Host "  2. sudo mv it into /etc/systemd/system/imgserv.service" -ForegroundColor Yellow
    Write-Host "  3. sudo systemctl daemon-reload" -ForegroundColor Yellow
    Write-Host "  (unit is installed but NOT enabled/started - cutover from the old startup line is a separate manual step)" -ForegroundColor Yellow
    exit
}

$SshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL")

$status = "OK"
try {
    Write-Host "[1/3] Copying imgserv.service to home directory..." -ForegroundColor Yellow
    & scp @SshOpts "$ScriptDir\imgserv.service" "$($target.user)@$($target.ip):~/"
    if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host "[2/3] Moving into place..." -ForegroundColor Yellow
    & ssh @SshOpts "$($target.user)@$($target.ip)" "sudo mv ~/imgserv.service /etc/systemd/system/imgserv.service"
    if ($LASTEXITCODE -ne 0) { throw "move failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host "[3/3] Reloading systemd..." -ForegroundColor Yellow
    & ssh @SshOpts "$($target.user)@$($target.ip)" "sudo systemctl daemon-reload"
    if ($LASTEXITCODE -ne 0) { throw "daemon-reload failed (exit $LASTEXITCODE)" }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host ""
    Write-Host "      Done - unit installed, NOT enabled/started." -ForegroundColor Yellow
    Write-Host "      Manual cutover still needed:" -ForegroundColor Yellow
    Write-Host "        1. Stop the running imgserv process and remove/comment its startup line (system_init.sh)" -ForegroundColor Yellow
    Write-Host "        2. sudo systemctl enable --now imgserv" -ForegroundColor Yellow
    Write-Host "        3. sudo systemctl status imgserv - confirm it's active" -ForegroundColor Yellow
}
catch {
    Write-Host "  FAILED: $_" -ForegroundColor Red
    $status = "FAILED: $_"
}

$LogFile = "$ScriptDir\deploy_log.csv"
if (-not (Test-Path $LogFile)) {
    "Timestamp,Camera,IP,PipelineType,Status" | Out-File $LogFile -Encoding utf8
}
$ts = Get-Date -Format "yyyy-MM-dd HH:mm"
"$ts,$($target.name),$($target.ip),imgserv-only,$status" | Out-File $LogFile -Encoding utf8 -Append

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
$color = if ($status -eq "OK") { "Green" } else { "Red" }
Write-Host "  Result: $status" -ForegroundColor $color
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
