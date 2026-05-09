<#
.SYNOPSIS
    Builds a generalised base VHDX from a Windows or Ubuntu ISO with zero user
    interaction during the build. Requires Hyper-V and must run as Administrator.

.DESCRIPTION
    Windows ISO path (offline, fast ~5-15 min):
        Applies the WIM directly to a new VHDX using DISM, injects setup scripts,
        boots a temporary Hyper-V VM to run configuration (Defender/Firewall/RDP/WinRM)
        and Sysprep, then removes the VM. Output is a generalised VHDX ready to clone.

    Ubuntu ISO path (online, slower ~20-40 min):
        Creates a cloud-init CIDATA seed ISO, boots a temporary Hyper-V VM from the
        Ubuntu ISO, runs a fully unattended autoinstall, then removes the VM. Output
        is a generalised VHDX (cloud-init clean, machine-id cleared) ready to clone.

.PARAMETER ISOPath
    Full path to the source Windows or Ubuntu ISO file.

.PARAMETER OutputVHDXPath
    Full path for the output VHDX. Parent directory must already exist.

.PARAMETER SizeGB
    Size of the VHDX in GB. Default 60.

.PARAMETER AdminUsername
    Local administrator username to create in the image. Default 'localadmin'.

.PARAMETER AdminPassword
    Password for the administrator account as a plain string. Will be prompted securely if not provided.

.PARAMETER Hostname
    Temporary hostname set during build (Windows: sysprepped away; Ubuntu: cleared).
    Default 'base-image'.

.PARAMETER WindowsEditionIndex
    Index of the Windows edition to install. If omitted, a menu is shown.

.PARAMETER TempVMName
    Name of the temporary Hyper-V VM created during the build. Default 'VHDX-Builder-Temp'.
    Removed automatically after the build.

.PARAMETER CPUCount
    Number of vCPUs for the temporary build VM. Default 4.

.PARAMETER MemoryGB
    RAM in GB for the temporary build VM. Default 4.

.PARAMETER VirtualSwitchName
    Virtual switch for the Ubuntu build VM (may need internet for package downloads).
    Default 'Default Switch'. Windows build VM runs with no network switch.

.EXAMPLE
    .\New-BaseVHDX.ps1 -ISOPath 'D:\ISOs\Win2022.iso' -OutputVHDXPath 'E:\VHDX\Win2022-Base.vhdx'

.EXAMPLE
    .\New-BaseVHDX.ps1 `
        -ISOPath         'D:\ISOs\ubuntu-24.04-live-server-amd64.iso' `
        -OutputVHDXPath  'E:\VHDX\Ubuntu2404-Base.vhdx' `
        -AdminUsername   'sysadmin' `
        -SizeGB          80

.NOTES
    Run as Administrator. Hyper-V must be installed and running.
    Temporary files are created under $env:TEMP and cleaned up automatically.
    Errors are descriptive:if a step fails the full error with context is shown.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ISOPath,

    [Parameter(Mandatory)]
    [string]$OutputVHDXPath,

    [int]$SizeGB = 60,

    [string]$AdminUsername = 'localadmin',

    [string]$AdminPassword,

    [string]$Hostname = 'base-image',

    [int]$WindowsEditionIndex = 0,   # 0 = prompt interactively

    [string]$TempVMName = 'VHDX-Builder-Temp',

    [int]$CPUCount = 4,

    [int]$MemoryGB = 4,

    [string]$VirtualSwitchName = 'Default Switch',

    [ValidateScript({ [string]::IsNullOrEmpty($_) -or (Test-Path $_ -PathType Leaf) })]
    [string]$SSHPublicKeyPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Bootstrap:load private functions

$scriptRoot = $PSScriptRoot
$privateDir  = Join-Path $scriptRoot 'Private'

foreach ($file in @('HelperFunctions.ps1','WindowsBuild.ps1','UbuntuBuild.ps1')) {
    $path = Join-Path $privateDir $file
    if (-not (Test-Path $path)) {
        Write-Error "Required module file not found: $path`nEnsure the 'Private' subfolder is present alongside New-BaseVHDX.ps1."
        exit 1
    }
    . $path
}

#endregion

#region Validate inputs

Write-BuildLog '================================================================' -Level STEP
Write-BuildLog ' New-BaseVHDX.ps1 : Base Image Builder' -Level STEP
Write-BuildLog "  Script version : 1.0" -Level STEP
Write-BuildLog "  Started        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level STEP
Write-BuildLog '================================================================' -Level STEP

# Resolve ISOPath to absolute
$ISOPath = (Resolve-Path $ISOPath).Path
Write-BuildLog "ISO path (resolved): $ISOPath" -Level INFO

# Validate output path - parent directory must exist
# If only a filename was given (no directory component), treat current directory as parent
$outputParent = Split-Path $OutputVHDXPath -Parent
if ([string]::IsNullOrEmpty($outputParent)) {
    $outputParent = (Get-Location).Path
}
if (-not (Test-Path $outputParent)) {
    Write-Error "Output directory does not exist: '$outputParent' - create it before running this script."
    exit 1
}
if (Test-Path $OutputVHDXPath) {
    Write-Error "Output file already exists: '$OutputVHDXPath'`nRemove it first to avoid accidental overwrites."
    exit 1
}
$OutputVHDXPath = Join-Path (Resolve-Path $outputParent).Path (Split-Path $OutputVHDXPath -Leaf)
Write-BuildLog "Output VHDX (resolved): $OutputVHDXPath" -Level INFO

# Size
if ($SizeGB -lt 30) {
    Write-Error "SizeGB must be at least 30 GB. Provided: $SizeGB"
    exit 1
}
$sizeBytes = [long]$SizeGB * 1GB

# Convert plain-text password to SecureString, or prompt if not supplied
if ([string]::IsNullOrEmpty($AdminPassword)) {
    Write-BuildLog 'AdminPassword not supplied - prompting securely.' -Level INFO
    $secureAdminPassword = Read-Host -AsSecureString "Enter admin password for the base image"
    if ($secureAdminPassword.Length -eq 0) {
        Write-Error "Password cannot be empty."
        exit 1
    }
} else {
    $secureAdminPassword = ConvertTo-SecureString -String $AdminPassword -AsPlainText -Force
}

# Memory
$memoryBytes = [long]$MemoryGB * 1GB

# Read SSH public key from file if provided
$sshPublicKey = ''
if (-not [string]::IsNullOrEmpty($SSHPublicKeyPath)) {
    $sshPublicKey = (Get-Content -Path $SSHPublicKeyPath -Raw -ErrorAction Stop).Trim()
    if ([string]::IsNullOrWhiteSpace($sshPublicKey)) {
        Write-Error "SSH public key file '$SSHPublicKeyPath' is empty."
        exit 1
    }
}

Write-BuildLog "Build options:" -Level INFO
Write-BuildLog "  Hostname       : $Hostname" -Level INFO
Write-BuildLog "  Admin username : $AdminUsername" -Level INFO
Write-BuildLog "  Admin password : $AdminPassword" -Level INFO
Write-BuildLog "  VHDX size      : $SizeGB GB" -Level INFO
Write-BuildLog "  Temp VM name   : $TempVMName" -Level INFO
Write-BuildLog "  CPUs / RAM     : $CPUCount vCPU / $MemoryGB GB" -Level INFO
Write-BuildLog "  SSH public key : $(if ([string]::IsNullOrEmpty($SSHPublicKeyPath)) { '(none)' } else { $SSHPublicKeyPath })" -Level INFO

#endregion

#region Prerequisites

Test-Prerequisites

#endregion

#region Detect ISO type

Write-BuildLog 'Detecting ISO type...' -Level STEP

Write-BuildLog "  Mounting ISO temporarily for type detection: $ISOPath" -Level INFO
try {
    $detectMount = Mount-DiskImage -ImagePath $ISOPath -PassThru -ErrorAction Stop
} catch {
    Write-Error "Failed to mount ISO '$ISOPath' for type detection. Error: $_"
    exit 1
}

$isoType = 'Unknown'
try {
    Start-Sleep -Seconds 2
    $detectDrive = ($detectMount | Get-Volume -ErrorAction SilentlyContinue).DriveLetter + ':'

    if ($detectDrive -and $detectDrive -ne ':') {
        if ((Test-Path "$detectDrive\sources\install.wim") -or (Test-Path "$detectDrive\sources\install.esd")) {
            $isoType = 'Windows'
        } elseif ((Test-Path "$detectDrive\.disk\info") -or (Test-Path "$detectDrive\casper\vmlinuz")) {
            $isoType = 'Ubuntu'
        } else {
            $rootContents = (Get-ChildItem $detectDrive -ErrorAction SilentlyContinue).Name -join ', '
            Write-BuildLog "  ISO root contents: $rootContents" -Level WARN
        }
    }
} finally {
    # Always dismount the detection ISO — failure here would leave the drive letter leaked
    Dismount-DiskImage -ImagePath $ISOPath -ErrorAction SilentlyContinue | Out-Null
}

Write-BuildLog "  ISO type detected: $isoType" -Level SUCCESS

if ($isoType -eq 'Unknown') {
    Write-Error ('Cannot determine ISO type from ''{0}''.{1}Expected a Windows ISO (sources\install.wim or install.esd) or Ubuntu ISO (.disk\info or casper\vmlinuz).' -f $ISOPath, [Environment]::NewLine)
    exit 1
}

#endregion

#region Build

$buildStart = Get-Date

try {
    switch ($isoType) {
        'Windows' {
            Invoke-WindowsBuild `
                -ISOPath             $ISOPath `
                -OutputVHDXPath      $OutputVHDXPath `
                -SizeBytes           $sizeBytes `
                -AdminUsername       $AdminUsername `
                -AdminPassword       $secureAdminPassword `
                -Hostname            $Hostname `
                -WindowsEditionIndex $WindowsEditionIndex `
                -TempVMName          $TempVMName `
                -CPUCount            $CPUCount `
                -MemoryBytes         $memoryBytes
        }
        'Ubuntu' {
            Invoke-UbuntuBuild `
                -ISOPath            $ISOPath `
                -OutputVHDXPath     $OutputVHDXPath `
                -SizeBytes          $sizeBytes `
                -AdminUsername      $AdminUsername `
                -AdminPassword      $secureAdminPassword `
                -Hostname           $Hostname `
                -TempVMName         $TempVMName `
                -CPUCount           $CPUCount `
                -MemoryBytes        $memoryBytes `
                -VirtualSwitchName  $VirtualSwitchName `
                -SSHPublicKey       $sshPublicKey
        }
    }
} catch {
    Write-BuildLog '' -Level ERROR
    Write-BuildLog '================================================================' -Level ERROR
    Write-BuildLog ' BUILD FAILED' -Level ERROR
    Write-BuildLog "  Error     : $($_.Exception.Message)" -Level ERROR
    Write-BuildLog "  Location  : $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -Level ERROR
    Write-BuildLog '================================================================' -Level ERROR
    Write-BuildLog '' -Level ERROR
    Write-BuildLog 'Diagnostic tips:' -Level WARN
    Write-BuildLog '  Windows: Check C:\Windows\Temp\BaseImageSetup.log inside the guest VM (open the VHDX via Hyper-V or mount it)' -Level WARN
    Write-BuildLog '  Windows: Check Hyper-V Manager VM console for error messages during boot' -Level WARN
    Write-BuildLog '  Ubuntu : Open Hyper-V Manager and attach to the VM console to see the installer output' -Level WARN
    Write-BuildLog '  Ubuntu : Verify the ISO is Ubuntu 22.04+ (autoinstall requires subiquity installer)' -Level WARN
    exit 1
}

#endregion

$elapsed    = (Get-Date) - $buildStart
$elapsedMin = [math]::Round($elapsed.TotalMinutes, 1)
$outSizeGB  = if (Test-Path $OutputVHDXPath) { [math]::Round((Get-Item $OutputVHDXPath).Length / 1GB, 2) } else { 0 }
Write-BuildLog '' -Level SUCCESS
Write-BuildLog "Total build time: $elapsedMin minutes"
Write-BuildLog ('Output: {0} ({1} GB on disk)' -f $OutputVHDXPath, $outSizeGB) -Level SUCCESS
