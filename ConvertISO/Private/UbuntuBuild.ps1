#region Ubuntu cloud-init content

function New-UbuntuMetaData {
    param([string]$Hostname)
    return @"
instance-id: iid-$(New-Guid)
local-hostname: $Hostname
"@
}

function New-UbuntuUserData {
    <#
    .SYNOPSIS
        Generates a cloud-init user-data file in Ubuntu autoinstall format.
        Targets Ubuntu 22.04+ / 24.04 LTS Server ISOs.

    .NOTES
        The autoinstall key triggers subiquity's unattended installation mode.
        Ubuntu 22.04+ will automatically detect a CIDATA volume without needing
        the 'autoinstall' kernel parameter when user-data contains autoinstall:.
        If autoinstall does not trigger automatically, see the README note about
        modifying the ISO's GRUB configuration.
    #>
    param(
        [string]$Hostname,
        [string]$AdminUsername,
        [string]$HashedPassword,          # SHA-512 crypt ($6$...) for /etc/shadow
        [string]$Timezone = 'UTC',
        [bool]  $GeneralizeForCloning = $true,
        [string]$SSHPublicKey = ''        # optional; written to authorized_keys on the base image
    )

    $authorizedKeysYaml = if ([string]::IsNullOrWhiteSpace($SSHPublicKey)) {
        '    authorized-keys: []'
    } else {
        "    authorized-keys:`n      - $SSHPublicKey"
    }

    $generalizeCommands = if ($GeneralizeForCloning) {
        @"
  late-commands:
    # Generalize image so each clone gets a unique machine-id and fresh cloud-init run
    - curtin in-target -- cloud-init clean --logs
    - rm -f /target/etc/machine-id
    - truncate -s 0 /target/etc/machine-id
    # Restrict datasource to NoCloud + None so clones boot fast without a metadata service
    - |
      cat > /target/etc/cloud/cloud.cfg.d/99-datasource.cfg << 'EOF'
      datasource_list: [NoCloud, None]
      EOF
    # Delete SSH host keys; openssh regenerates them automatically on first sshd start
    - rm -f /target/etc/ssh/ssh_host_*
    # Shut down the installer VM (power_state is not recognised in Ubuntu 24.04 subiquity)
    - shutdown -h now
"@
    } else {
        '  late-commands: []'
    }

    return @"
#cloud-config
autoinstall:
  version: 1

  # ---- Identity ----
  identity:
    hostname: $Hostname
    username: $AdminUsername
    # Password hashed with SHA-512 crypt (openssl passwd -6 equivalent)
    password: "$HashedPassword"

  # ---- Locale / Keyboard ----
  locale: en_GB.UTF-8
  keyboard:
    layout: gb

  # ---- Timezone ----
  timezone: $Timezone

  # ---- Network (DHCP on first interface for SSH access) ----
  network:
    version: 2
    ethernets:
      eth0:
        dhcp4: true
        optional: true

  # ---- Storage (use entire disk, direct layout) ----
  storage:
    layout:
      name: direct

  # ---- SSH ----
  ssh:
    install-server: true
    allow-pw: true
$authorizedKeysYaml

  # ---- Packages ----
  packages:
    - cloud-init
    - net-tools
    - linux-image-virtual 
    - linux-tools-virtual 
    - linux-cloud-tools-virtual

  # ---- Sudoers ----
  user-data:
    users:
      - name: $AdminUsername
        groups: [sudo, adm]
        shell: /bin/bash
        sudo: ALL=(ALL) NOPASSWD:ALL
        lock_passwd: false

$generalizeCommands
"@
}

#endregion

#region Ubuntu ISO autoinstall patching

function Get-ISO9660FileInfo {
    <#
    .SYNOPSIS
        Parses an ISO9660 image's directory tree to return the byte offset, size, and
        directory-entry offset of a file inside the image.  Returns $null if not found.
        DirEntryOffset points to the ISO9660 directory record for the file so that the
        Data Length fields can be updated in-place when the patched content changes size.
    #>
    param(
        [string]$ISOPath,
        [string]$FilePath   # forward-slash path, e.g. 'boot/grub/grub.cfg'
    )

    $sectorSize = 2048
    $fs = [System.IO.File]::OpenRead($ISOPath)
    try {
        $buf = New-Object byte[] $sectorSize

        # Primary Volume Descriptor is always at sector 16
        $fs.Position = 16 * $sectorSize
        [void]$fs.Read($buf, 0, $sectorSize)
        if ($buf[0] -ne 1 -or [System.Text.Encoding]::ASCII.GetString($buf, 1, 5) -ne 'CD001') {
            throw "Sector 16 is not an ISO9660 PVD (type byte=$($buf[0]))"
        }

        # Root directory extent LBA at PVD+158 (LE uint32), size at PVD+166
        $dirLBA  = [BitConverter]::ToUInt32($buf, 158)
        $dirSize = [BitConverter]::ToUInt32($buf, 166)

        $dirEntryAbsOffset = -1L

        foreach ($part in ($FilePath -split '/')) {
            $readSize   = [math]::Ceiling($dirSize / $sectorSize) * $sectorSize
            $dirBuf     = New-Object byte[] $readSize
            $dirAbsBase = [long]$dirLBA * $sectorSize   # absolute ISO byte offset of this directory
            $fs.Position = $dirAbsBase
            [void]$fs.Read($dirBuf, 0, $readSize)

            $pos   = 0
            $found = $false
            while ($pos -lt $dirSize) {
                $recLen = $dirBuf[$pos]
                if ($recLen -eq 0) {
                    # Zero-pad to next sector boundary inside the directory extent
                    $pos = ([math]::Floor($pos / $sectorSize) + 1) * $sectorSize
                    continue
                }
                $nameLen = $dirBuf[$pos + 32]
                $rawName = [System.Text.Encoding]::ASCII.GetString($dirBuf, $pos + 33, $nameLen)
                $name    = ($rawName -replace ';[0-9]+$', '')   # strip ISO9660 version suffix ;1

                if ($name.ToUpperInvariant() -eq $part.ToUpperInvariant()) {
                    $dirEntryAbsOffset = $dirAbsBase + $pos     # absolute offset of this dir entry
                    $dirLBA  = [BitConverter]::ToUInt32($dirBuf, $pos + 2)
                    $dirSize = [BitConverter]::ToUInt32($dirBuf, $pos + 10)
                    $found   = $true
                    break
                }
                $pos += $recLen
            }
            if (-not $found) { return $null }
        }

        return @{
            ByteOffset     = [long]$dirLBA * $sectorSize
            Size           = $dirSize
            DirEntryOffset = $dirEntryAbsOffset  # position of the file's ISO9660 directory record
        }
    } finally {
        $fs.Close()
    }
}

function New-AutoinstallISO {
    <#
    .SYNOPSIS
        Creates a copy of a Ubuntu ISO with 'autoinstall' injected into every kernel
        command line in boot/grub/grub.cfg.  The original ISO is never modified.
        The patch is written in-place at the file's sector offset so no ISO repacking
        tools (oscdimg, IMAPI2FS, etc.) are required.
        Works for both Ubuntu Server and Desktop ISOs (22.04+ / 24.04+).
    #>
    param(
        [string]$SourceISOPath,
        [string]$OutputISOPath
    )

    Write-BuildLog "Preparing autoinstall ISO (patching grub.cfg in copy)..." -Level STEP

    # 1. Locate grub.cfg inside the ISO9660 directory tree
    $fileInfo = Get-ISO9660FileInfo -ISOPath $SourceISOPath -FilePath 'boot/grub/grub.cfg'
    if (-not $fileInfo) {
        throw "Cannot locate boot/grub/grub.cfg in '$SourceISOPath'. Verify this is a Ubuntu 22.04+ ISO."
    }
    Write-BuildLog "  grub.cfg found at byte offset $($fileInfo.ByteOffset), $($fileInfo.Size) bytes" -Level INFO

    # 2. Read the original grub.cfg bytes directly from the ISO
    $srcStream = [System.IO.File]::OpenRead($SourceISOPath)
    try {
        $srcStream.Position = $fileInfo.ByteOffset
        $originalBytes = New-Object byte[] $fileInfo.Size
        [void]$srcStream.Read($originalBytes, 0, $fileInfo.Size)
    } finally { $srcStream.Close() }

    $utf8     = [System.Text.UTF8Encoding]::new($false)
    $origText = $utf8.GetString($originalBytes)

    # 3. Add 'autoinstall' before the '---' separator on every linux/casper line.
    #    Ubuntu grub.cfg pattern:  linux   /casper/vmlinuz  ---
    #    After patch:              linux   /casper/vmlinuz autoinstall ---
    $patchedText = [System.Text.RegularExpressions.Regex]::Replace(
        $origText,
        '(?m)^(\s*linux\b[^\n]*?)\s+(---[^\n]*)$',
        '$1 autoinstall $2'
    )

    if ($patchedText -eq $origText) {
        throw "No 'linux ... ---' line found in grub.cfg. Cannot inject autoinstall kernel parameter."
    }

    $matchCount = ([regex]::Matches($patchedText, '\bautoinstall\b')).Count
    Write-BuildLog "  Injected 'autoinstall' into $matchCount kernel line(s)" -Level INFO

    # 4. Verify the patched content fits within the sectors already allocated to grub.cfg.
    #    ISO9660 files are padded to the next 2048-byte sector boundary, so we have
    #    up to (ceil(originalSize/2048)*2048) bytes of safe write space.
    $patchedBytes    = $utf8.GetBytes($patchedText)
    $allocatedBytes  = [math]::Ceiling($fileInfo.Size / 2048) * 2048
    if ($patchedBytes.Length -gt $allocatedBytes) {
        throw ("Patched grub.cfg ($($patchedBytes.Length) B) exceeds the allocated sector space " +
               "($allocatedBytes B). Cannot patch in-place.")
    }
    Write-BuildLog "  Patched size: $($patchedBytes.Length) B (allocated: $allocatedBytes B)" -Level INFO

    # 5. Copy the full ISO, then overwrite the grub.cfg content and update its
    #    directory entry size (LE at entry+10, BE at entry+14) to match the new length.
    $isoSizeMB = [math]::Round((Get-Item $SourceISOPath).Length / 1MB)
    Write-BuildLog "  Copying ISO ($isoSizeMB MB)..." -Level INFO
    Copy-Item -Path $SourceISOPath -Destination $OutputISOPath -ErrorAction Stop

    $newSizeLE = [BitConverter]::GetBytes([uint32]$patchedBytes.Length)
    $newSizeBE = [byte[]]@($newSizeLE[3], $newSizeLE[2], $newSizeLE[1], $newSizeLE[0])

    $dstStream = [System.IO.FileStream]::new($OutputISOPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write)
    try {
        # Write patched file content
        $dstStream.Position = $fileInfo.ByteOffset
        $dstStream.Write($patchedBytes, 0, $patchedBytes.Length)
        # Update Data Length in the ISO9660 directory entry (LE at +10, BE at +14)
        $dstStream.Position = $fileInfo.DirEntryOffset + 10
        $dstStream.Write($newSizeLE, 0, 4)
        $dstStream.Position = $fileInfo.DirEntryOffset + 14
        $dstStream.Write($newSizeBE, 0, 4)
    } finally { $dstStream.Close() }

    Write-BuildLog "  Autoinstall ISO ready: $OutputISOPath" -Level SUCCESS
    return $OutputISOPath
}

#endregion

#region Ubuntu seed disk

function New-SeedVHDX {
    <#
    .SYNOPSIS
        Creates a small FAT-formatted VHD containing cloud-init user-data and meta-data.
        Using FAT instead of ISO9660 guarantees lowercase filenames (user-data, meta-data)
        so cloud-init's NoCloud datasource can find them on any Ubuntu version.
        The volume is labelled CIDATA which cloud-init detects automatically.
    #>
    param(
        [string]$OutputPath,
        [string]$UserDataContent,
        [string]$MetaDataContent,
        [string]$VolumeLabel = 'CIDATA'
    )

    Write-BuildLog "Creating cloud-init seed disk: $OutputPath (label: $VolumeLabel)" -Level STEP

    $mountedVhd = $null
    try {
        New-VHD -Path $OutputPath -SizeBytes 10MB -Fixed -ErrorAction Stop | Out-Null
        Write-BuildLog "  VHD created (10 MB fixed)"

        $mountedVhd = Mount-VHD -Path $OutputPath -PassThru -ErrorAction Stop
        $disk       = Get-Disk -Number $mountedVhd.DiskNumber -ErrorAction Stop

        if ($disk.OperationalStatus -eq 'Offline') {
            Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop
        }

        Initialize-Disk -Number $disk.Number -PartitionStyle MBR -ErrorAction Stop
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
        Start-Sleep -Seconds 1

        Format-Volume -DriveLetter $partition.DriveLetter `
                      -FileSystem FAT -NewFileSystemLabel $VolumeLabel `
                      -Force -Confirm:$false -ErrorAction Stop | Out-Null
        Write-BuildLog "  Formatted FAT, label=$VolumeLabel, drive=$($partition.DriveLetter):"

        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText("$($partition.DriveLetter):\user-data", $UserDataContent, $utf8NoBom)
        [System.IO.File]::WriteAllText("$($partition.DriveLetter):\meta-data", $MetaDataContent, $utf8NoBom)
        Write-BuildLog "  Wrote user-data and meta-data" -Level SUCCESS

        Dismount-VHD -Path $OutputPath -ErrorAction Stop
        $mountedVhd = $null
        Write-BuildLog "  Seed disk ready." -Level SUCCESS

        return $OutputPath
    } catch {
        if ($mountedVhd) { Dismount-VHD -Path $OutputPath -ErrorAction SilentlyContinue }
        throw "Failed to create seed VHD at '$OutputPath'. Error: $($_.Exception.Message)"
    }
}

#endregion

#region Ubuntu VHDX

function New-UbuntuVHDX {
    <#
    .SYNOPSIS
        Creates a new dynamic VHDX for the Ubuntu installer to partition and format.
        Returns the path to the created VHDX.
    #>
    param(
        [string]$VHDXPath,
        [long]  $SizeBytes
    )

    Write-BuildLog "Creating Ubuntu VHDX: $VHDXPath ($([math]::Round($SizeBytes/1GB,1)) GB)" -Level STEP
    try {
        New-VHD -Path $VHDXPath -SizeBytes $SizeBytes -Dynamic -ErrorAction Stop | Out-Null
        Write-BuildLog "  VHDX created." -Level SUCCESS
    } catch {
        throw "Failed to create VHDX at '$VHDXPath'. Error: $($_.Exception.Message)"
    }
    return $VHDXPath
}

#endregion

#region Temp VM (Ubuntu)

function Invoke-UbuntuTempVM {
    <#
    .SYNOPSIS
        Creates a Gen2 Hyper-V VM with Secure Boot disabled (required for Ubuntu),
        attaches the Ubuntu ISO as primary DVD and the CIDATA seed ISO as secondary DVD,
        starts the VM, waits for the autoinstall to complete (VM shuts down),
        then removes the VM (preserving the VHDX).
    #>
    param(
        [string]$VMName,
        [string]$VHDXPath,
        [string]$UbuntuISOPath,
        [string]$SeedDiskPath,    # FAT-formatted VHD labelled CIDATA
        [int]   $CPUCount,
        [long]  $MemoryBytes,
        [int]   $TimeoutMinutes = 120,
        [string]$VirtualSwitchName = 'Default Switch'
    )

    Write-BuildLog "Creating temporary Ubuntu VM: '$VMName'" -Level STEP

    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "A VM named '$VMName' already exists. Remove it first or choose a different -TempVMName."
    }

    try {
        # Resolve virtual switch
        $switch = Get-VMSwitch -Name $VirtualSwitchName -ErrorAction SilentlyContinue
        if (-not $switch) {
            Write-BuildLog "  Virtual switch '$VirtualSwitchName' not found. Available switches:" -Level WARN
            Get-VMSwitch | Select-Object Name, SwitchType | Format-Table | Out-String | Write-BuildLog
            Write-BuildLog "  Proceeding without network switch. Ubuntu installer may fail if it needs internet access." -Level WARN
            $VirtualSwitchName = $null
        }

        # Create VM
        $newVMParams = @{
            Name               = $VMName
            Generation         = 2
            MemoryStartupBytes = $MemoryBytes
            NoVHD              = $true
            ErrorAction        = 'Stop'
        }
        if ($VirtualSwitchName) { $newVMParams['SwitchName'] = $VirtualSwitchName }

        $vm = New-VM @newVMParams
        Write-BuildLog "  VM '$VMName' created (Gen2)" -Level SUCCESS

        # CPU and memory
        Set-VMProcessor -VMName $VMName -Count $CPUCount -ErrorAction Stop
        Set-VMMemory    -VMName $VMName -DynamicMemoryEnabled $false -ErrorAction Stop
        Write-BuildLog "  CPU: $CPUCount, Memory: $([math]::Round($MemoryBytes/1GB,1)) GB (static)"

        # Disable Secure Boot : required for Ubuntu on Gen2
        Set-VMFirmware -VMName $VMName -EnableSecureBoot Off -ErrorAction Stop
        Write-BuildLog '  Secure Boot: disabled (required for Ubuntu)'

        # Disable checkpoints
        Set-VM -VMName $VMName -CheckpointType Disabled -ErrorAction Stop

        # Attach target VHDX (where Ubuntu installs to)
        Add-VMHardDiskDrive -VMName $VMName -Path $VHDXPath -ControllerType SCSI -ErrorAction Stop
        Write-BuildLog "  VHDX attached: $VHDXPath"

        # Attach Ubuntu installer ISO as DVD boot device
        $ubuntuDvd = Add-VMDvdDrive -VMName $VMName -Path $UbuntuISOPath -ErrorAction Stop
        Write-BuildLog "  Ubuntu ISO attached: $UbuntuISOPath"

        # Attach CIDATA seed as a SCSI disk (FAT-formatted VHD labelled CIDATA).
        # Using a VHD instead of an ISO guarantees lowercase filenames so cloud-init
        # can find user-data / meta-data on any Ubuntu version.
        Add-VMHardDiskDrive -VMName $VMName -Path $SeedDiskPath -ControllerType SCSI -ErrorAction Stop
        Write-BuildLog "  Seed disk attached: $SeedDiskPath"

        # Boot order: Ubuntu ISO first, then VHDX
        $firmware       = Get-VMFirmware -VMName $VMName
        $bootOrder      = $firmware.BootOrder
        $dvdBootDevice  = $bootOrder | Where-Object { $_.BootType -eq 'Drive' -and $_.Device -is [Microsoft.HyperV.PowerShell.DvdDrive] } | Select-Object -First 1
        if ($dvdBootDevice) {
            Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdBootDevice -ErrorAction Stop
            Write-BuildLog '  Boot order: DVD (Ubuntu ISO) first'
        } else {
            Write-BuildLog '  Could not explicitly set DVD as first boot device : VM may not boot from ISO' -Level WARN
        }

        # set start to nothing to prevent reboots
        Set-VM -VMName $VMName -AutomaticStartAction Nothing -ErrorAction SilentlyContinue
        Write-BuildLog '  Automatic start action: Nothing'

        # Start VM
        Write-BuildLog "Starting Ubuntu VM '$VMName'..." -Level STEP
        Start-VM -Name $VMName -ErrorAction Stop
        Write-BuildLog '  VM started.' -Level SUCCESS
        Write-BuildLog '  Ubuntu autoinstall is running. This typically takes 15-30 minutes.'
        Write-BuildLog '  The VM will shut down automatically when installation is complete.'
        Write-BuildLog "  If installation does not begin, open Hyper-V Manager and check the VM console."

        # Wait for VM to shut down (power_state: poweroff in user-data triggers this)
        Wait-VMShutdown -VMName $VMName -TimeoutMinutes $TimeoutMinutes

    } catch {
        Write-BuildLog "Error during Ubuntu temp VM '$VMName': $($_.Exception.Message)" -Level ERROR
        Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
            Write-BuildLog "  Removing temp VM '$VMName'..." -Level INFO
            Remove-VM -Name $VMName -Force -ErrorAction SilentlyContinue
            Write-BuildLog '  Temp VM removed.' -Level SUCCESS
        }
    }
}

#endregion

#region Main Ubuntu Build Orchestration

function Invoke-UbuntuBuild {
    <#
    .SYNOPSIS
        Full orchestration of the Ubuntu ISO -> generalized VHDX pipeline.
    #>
    param(
        [string]$ISOPath,
        [string]$OutputVHDXPath,
        [long]  $SizeBytes,
        [string]$AdminUsername,
        [System.Security.SecureString]$AdminPassword,
        [string]$Hostname,
        [string]$TempVMName,
        [int]   $CPUCount,
        [long]  $MemoryBytes,
        [string]$Timezone = 'UTC',
        [string]$VirtualSwitchName = 'Default Switch',
        [string]$SSHPublicKey = ''
    )

    Write-BuildLog '================================================================' -Level STEP
    Write-BuildLog ' Ubuntu Build Pipeline Starting' -Level STEP
    Write-BuildLog "  ISO          : $ISOPath" -Level STEP
    Write-BuildLog "  Output VHDX  : $OutputVHDXPath" -Level STEP
    Write-BuildLog "  Hostname     : $Hostname" -Level STEP
    Write-BuildLog "  Admin user   : $AdminUsername" -Level STEP
    Write-BuildLog "  VHDX size    : $([math]::Round($SizeBytes/1GB,1)) GB" -Level STEP
    Write-BuildLog "  SSH key      : $(if ([string]::IsNullOrWhiteSpace($SSHPublicKey)) { '(none)' } else { 'provided' })" -Level STEP
    Write-BuildLog '================================================================' -Level STEP

    $seedDiskPath    = $null
    $patchedISOPath  = $null
    $tempDir         = $null

    try {
        # ---- 1. Create temp directory ----
        $tempDir = New-Item -ItemType Directory `
                             -Path (Join-Path $env:TEMP "UbuntuBuild-$(Get-Date -Format 'yyyyMMdd-HHmmss')") `
                             -Force -ErrorAction Stop
        Write-BuildLog "Temp directory: $($tempDir.FullName)" -Level INFO

        # ---- 2. Hash password for cloud-init ----
        Write-BuildLog 'Generating SHA-512 password hash for cloud-init...' -Level STEP
        $hashedPassword = ConvertTo-UnixPasswordHash -SecurePassword $AdminPassword
        Write-BuildLog '  Password hashed.' -Level SUCCESS

        # ---- 3. Generate cloud-init content ----
        Write-BuildLog 'Generating cloud-init user-data and meta-data...' -Level STEP

        $metaData = New-UbuntuMetaData -Hostname $Hostname
        $userData = New-UbuntuUserData `
            -Hostname             $Hostname `
            -AdminUsername        $AdminUsername `
            -HashedPassword       $hashedPassword `
            -Timezone             $Timezone `
            -GeneralizeForCloning $true `
            -SSHPublicKey         $SSHPublicKey

        Write-BuildLog '  user-data generated.' -Level SUCCESS

        # ---- 4. Create CIDATA seed disk (FAT VHD, label CIDATA) ----
        $seedDiskPath = Join-Path $tempDir.FullName 'seed.vhdx'
        New-SeedVHDX -OutputPath $seedDiskPath -UserDataContent $userData -MetaDataContent $metaData

        # ---- 5. Patch ISO grub.cfg to add 'autoinstall' kernel parameter ----
        #    Creates a copy of the ISO; the original file is never modified.
        #    This bypasses the Ubuntu 24.04 confirmation prompt on both Server and Desktop ISOs.
        $patchedISOPath = Join-Path $tempDir.FullName 'ubuntu-autoinstall.iso'
        New-AutoinstallISO -SourceISOPath $ISOPath -OutputISOPath $patchedISOPath

        # ---- 6. Create Ubuntu VHDX ----
        New-UbuntuVHDX -VHDXPath $OutputVHDXPath -SizeBytes $SizeBytes

        # ---- 7. Boot temp VM and wait for autoinstall ----
        Invoke-UbuntuTempVM `
            -VMName             $TempVMName `
            -VHDXPath           $OutputVHDXPath `
            -UbuntuISOPath      $patchedISOPath `
            -SeedDiskPath       $seedDiskPath `
            -CPUCount           $CPUCount `
            -MemoryBytes        $MemoryBytes `
            -TimeoutMinutes     120 `
            -VirtualSwitchName  $VirtualSwitchName

        # ---- Done ----
        Write-BuildLog '' -Level SUCCESS
        Write-BuildLog '================================================================' -Level SUCCESS
        Write-BuildLog ' Ubuntu Build Complete' -Level SUCCESS
        Write-BuildLog "  Output VHDX: $OutputVHDXPath" -Level SUCCESS
        Write-BuildLog '  The VHDX has been generalised (cloud-init clean, machine-id cleared).' -Level SUCCESS
        Write-BuildLog '  Provide a CIDATA seed ISO to each clone for per-VM configuration.' -Level SUCCESS
        Write-BuildLog '================================================================' -Level SUCCESS

    } catch {
        Write-BuildLog 'Ubuntu build pipeline FAILED.' -Level ERROR
        Write-BuildLog "  Error: $($_.Exception.Message)" -Level ERROR
        throw
    } finally {
        # Clean up temp directory (contains seed ISO)
        if ($tempDir -and (Test-Path $tempDir.FullName)) {
            Remove-Item -Path $tempDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-BuildLog '  Temp directory cleaned up.' -Level INFO
        }
    }
}

#endregion
