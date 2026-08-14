# ============================================================
# USB RECOVERY SCRIPT - WINDOWS 10
# ============================================================
#Requires -RunAsAdministrator

Clear-Host
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "    USB RECOVERY TOOL - WINDOWS 10" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Function to wait with countdown
function Wait-Countdown {
    param($Seconds)
    for ($i = $Seconds; $i -gt 0; $i--) {
        Write-Host "`rWaiting $i seconds..." -ForegroundColor Yellow -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host "`rDone!                    " -ForegroundColor Green
}

# STEP 1: Enable all DiskDrives
Write-Host "`n[1] ENABLING ALL DISK DRIVES..." -ForegroundColor Yellow
$devices = Get-PnpDevice -Class "DiskDrive" -ErrorAction SilentlyContinue
foreach ($dev in $devices) {
    Write-Host "  Device: $($dev.FriendlyName)" -ForegroundColor Gray
    Write-Host "  Status: $($dev.Status)" -ForegroundColor Gray
    
    if ($dev.Status -ne 'OK') {
        Write-Host "  -> Enabling..." -ForegroundColor Green
        Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
}
Wait-Countdown 2

# STEP 2: Bring all USB disks online
Write-Host "`n[2] BRINGING USB DISKS ONLINE..." -ForegroundColor Yellow
$disks = Get-Disk -ErrorAction SilentlyContinue | Where-Object { 
    $_.BusType -eq 'USB' -or $_.Location -like "*USB*"
}

if ($disks) {
    foreach ($disk in $disks) {
        Write-Host "  Disk #$($disk.Number): $($disk.FriendlyName)" -ForegroundColor Gray
        Write-Host "  IsOffline: $($disk.IsOffline)" -ForegroundColor Gray
        
        if ($disk.IsOffline) {
            Write-Host "  -> Bringing online..." -ForegroundColor Green
            Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction SilentlyContinue
            Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }
}
else {
    Write-Host "  No USB disks found. Trying to rescan..." -ForegroundColor Yellow
}
Wait-Countdown 2

# STEP 3: Rescan hardware
Write-Host "`n[3] RESCANNING HARDWARE..." -ForegroundColor Yellow

# Method 1: Using pnputil
Write-Host "  Method 1: pnputil" -ForegroundColor Gray
pnputil /scan-devices | Out-Null
Start-Sleep -Seconds 3

# Method 2: Using devcon (if available)
Write-Host "  Method 2: devcon" -ForegroundColor Gray
$devconPath = "$env:windir\System32\devcon.exe"
if (Test-Path $devconPath) {
    & $devconPath rescan | Out-Null
}
else {
    Write-Host "  devcon not found, skipping..." -ForegroundColor Gray
}
Wait-Countdown 3

# STEP 4: Enable USB Mass Storage devices
Write-Host "`n[4] ENABLING USB MASS STORAGE DEVICES..." -ForegroundColor Yellow
$usbDevices = Get-PnpDevice -Class "USB" -ErrorAction SilentlyContinue | 
Where-Object { $_.FriendlyName -like "*Mass Storage*" -or $_.FriendlyName -like "*USB Storage*" }

if ($usbDevices) {
    foreach ($dev in $usbDevices) {
        Write-Host "  Device: $($dev.FriendlyName)" -ForegroundColor Gray
        if ($dev.Status -ne 'OK') {
            Write-Host "  -> Enabling..." -ForegroundColor Green
            Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}
else {
    Write-Host "  No USB Mass Storage devices found" -ForegroundColor Gray
}
Wait-Countdown 2

# STEP 5: Reset USB controllers
Write-Host "`n[5] RESETTING USB CONTROLLERS..." -ForegroundColor Yellow
$usbControllers = Get-PnpDevice -Class "USB" | Where-Object { 
    $_.FriendlyName -like "*Host Controller*" -or $_.FriendlyName -like "*Root Hub*"
}

foreach ($ctrl in $usbControllers) {
    Write-Host "  Controller: $($ctrl.FriendlyName)" -ForegroundColor Gray
    Write-Host "  Status: $($ctrl.Status)" -ForegroundColor Gray
    if ($ctrl.Status -eq 'OK') {
        Write-Host "  -> Disabling..." -ForegroundColor Red
        Disable-PnpDevice -InstanceId $ctrl.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 1000
        Write-Host "  -> Enabling..." -ForegroundColor Green
        Enable-PnpDevice -InstanceId $ctrl.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
}
Wait-Countdown 3

# STEP 6: Refresh drive letters
Write-Host "`n[6] REFRESHING DRIVE LETTERS..." -ForegroundColor Yellow
$volumes = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Removable' }
foreach ($vol in $volumes) {
    Write-Host "  Volume: $($vol.DriveLetter)" -ForegroundColor Gray
    if ($vol.DriveLetter) {
        $drivePath = "$($vol.DriveLetter):\"
        if (Test-Path $drivePath) {
            Write-Host "  -> Accessible: $drivePath" -ForegroundColor Green
        }
    }
}
Wait-Countdown 2

# STEP 7: Final check
Write-Host "`n[7] FINAL CHECK - ACTIVE USB DEVICES..." -ForegroundColor Yellow
$activeDevices = Get-PnpDevice -Class "DiskDrive" -ErrorAction SilentlyContinue | 
Where-Object { $_.Status -eq 'OK' }

if ($activeDevices) {
    Write-Host "`n  FOUND ACTIVE USB DEVICES:" -ForegroundColor Green
    foreach ($dev in $activeDevices) {
        Write-Host "    ✓ $($dev.FriendlyName)" -ForegroundColor Green
    }
}
else {
    Write-Host "`n  NO ACTIVE USB DEVICES FOUND!" -ForegroundColor Red
    Write-Host "  Silakan cabut dan colokkan kembali USB flashdisk Anda." -ForegroundColor Yellow
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "    RECOVERY PROCESS COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nJika USB masih tidak terdeteksi:" -ForegroundColor Yellow
Write-Host "1. Cabut USB dan colokkan ke port lain" -ForegroundColor Yellow
Write-Host "2. Restart komputer" -ForegroundColor Yellow
Write-Host "3. Coba di komputer lain untuk memastikan USB tidak rusak" -ForegroundColor Yellow
Write-Host ""
Read-Host "Press Enter to exit"