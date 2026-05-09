#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Validates the sysprep answer file then generalises the base image with Sysprep.
    Injected into the VHDX at C:\BaseImageSetup\ by New-BaseVHDX.ps1.
    All post-clone configuration (Defender, Firewall, WinRM, CredSSP) is handled by
    Configure-Clone.ps1, which runs on the clone's first boot via the sysprep unattend.
#>

$ErrorActionPreference = 'Stop'
$LogPath = 'C:\Windows\Temp\BaseImageSetup.log'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','SUCCESS','WARN','ERROR')][string]$Level = 'INFO'
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Log "--- BEGIN: $Name ---"
    try {
        & $Action
        Write-Log "--- DONE: $Name ---" -Level SUCCESS
    } catch {
        Write-Log "--- FAILED: $Name ---" -Level ERROR
        Write-Log "  Exception : $($_.Exception.Message)" -Level ERROR
        Write-Log "  StackTrace: $($_.ScriptStackTrace)" -Level ERROR
        throw
    }
}

try {
    Write-Log '================================================================'
    Write-Log ' Configure-BaseImage.ps1 starting'
    Write-Log "  Running as : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "  OS Version : $([System.Environment]::OSVersion.VersionString)"
    Write-Log "  PS Version : $($PSVersionTable.PSVersion)"
    Write-Log "  Script dir : $PSScriptRoot"
    Write-Log '================================================================'

    # Wait for services to stabilize after first boot
    Invoke-Step 'Wait for system services to stabilize' {
        Write-Log "  Pausing 45 seconds for system services to initialize..."
        Start-Sleep -Seconds 45
        Write-Log "  Wait complete."
    }

    # Validate the sysprep answer file and the clone configuration script are in place
    Invoke-Step 'Validate sysprep answer file and clone script' {
        $unattendPath = 'C:\Windows\System32\Sysprep\unattend.xml'
        if (-not (Test-Path $unattendPath)) {
            throw "Sysprep answer file not found at '$unattendPath'. The build host should have injected this file."
        }

        # Confirm it is well-formed XML - catches truncation or encoding issues
        try {
            [xml](Get-Content $unattendPath -Raw -ErrorAction Stop) | Out-Null
            Write-Log "  Sysprep answer file is valid XML: $unattendPath" -Level SUCCESS
        } catch {
            throw "Sysprep answer file at '$unattendPath' failed XML parse: $_"
        }

        # Confirm the clone script referenced by FirstLogonCommands is present
        $cloneScript = 'C:\BaseImageSetup\Configure-Clone.ps1'
        if (-not (Test-Path $cloneScript)) {
            throw "Configure-Clone.ps1 not found at '$cloneScript'. This is referenced by the sysprep unattend's FirstLogonCommands."
        }
        Write-Log "  Configure-Clone.ps1 present: $cloneScript" -Level SUCCESS
    }

    # Remove base-image-only files before sysprep so clones do not re-run this pipeline.
    # Configure-Clone.ps1 is intentionally left in place - the sysprep unattend needs it.
    Invoke-Step 'Pre-Sysprep cleanup (prevent clone re-run)' {
        foreach ($file in @('Configure-BaseImage.ps1', 'config.json')) {
            $target = Join-Path $PSScriptRoot $file
            if (Test-Path $target) {
                Remove-Item -Path $target -Force -ErrorAction SilentlyContinue
                Write-Log "  Removed: $target"
            }
        }
        $setupCompleteCmd = 'C:\Windows\Setup\Scripts\SetupComplete.cmd'
        if (Test-Path $setupCompleteCmd) {
            Remove-Item -Path $setupCompleteCmd -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed: $setupCompleteCmd"
        }
    }

    # Remove the {fwbootmgr} BCD object before sysprep.
    # Sysprep tries to export this entry to EFI NVRAM; in Hyper-V Gen2 VMs the
    # virtual UEFI firmware rejects those writes with STATUS_INVALID_PARAMETER
    # (c000000d), causing sysprep to reboot instead of shut down on Windows 11.
    # Deleting the object removes the target for the export - the VM still boots
    # correctly because Hyper-V manages its own virtual UEFI boot order.
    Invoke-Step 'BCD cleanup for Hyper-V Gen2 compatibility' {
        $bcdedit = "$env:SystemRoot\System32\bcdedit.exe"
        $result  = & $bcdedit /delete '{fwbootmgr}' /f 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  Deleted {fwbootmgr} from BCD store" -Level SUCCESS
        } else {
            Write-Log "  {fwbootmgr} not present in BCD store (normal on clean installs, continuing)"
        }
    }

    # Generalize with Sysprep - VM will shut down after this step
    Invoke-Step 'Sysprep - Generalize and Shutdown' {
        $sysprepExe = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
        if (-not (Test-Path $sysprepExe)) {
            throw "sysprep.exe not found at '$sysprepExe'."
        }

        Write-Log "  Launching: $sysprepExe /generalize /shutdown /oobe /quiet /mode:vm"
        Write-Log "  /mode:vm suppresses EFI NVRAM writes that fail inside Hyper-V Gen2 VMs."
        Write-Log "  The VM will shut down when Sysprep completes - this is expected."

        $proc = Start-Process -FilePath $sysprepExe `
                              -ArgumentList '/generalize', '/shutdown', '/oobe', '/quiet', '/mode:vm' `
                              -Wait -PassThru -NoNewWindow

        $sysprepErrLog = "$env:SystemRoot\System32\Sysprep\Panther\setuperr.log"
        if (Test-Path $sysprepErrLog) {
            $errContent = Get-Content $sysprepErrLog -Raw
            if ($errContent.Trim()) {
                Write-Log "  Sysprep error log content:`n$errContent" -Level WARN
            }
        }

        if ($proc.ExitCode -ne 0) {
            $sysprepActLog = "$env:SystemRoot\System32\Sysprep\Panther\setupact.log"
            $actContent = if (Test-Path $sysprepActLog) { Get-Content $sysprepActLog -Tail 40 -Raw } else { '(log not found)' }
            throw "Sysprep exited with code $($proc.ExitCode). Last 40 lines of setupact.log:`n$actContent"
        }

        Write-Log "  Sysprep completed. System will shut down momentarily." -Level SUCCESS
    }

} catch {
    Write-Log '================================================================' -Level ERROR
    Write-Log ' Configure-BaseImage.ps1 FAILED' -Level ERROR
    Write-Log "  Error   : $($_.Exception.Message)" -Level ERROR
    Write-Log "  Location: $($_.InvocationInfo.PositionMessage)" -Level ERROR
    Write-Log '================================================================' -Level ERROR
    exit 1
}
