#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Runs on first boot of a cloned (sysprepped) Windows image via unattend.xml
    FirstLogonCommands.  Disables Defender (real-time, cloud, tamper protection),
    disables the Windows Firewall on all profiles, then enables WinRM and CredSSP.
    Compatible: Server 2012 -> Server 2025, Windows 10, Windows 11.
#>

$ErrorActionPreference = 'Continue'
$LogPath = 'C:\Windows\Temp\ConfigureClone.log'

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','SUCCESS','WARN','ERROR')][string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

Write-Log '================================================================'
Write-Log ' Configure-Clone.ps1 starting'
Write-Log "  Running as : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "  OS Version : $([System.Environment]::OSVersion.VersionString)"
Write-Log "  PS Version : $($PSVersionTable.PSVersion)"
Write-Log '================================================================'

# ---- 1. Disable Tamper Protection ----------------------------------------
# Must be cleared first; otherwise it blocks subsequent Defender registry changes
# on Windows 10 1903+ and Server 2019+.
try {
    Write-Log '--- BEGIN: Disable Tamper Protection ---'

    $featKey = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features'
    if (-not (Test-Path $featKey)) { New-Item -Path $featKey -Force | Out-Null }
    Set-ItemProperty -Path $featKey -Name 'TamperProtection' -Value 4 -Type DWord -Force
    Write-Log '  TamperProtection = 4 (disabled)'

    Write-Log '--- DONE: Disable Tamper Protection ---' -Level SUCCESS
} catch {
    Write-Log "  Tamper Protection key could not be set (may not exist on this SKU): $_" -Level WARN
}

# ---- 2. Disable Windows Defender ------------------------------------------
try {
    Write-Log '--- BEGIN: Disable Windows Defender ---'

    # Main policy key - disables Defender at the GP layer (survives reboots / updates)
    $defKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    if (-not (Test-Path $defKey)) { New-Item -Path $defKey -Force | Out-Null }
    Set-ItemProperty -Path $defKey -Name 'DisableAntiSpyware' -Value 1 -Type DWord -Force
    Write-Log '  DisableAntiSpyware = 1'

    # Real-time protection sub-key
    $rtpKey = "$defKey\Real-Time Protection"
    if (-not (Test-Path $rtpKey)) { New-Item -Path $rtpKey -Force | Out-Null }
    foreach ($name in @(
        'DisableRealtimeMonitoring',
        'DisableIOAVProtection',
        'DisableOnAccessProtection',
        'DisableScanOnRealtimeEnable',
        'DisableBehaviorMonitoring'
    )) {
        Set-ItemProperty -Path $rtpKey -Name $name -Value 1 -Type DWord -Force
        Write-Log "  $name = 1"
    }

    # Cloud protection / sample submission
    $spynetKey = "$defKey\Spynet"
    if (-not (Test-Path $spynetKey)) { New-Item -Path $spynetKey -Force | Out-Null }
    Set-ItemProperty -Path $spynetKey -Name 'SpynetReporting'      -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $spynetKey -Name 'SubmitSamplesConsent' -Value 2 -Type DWord -Force
    Write-Log '  SpynetReporting = 0 (no cloud reporting), SubmitSamplesConsent = 2 (never send)'

    # MpEngine PUS (potentially unwanted software) detection
    $mpEngKey = "$defKey\MpEngine"
    if (-not (Test-Path $mpEngKey)) { New-Item -Path $mpEngKey -Force | Out-Null }
    Set-ItemProperty -Path $mpEngKey -Name 'MpEnablePus' -Value 0 -Type DWord -Force
    Write-Log '  MpEnablePus = 0'

    # Try the PowerShell cmdlet as well (may not exist on Server Core or non-Defender SKUs)
    try {
        Set-MpPreference `
            -DisableRealtimeMonitoring $true `
            -DisableIOAVProtection     $true `
            -DisableBehaviorMonitoring $true `
            -DisableBlockAtFirstSeen   $true `
            -MAPSReporting             Disabled `
            -SubmitSamplesConsent      NeverSend `
            -ErrorAction Stop
        Write-Log '  Set-MpPreference succeeded'
    } catch {
        Write-Log "  Set-MpPreference not available on this SKU: $_ (registry settings are sufficient)" -Level WARN
    }

    Write-Log '--- DONE: Disable Windows Defender ---' -Level SUCCESS
} catch {
    Write-Log "--- ERROR: Defender disable failed: $_" -Level ERROR
}

# ---- 3. Disable Windows Firewall ------------------------------------------
try {
    Write-Log '--- BEGIN: Disable Windows Firewall ---'

    # netsh works on every Windows version in scope
    $netshOut = & netsh advfirewall set allprofiles state off 2>&1
    Write-Log "  netsh advfirewall: $netshOut"

    # Belt-and-suspenders: PowerShell cmdlet (Win8+ / Server 2012+)
    try {
        Set-NetFirewallProfile -All -Enabled False -ErrorAction Stop
        Write-Log '  Set-NetFirewallProfile -All -Enabled False succeeded'
    } catch {
        Write-Log "  Set-NetFirewallProfile not available on this SKU: $_" -Level WARN
    }

    Write-Log '--- DONE: Disable Windows Firewall ---' -Level SUCCESS
} catch {
    Write-Log "--- ERROR: Firewall disable failed: $_" -Level ERROR
}

# ---- 4. Enable WinRM -------------------------------------------------------
try {
    Write-Log '--- BEGIN: Enable WinRM ---'

    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
    Write-Log '  Enable-PSRemoting succeeded'

    Set-Service  -Name WinRM -StartupType Automatic -ErrorAction Stop
    Start-Service -Name WinRM                       -ErrorAction SilentlyContinue
    Write-Log '  WinRM service -> Automatic / Started'

    Write-Log '--- DONE: Enable WinRM ---' -Level SUCCESS
} catch {
    Write-Log "--- ERROR: WinRM enable failed: $_" -Level ERROR
}

# ---- 5. Enable CredSSP -----------------------------------------------------
try {
    Write-Log '--- BEGIN: Enable CredSSP ---'

    # Server role: accepts CredSSP inbound connections
    Enable-WSManCredSSP -Role Server -Force -ErrorAction Stop
    Write-Log '  WSManCredSSP Server role enabled'

    # Client role with wildcard delegation (Server SKUs may not support this role)
    try {
        Enable-WSManCredSSP -Role Client -DelegateComputer '*' -Force -ErrorAction Stop
        Write-Log '  WSManCredSSP Client role enabled (DelegateComputer: *)'
    } catch {
        Write-Log "  WSManCredSSP Client role failed (Server SKU may not support it): $_" -Level WARN
    }

    # Group Policy registry keys - belt-and-suspenders for older OS versions
    $credKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'
    if (-not (Test-Path $credKey)) { New-Item -Path $credKey -Force | Out-Null }
    Set-ItemProperty -Path $credKey -Name 'AllowFreshCredentials'             -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $credKey -Name 'AllowFreshCredentialsWhenNTLMOnly' -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $credKey -Name 'ConcatenateDefaults_AllowFresh'    -Value 1 -Type DWord -Force
    Write-Log '  CredentialsDelegation policy keys set'

    foreach ($sub in @('AllowFreshCredentials', 'AllowFreshCredentialsWhenNTLMOnly')) {
        $sk = "$credKey\$sub"
        if (-not (Test-Path $sk)) { New-Item -Path $sk -Force | Out-Null }
        Set-ItemProperty -Path $sk -Name '1' -Value 'wsman/*' -Type String -Force
        Write-Log "  $sub\1 = wsman/*"
    }

    # Direct WSMAN service registry key (covers edge cases on Server 2012)
    $wsmanSvcKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Service'
    if (Test-Path $wsmanSvcKey) {
        Set-ItemProperty -Path $wsmanSvcKey -Name 'auth_credssp' -Value 1 -Type DWord -Force
        Write-Log '  WSMAN Service auth_credssp = 1'
    }

    Write-Log '--- DONE: Enable CredSSP ---' -Level SUCCESS
} catch {
    Write-Log "--- ERROR: CredSSP enable failed: $_" -Level ERROR
}

Write-Log '================================================================'
Write-Log ' Configure-Clone.ps1 COMPLETE'
Write-Log '================================================================'
