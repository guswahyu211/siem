# ====================================================================
# SIEM IT USB CONTROL AGENT & MONITORING v2.1
# PT BPR Bank Daerah Gianyar (Perseroda)
# ====================================================================
#Requires -RunAsAdministrator

$ServerApiUrl = "http://192.168.100.42:5000/api"
$LogFile = "C:\Temp\siem_agent_log.txt"
$Hostname = $env:COMPUTERNAME
$AgentVersion = "2.1"

# Track sent login events to prevent duplicates
$script:SentLoginEventIds = @()

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $msg = "[$ts] $Message"
    Write-Host $msg -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $msg -ErrorAction SilentlyContinue
}

# Add-Type for Foreground Window Tracking
$WindowCode = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WindowTracker {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    
    public static string GetActiveWindow(out string processName) {
        IntPtr handle = GetForegroundWindow();
        StringBuilder title = new StringBuilder(256);
        GetWindowText(handle, title, 256);
        
        uint pid = 0;
        GetWindowThreadProcessId(handle, out pid);
        processName = "unknown";
        if (pid > 0) {
            try { processName = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; }
            catch { }
        }
        return title.ToString();
    }
}
'@
try { Add-Type -TypeDefinition $WindowCode -ErrorAction SilentlyContinue } catch {}

function Get-IPAddress {
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.' -and $_.PrefixOrigin -ne 'WellKnown' } |
            Select-Object -First 1).IPAddress
        if (-not $ip) { $ip = "0.0.0.0" }
        return $ip
    }
    catch { return "0.0.0.0" }
}

function Register-Agent {
    try {
        $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        if (-not $os) { $os = "Windows" }
        $ip = Get-IPAddress
        $body = @{ hostname = $Hostname; os = $os; ip = $ip; agent_version = $AgentVersion }
        Invoke-RestMethod -Uri "$ServerApiUrl/agent/register" -Method Post -Body ($body | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 5 | Out-Null
        Write-Log "Agent registered to server successfully" "Green"
        return $true
    }
    catch {
        Write-Log "Failed to register agent: $_" "Red"
        return $false
    }
}

function Send-Heartbeat {
    try {
        $ip = Get-IPAddress
        $body = @{ hostname = $Hostname; ip = $ip }
        Invoke-RestMethod -Uri "$ServerApiUrl/agent/heartbeat" -Method Post -Body ($body | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 3 | Out-Null
    }
    catch {
        Write-Log "Heartbeat failed: $_" "Yellow"
    }
}

function Send-LoginEvent {
    try {
        $startTime = (Get-Date).AddSeconds(-20)
        $events = Get-WinEvent -FilterHashtable @{LogName = 'Security'; Id = @(4624, 4634); StartTime = $startTime } -MaxEvents 10 -ErrorAction SilentlyContinue
        foreach ($e in $events) {
            # Skip if already sent (using RecordId for deduplication)
            $eventKey = "$($e.RecordId)"
            if ($script:SentLoginEventIds -contains $eventKey) { continue }

            $action = if ($e.Id -eq 4624) { "login" } else { "logout" }
            $user = $e.Properties[5].Value
            if ($user -and $user -notmatch 'SYSTEM|NETWORK|DWM|UMFD|ANONYMOUS|LOCAL SERVICE|NETWORK SERVICE|\$$') {
                $body = @{ hostname = $Hostname; username = $user; action = $action; ip = (Get-IPAddress) }
                Invoke-RestMethod -Uri "$ServerApiUrl/agent/login-event" -Method Post -Body ($body | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 3 | Out-Null
                Write-Log "Login event sent: $user ($action)" "Cyan"
            }
            
            # Track sent events (keep last 100 to prevent memory leak)
            $script:SentLoginEventIds += $eventKey
            if ($script:SentLoginEventIds.Count -gt 100) {
                $script:SentLoginEventIds = $script:SentLoginEventIds[-50..-1]
            }
        }
    }
    catch {}
}

function Send-UserActivity {
    try {
        $procName = ""
        $title = [WindowTracker]::GetActiveWindow([ref]$procName)
        $user = $env:USERNAME
        
        if ($title -and $procName -and $procName -ne "unknown") {
            $body = @{ hostname = $Hostname; username = $user; process_name = $procName; window_title = $title; duration = 15 }
            Invoke-RestMethod -Uri "$ServerApiUrl/agent/user-activity" -Method Post -Body ($body | ConvertTo-Json -Depth 3) -ContentType "application/json" -TimeoutSec 3 | Out-Null
        }
    }
    catch {}
}

function Send-UsbEvent($sn, $name, $action) {
    try {
        $body = @{ hostname = $Hostname; serial_number = $sn; device_name = $name; action = $action }
        Invoke-RestMethod -Uri "$ServerApiUrl/agent/usb-event" -Method Post -Body ($body | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 3 | Out-Null
        Write-Log "USB event sent: $sn - $action" "Magenta"
    }
    catch {
        Write-Log "Failed to send USB event: $_" "Red"
    }
}

function Get-UsbPolicy {
    try {
        $res = Invoke-RestMethod -Uri "$ServerApiUrl/allowed_usbs" -Method Get -TimeoutSec 5
        return $res
    }
    catch {
        Write-Log "Failed to fetch USB policy from server" "Yellow"
        return $null
    }
}

function Sync-USB {
    $policy = Get-UsbPolicy
    if (-not $policy) { return }
    
    $allowed = @()
    $blocked = @()
    if ($policy.allowed_serials) { $allowed = @($policy.allowed_serials) }
    if ($policy.blocked_serials) { $blocked = @($policy.blocked_serials) }
    $default = "$($policy.default_policy)".ToLower()
    
    # Get all USB storage drives via WMI
    $wmiDrives = @(Get-WmiObject Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceType -eq 'USB' })
    
    foreach ($wmiDrive in $wmiDrives) {
        try {
            $rawSerial = $wmiDrive.SerialNumber
            if (-not $rawSerial) { continue }
            $cleanSerial = ($rawSerial -replace '[^a-zA-Z0-9]', '').ToUpper()
            if (-not $cleanSerial) { continue }
            
            $model = $wmiDrive.Model
            if (-not $model) { $model = "Unknown USB Storage" }
            
            $disk = Get-Disk -Number $wmiDrive.Index -ErrorAction SilentlyContinue
            if (-not $disk) { continue }
            
            # Determine if USB should be allowed
            $shouldAllow = $false
            $reason = ""
            
            $matchAllow = $allowed | Where-Object { $_ -eq $cleanSerial }
            $matchBlock = $blocked | Where-Object { $_ -eq $cleanSerial }
            
            if ($matchAllow) {
                $shouldAllow = $true
                $reason = "whitelisted"
            } elseif ($matchBlock) {
                $shouldAllow = $false
                $reason = "blacklisted"
            } else {
                $shouldAllow = ($default -eq 'allow')
                $reason = "default_policy ($default)"
            }
            
            # Apply policy: ALLOW
            if ($shouldAllow) {
                $wasRestored = $false
                
                # 1. Bring Disk Online (For External HDDs)
                if ($disk.IsOffline) {
                    Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction SilentlyContinue
                    Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction SilentlyContinue
                    $wasRestored = $true
                }
                
                # 2. Restore Drive Letters (For Flashdisks)
                $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
                foreach ($part in $partitions) {
                    # Jika partisi tidak punya drive letter, ukurannya cukup besar, dan bukan partisi sistem tersembunyi
                    if (-not $part.DriveLetter -and $part.Size -gt 10MB) {
                        try {
                            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AssignDriveLetter -ErrorAction Stop
                            $wasRestored = $true
                        } catch {}
                    }
                }
                
                if ($wasRestored) {
                    Write-Log "USB $cleanSerial ($model) ALLOWED by $reason - Mount restored!" "Green"
                    Send-UsbEvent $cleanSerial $model "connected"
                }
            }
            # Apply policy: BLOCK
            else {
                $wasBlocked = $false
                
                # 1. Remove Drive Letters (For Flashdisks - seperti 'umount' di Linux)
                $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
                foreach ($part in $partitions) {
                    if ($part.DriveLetter) {
                        $letter = "$($part.DriveLetter):\"
                        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AccessPath $letter -ErrorAction SilentlyContinue
                        $wasBlocked = $true
                    }
                }
                
                # 2. Set Disk Offline (For External HDDs)
                if (-not $disk.IsOffline) {
                    try {
                        Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction Stop
                        $wasBlocked = $true
                    } catch {}
                }
                
                if ($wasBlocked) {
                    Write-Log "USB $cleanSerial ($model) BLOCKED by $reason - Mount removed!" "Red"
                    Send-UsbEvent $cleanSerial $model "blocked"
                }
            }
        } catch {
            Write-Log "Error processing USB device: $_" "Red"
        }
    }
}

# ====================================================================
# MAIN LOOP
# ====================================================================
Clear-Host
Write-Log "========================================" "Cyan"
Write-Log " SIEM USB & Monitoring Agent v$AgentVersion" "Cyan"
Write-Log " PT BPR Bank Daerah Gianyar (Perseroda)" "Cyan"
Write-Log " Server: $ServerApiUrl" "Cyan"
Write-Log "========================================" "Cyan"

# Retry registration up to 5 times
$registered = $false
for ($i = 1; $i -le 5; $i++) {
    $registered = Register-Agent
    if ($registered) { break }
    Write-Log "Retry registration ($i/5) in 5 seconds..." "Yellow"
    Start-Sleep -Seconds 5
}

if (-not $registered) {
    Write-Log "WARNING: Could not register with server. Agent will keep trying in the main loop." "Red"
}

$counter = 0
while ($true) {
    try {
        # Always send heartbeat every loop (15 seconds)
        Send-Heartbeat
        
        # Sync USB policies and enforce block/allow
        Sync-USB
        
        # Monitor login events from Windows Security Log
        Send-LoginEvent
        
        # Track foreground window activity
        Send-UserActivity
        
        # Re-register every 20 loops (~5 minutes) to refresh info
        if ($counter % 20 -eq 0 -and $counter -gt 0) {
            Register-Agent | Out-Null
        }
    }
    catch {
        Write-Log "Main loop error: $_" "Red"
    }
    
    $counter++
    Start-Sleep -Seconds 15
}
