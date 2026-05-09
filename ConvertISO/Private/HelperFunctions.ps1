#region Logging

function Write-BuildLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','SUCCESS','WARN','ERROR','STEP')][string]$Level = 'INFO'
    )
    $ts     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = switch ($Level) {
        'INFO'    { '[INFO]   ' }
        'SUCCESS' { '[SUCCESS]' }
        'WARN'    { '[WARN]   ' }
        'ERROR'   { '[ERROR]  ' }
        'STEP'    { '[STEP]   ' }
    }
    $color  = switch ($Level) {
        'INFO'    { 'Cyan'    }
        'SUCCESS' { 'Green'   }
        'WARN'    { 'Yellow'  }
        'ERROR'   { 'Red'     }
        'STEP'    { 'Magenta' }
    }
    Write-Host "[$ts] $prefix $Message" -ForegroundColor $color
}

#endregion

#region Prerequisites

function Test-Prerequisites {
    Write-BuildLog 'Checking prerequisites...' -Level STEP

    # Must run as Administrator
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Script must be run as Administrator. Right-click your PowerShell shortcut and choose 'Run as Administrator'."
    }
    Write-BuildLog "  Running as Administrator: OK ($($identity.Name))" -Level SUCCESS

    # Hyper-V PowerShell module
    if (-not (Get-Module -ListAvailable -Name Hyper-V -ErrorAction SilentlyContinue)) {
        throw "Hyper-V PowerShell module not found.`n  Enable with: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell"
    }
    Write-BuildLog '  Hyper-V PowerShell module: found' -Level SUCCESS

    # Hyper-V Virtual Machine Management service
    $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $vmms) {
        throw "Hyper-V service (vmms) does not exist. Ensure Hyper-V is installed and enabled."
    }
    if ($vmms.Status -ne 'Running') {
        throw "Hyper-V service (vmms) is not running (status: $($vmms.Status)). Start it with: Start-Service vmms"
    }
    Write-BuildLog '  Hyper-V service (vmms): Running' -Level SUCCESS

    # dism.exe
    $dismPath = Join-Path $env:SystemRoot 'System32\dism.exe'
    if (-not (Test-Path $dismPath)) {
        throw "dism.exe not found at '$dismPath'. This is unexpected on Windows 8+."
    }
    Write-BuildLog "  dism.exe: $dismPath" -Level SUCCESS

    # bcdboot.exe
    $bcdbootPath = Join-Path $env:SystemRoot 'System32\bcdboot.exe'
    if (-not (Test-Path $bcdbootPath)) {
        throw "bcdboot.exe not found at '$bcdbootPath'. This is unexpected on Windows 7+."
    }
    Write-BuildLog "  bcdboot.exe: $bcdbootPath" -Level SUCCESS

    Write-BuildLog 'All prerequisites satisfied.' -Level SUCCESS
}

#endregion

#region Disk Safety

function Get-AvailableDriveLetter {
    <#
    .SYNOPSIS
        Returns the first available drive letter in the S-Z range, excluding
        any already in use or explicitly reserved by the caller.
    #>
    param([string[]]$AlreadyAllocated = @())

    # Three-layer check for in-use drive letters:
    # 1. Get-PSDrive  - active filesystem drives visible to PowerShell
    # 2. Get-Volume   - WMI/CIM volumes (catches some diskpart-assigned letters)
    # 3. mountvol /L  - queries the VDS (Virtual Disk Service) layer directly;
    #                   this catches EFI partition letters and orphaned letters
    #                   from failed runs that are registered in VDS but whose
    #                   path is not accessible (so Test-Path and Get-Volume miss them)
    $psLetters  = (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name
    $volLetters = (Get-Volume -ErrorAction SilentlyContinue |
                   Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 }).DriveLetter |
                  ForEach-Object { [string]$_ }
    $vdsLetters = 'T','U','V','W','X','Y','Z' | Where-Object {
        & mountvol "${_}:\" /L 2>&1 | Out-Null
        $LASTEXITCODE -eq 0    # exit 0 = letter has a registered volume in VDS
    }
    $inUse = @($psLetters + $volLetters + $vdsLetters + $AlreadyAllocated) | Sort-Object -Unique

    $candidate = 'T','U','V','W','X','Y','Z' | Where-Object { $_ -notin $inUse } | Select-Object -First 1

    if (-not $candidate) {
        throw "No available drive letters in range S-Z. Currently in use: $($inUse -join ', ')."
    }

    Write-BuildLog "  Allocated drive letter: $candidate" -Level INFO
    return $candidate
}

function Protect-HostDisk {
    <#
    .SYNOPSIS
        Safety gate : aborts if the given disk number is the host's boot or
        system disk, or if it already has partitions (fresh VHDX must be empty).
    #>
    param([int]$DiskNumber)

    Write-BuildLog "Running host-disk safety checks on disk $DiskNumber..." -Level STEP

    try {
        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    } catch {
        throw "Could not retrieve disk information for disk $DiskNumber. Error: $_"
    }

    Write-BuildLog "  Disk $DiskNumber - FriendlyName: '$($disk.FriendlyName)', BusType: $($disk.BusType), PartitionStyle: $($disk.PartitionStyle), Partitions: $($disk.NumberOfPartitions), AllocatedSize: $($disk.AllocatedSize) bytes"

    # Hard stop 1: never touch disk 0 (almost always the host OS drive)
    if ($DiskNumber -eq 0) {
        throw "SAFETY ABORT: Disk 0 is refused unconditionally. VHDXs should never mount as disk 0 on a system with a physical OS drive."
    }

    # Hard stop 2: bus type must identify as a virtual disk
    # Physical and iSCSI disks use types like SATA, NVMe, SAS, USB, iSCSI.
    # A Hyper-V-mounted VHD/VHDX always reports 'File Backed Virtual'.
    $allowedBusTypes = @('File Backed Virtual')
    if ($disk.BusType -notin $allowedBusTypes) {
        throw "SAFETY ABORT: Disk $DiskNumber has BusType '$($disk.BusType)'. Only 'File Backed Virtual' (mounted VHD/VHDX) is permitted. Refusing to modify a physical or network disk."
    }

    # Hard stop 3: must not be the active boot or system disk
    if ($disk.IsBoot) {
        throw "SAFETY ABORT: Disk $DiskNumber is the host BOOT disk. Investigate why Mount-VHD returned this disk number."
    }

    if ($disk.IsSystem) {
        throw "SAFETY ABORT: Disk $DiskNumber is the host SYSTEM disk (holds EFI/boot files). Will not modify it."
    }

    # Hard stop 4: cluster disks
    if ($disk.IsHighlyAvailable) {
        throw "SAFETY ABORT: Disk $DiskNumber is flagged as Highly Available (cluster disk). Refusing to modify."
    }

    # Hard stop 5: must be unpartitioned (fresh VHDX has 0 partitions)
    if ($disk.NumberOfPartitions -gt 0) {
        $partInfo = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
                    Select-Object PartitionNumber, @{n='SizeMB';e={[math]::Round($_.Size/1MB,1)}}, Type |
                    Format-Table -AutoSize | Out-String
        throw "SAFETY ABORT: Disk $DiskNumber already has $($disk.NumberOfPartitions) partition(s). A freshly created VHDX must be unpartitioned.`nExisting partitions:`n$partInfo"
    }

    if ($disk.AllocatedSize -gt 0) {
        throw "SAFETY ABORT: Disk $DiskNumber has $($disk.AllocatedSize) bytes already allocated. Expected 0 for a new VHDX."
    }

    Write-BuildLog "  Disk $DiskNumber passed all safety checks (BusType confirmed as virtual disk)." -Level SUCCESS
}

#endregion

#region VM Helpers

function Wait-VMShutdown {
    <#
    .SYNOPSIS
        Polls until the named VM reaches the 'Off' state or the timeout expires.
    #>
    param(
        [string]$VMName,
        [int]$TimeoutMinutes = 90,
        [int]$PollIntervalSeconds = 5
    )

    Write-BuildLog "Waiting for VM '$VMName' to shut down (timeout: ${TimeoutMinutes}m, poll: ${PollIntervalSeconds}s)..." -Level STEP
    $deadline  = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastState = ''

    while ((Get-Date) -lt $deadline) {
        try {
            $vm = Get-VM -Name $VMName -ErrorAction Stop
        } catch {
            throw "Lost track of VM '$VMName' while waiting for shutdown. Error: $_"
        }

        if ($vm.State -ne $lastState) {
            Write-BuildLog "  VM state changed: $lastState -> $($vm.State)"
            $lastState = $vm.State
        }

        if ($vm.State -eq 'Off') {
            Write-BuildLog "  VM '$VMName' is Off." -Level SUCCESS
            return
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    # Timeout : collect diagnostics before throwing
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    $stateInfo = if ($vm) { "Current state: $($vm.State)" } else { "(VM no longer found)" }
    throw ('Timeout: VM ''{0}'' did not reach ''Off'' state within {1} minutes. {2}.{3}Check Hyper-V Manager for VM console output or review C:\Windows\Temp\BaseImageSetup.log inside the guest.' -f $VMName, $TimeoutMinutes, $stateInfo, [Environment]::NewLine)
}

#endregion

#region C# Helpers (compiled once per session)

$script:CSharpHelpersLoaded = $false

function Initialize-CSharpHelpers {
    if ($script:CSharpHelpersLoaded) { return }

    Write-BuildLog 'Compiling C# helper types (SHA512Crypt)...' -Level INFO

    $src = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

/// <summary>
/// SHA-512 crypt implementation matching openssl passwd -6 / mkpasswd -m sha-512.
/// Follows https://www.akkadia.org/docs/SHA-crypt.txt
/// </summary>
public static class SHA512Crypt {
    private const string B64CHARS = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    private const int ROUNDS = 5000;

    public static string Hash(string password, string salt = null) {
        // Generate a random 12-char salt if not supplied
        if (string.IsNullOrEmpty(salt)) {
            byte[] raw = new byte[16];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(raw);
            var sb = new StringBuilder(12);
            foreach (byte b in raw) { sb.Append(B64CHARS[b % B64CHARS.Length]); if (sb.Length == 12) break; }
            salt = sb.ToString();
        }
        // Strip prefix if caller passed the full $6$salt$ string
        if (salt.StartsWith("$6$")) salt = salt.Substring(3);
        int dollar = salt.IndexOf('$');
        if (dollar >= 0) salt = salt.Substring(0, dollar);
        if (salt.Length > 16) salt = salt.Substring(0, 16);

        byte[] pw = Encoding.UTF8.GetBytes(password);
        byte[] s  = Encoding.UTF8.GetBytes(salt);

        using (SHA512 sha = SHA512.Create()) {

            // --- Step 1-8: digest B ---
            byte[] digestB = sha.ComputeHash(Concat(pw, s, pw));

            // --- Step 9-10: build buffer for digest A ---
            var bufA = new List<byte>();
            bufA.AddRange(pw);
            bufA.AddRange(s);
            for (int i = pw.Length; i > 0; i -= 64)
                bufA.AddRange(Slice(digestB, 0, Math.Min(i, 64)));
            for (int bits = pw.Length; bits > 0; bits >>= 1)
                bufA.AddRange((bits & 1) != 0 ? (IEnumerable<byte>)digestB : pw);
            byte[] digestA = sha.ComputeHash(bufA.ToArray());

            // --- Step 12-15: P string ---
            var bufP = new List<byte>();
            for (int i = 0; i < pw.Length; i++) bufP.AddRange(pw);
            byte[] digestP = sha.ComputeHash(bufP.ToArray());
            byte[] P = new byte[pw.Length];
            for (int i = 0; i < pw.Length; i++) P[i] = digestP[i % 64];

            // --- Step 16-19: S string ---
            var bufS = new List<byte>();
            for (int i = 0; i < 16 + digestA[0]; i++) bufS.AddRange(s);
            byte[] digestS = sha.ComputeHash(bufS.ToArray());
            byte[] S = new byte[s.Length];
            for (int i = 0; i < s.Length; i++) S[i] = digestS[i % 64];

            // --- Step 20: ROUNDS iterations ---
            byte[] C = (byte[])digestA.Clone();
            for (int i = 0; i < ROUNDS; i++) {
                var buf = new List<byte>();
                if ((i & 1) != 0) buf.AddRange(P); else buf.AddRange(C);
                if (i % 3 != 0) buf.AddRange(S);
                if (i % 7 != 0) buf.AddRange(P);
                if ((i & 1) != 0) buf.AddRange(C); else buf.AddRange(P);
                C = sha.ComputeHash(buf.ToArray());
            }

            // --- Step 21: encode ---
            return "$6$" + salt + "$" + Encode(C);
        }
    }

    private static byte[] Concat(params byte[][] parts) {
        var r = new List<byte>();
        foreach (var p in parts) r.AddRange(p);
        return r.ToArray();
    }

    private static byte[] Slice(byte[] src, int offset, int count) {
        byte[] r = new byte[count];
        Array.Copy(src, offset, r, 0, count);
        return r;
    }

    // SHA-512 crypt uses a specific byte permutation before base64 encoding
    private static string Encode(byte[] b) {
        var sb = new StringBuilder(86);
        // Permutation table from spec (groups of 3 bytes → 4 base64 chars)
        int[,] order = {
            {0,21,42},{22,43,1},{44,2,23},{3,24,45},{25,46,4},{47,5,26},
            {6,27,48},{28,49,7},{50,8,29},{9,30,51},{31,52,10},{53,11,32},
            {12,33,54},{34,55,13},{56,14,35},{15,36,57},{37,58,16},{59,17,38},
            {18,39,60},{40,61,19},{62,20,41}
        };
        for (int g = 0; g < 21; g++) {
            int w = (b[order[g,0]] << 16) | (b[order[g,1]] << 8) | b[order[g,2]];
            sb.Append(B64CHARS[ w        & 63]);
            sb.Append(B64CHARS[(w >>  6) & 63]);
            sb.Append(B64CHARS[(w >> 12) & 63]);
            sb.Append(B64CHARS[(w >> 18) & 63]);
        }
        // Last byte encodes to 2 chars
        int last = b[63];
        sb.Append(B64CHARS[ last       & 63]);
        sb.Append(B64CHARS[(last >> 6) & 63]);
        return sb.ToString();
    }
}
'@
    try {
        Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
        Write-BuildLog '  C# helpers compiled successfully.' -Level SUCCESS
    } catch {
        if ($_.Exception.Message -like '*already exists*') {
            # Types were compiled in a previous build in the same PowerShell session.
            # Add-Type cannot redefine them, but they are already usable.
            Write-BuildLog '  C# helpers already compiled in this session (skipping recompile).' -Level INFO
        } else {
            throw "Failed to compile C# helper types. Error: $($_.Exception.Message)`nFull details: $_"
        }
    }
    $script:CSharpHelpersLoaded = $true
}

#endregion

#region Password Helpers

function ConvertTo-UnixPasswordHash {
    <#
    .SYNOPSIS
        Returns a SHA-512 crypt hash ($6$...) from a SecureString.
        Compatible with Linux /etc/shadow and cloud-init identity.password.
    #>
    param([System.Security.SecureString]$SecurePassword)

    Initialize-CSharpHelpers

    $bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        return [SHA512Crypt]::Hash($plain)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function ConvertTo-UnattendPassword {
    <#
    .SYNOPSIS
        Encodes a SecureString as a Windows unattend.xml password value
        (UTF-16LE Base64 of '<password>Password').
    #>
    param([System.Security.SecureString]$SecurePassword)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
        $plain   = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($plain + 'Password'))
        return $encoded
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

#endregion
