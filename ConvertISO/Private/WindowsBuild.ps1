#region WIM Discovery

function Get-ISOWIMPath {
    <#
    .SYNOPSIS
        Locates install.wim or install.esd on a mounted ISO drive.
        Returns a hashtable with keys: Path, IsESD.
    #>
    param([string]$DriveLetter)

    $wimPath = Join-Path $DriveLetter 'sources\install.wim'
    $esdPath = Join-Path $DriveLetter 'sources\install.esd'

    if (Test-Path $wimPath) {
        Write-BuildLog "  Found: $wimPath" -Level SUCCESS
        return @{ Path = $wimPath; IsESD = $false }
    }
    if (Test-Path $esdPath) {
        Write-BuildLog "  Found: $esdPath (ESD - will be exported to WIM)" -Level SUCCESS
        return @{ Path = $esdPath; IsESD = $true }
    }

    throw "No install.wim or install.esd found under '$DriveLetter\sources\'. Verify this is a valid Windows ISO."
}

function Export-ESDtoWIM {
    <#
    .SYNOPSIS
        Exports a specific index from an ESD file to a standard WIM using DISM.
        Returns the path to the exported WIM.
    #>
    param(
        [string]$ESDPath,
        [int]   $ImageIndex,
        [string]$TempDir
    )

    $wimOut = Join-Path $TempDir 'install.wim'
    Write-BuildLog "  Exporting index $ImageIndex from ESD to WIM: $wimOut" -Level INFO
    Write-BuildLog "  (This may take several minutes...)" -Level INFO

    $dismArgs = @(
        '/Export-Image',
        "/SourceImageFile:`"$ESDPath`"",
        "/SourceIndex:$ImageIndex",
        "/DestinationImageFile:`"$wimOut`"",
        '/Compress:Max',
        '/CheckIntegrity'
    )

    Write-BuildLog "  Running: dism $($dismArgs -join ' ')" -Level INFO
    $result = & "$env:SystemRoot\System32\dism.exe" @dismArgs 2>&1
    $exitCode = $LASTEXITCODE

    $result | ForEach-Object { Write-BuildLog "    [dism] $_" -Level INFO }

    if ($exitCode -ne 0) {
        throw ('DISM ESD export failed (exit code {0}). Source: ''{1}'', Index: {2}.{3}DISM output shown above.' -f $exitCode, $ESDPath, $ImageIndex, [Environment]::NewLine)
    }

    if (-not (Test-Path $wimOut)) {
        throw "DISM reported success but WIM file not found at '$wimOut'."
    }

    Write-BuildLog "  ESD export complete: $wimOut ($([math]::Round((Get-Item $wimOut).Length/1GB,2)) GB)" -Level SUCCESS
    return $wimOut
}

function Get-WIMImageInfo {
    <#
    .SYNOPSIS
        Returns DISM image info for all indexes in a WIM/ESD as a list of objects.
    #>
    param([string]$ImageFile)

    Write-BuildLog "  Querying image info: $ImageFile" -Level INFO

    $dismArgs = @('/Get-ImageInfo', "/ImageFile:`"$ImageFile`"")
    $raw      = & "$env:SystemRoot\System32\dism.exe" @dismArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $raw | ForEach-Object { Write-BuildLog "    [dism] $_" -Level INFO }
        throw "DISM /Get-ImageInfo failed (exit code $exitCode) for '$ImageFile'."
    }

    # Also query via PowerShell cmdlet for richer object data
    try {
        $images = Get-WindowsImage -ImagePath $ImageFile -ErrorAction Stop
        return $images
    } catch {
        Write-BuildLog "  Get-WindowsImage cmdlet failed, falling back to DISM text output: $_" -Level WARN
        # Parse DISM text output as fallback
        $images  = @()
        $current = $null
        foreach ($line in $raw) {
            if ($line -match '^Index\s*:\s*(\d+)') {
                if ($current) { $images += $current }
                $current = [PSCustomObject]@{ ImageIndex = [int]$matches[1]; ImageName = ''; ImageDescription = ''; ImageSize = 0; ImageVersion = '' }
            } elseif ($current -and $line -match '^Name\s*:\s*(.+)') {
                $current.ImageName = $matches[1].Trim()
            } elseif ($current -and $line -match '^Description\s*:\s*(.+)') {
                $current.ImageDescription = $matches[1].Trim()
            } elseif ($current -and $line -match '^Size\s*:\s*([\d,]+)') {
                $current.ImageSize = [int64]($matches[1] -replace ',','')
            }
        }
        if ($current) { $images += $current }
        return $images
    }
}

function Select-WindowsEdition {
    <#
    .SYNOPSIS
        Lists available editions and either validates a supplied index or prompts
        the user to choose one interactively.
    #>
    param(
        [string]$ImageFile,
        [int]   $RequestedIndex = 0
    )

    $images = Get-WIMImageInfo -ImageFile $ImageFile

    if (-not $images -or $images.Count -eq 0) {
        throw "No images found in '$ImageFile'. The file may be corrupt or unsupported."
    }

    Write-BuildLog '' -Level INFO
    Write-BuildLog '  Available Windows editions:' -Level INFO
    foreach ($img in $images) {
        $sizGB = [math]::Round($img.ImageSize / 1GB, 1)
        Write-BuildLog "    [$($img.ImageIndex)] $($img.ImageName) ($sizGB GB)" -Level INFO
    }
    Write-BuildLog '' -Level INFO

    if ($RequestedIndex -gt 0) {
        $match = $images | Where-Object { $_.ImageIndex -eq $RequestedIndex }
        if (-not $match) {
            throw "Requested edition index $RequestedIndex not found. Available indexes: $($images.ImageIndex -join ', ')."
        }
        Write-BuildLog "  Using requested edition index ${RequestedIndex}: $($match.ImageName)" -Level SUCCESS
        return $match
    }

    # Interactive selection ($input is a reserved PS variable — use $userInput)
    do {
        $userInput = Read-Host "  Enter the edition index to install (or press Enter for index 1)"
        if ([string]::IsNullOrWhiteSpace($userInput)) { $userInput = '1' }
        $chosen = $images | Where-Object { $_.ImageIndex -eq [int]$userInput }
        if (-not $chosen) {
            Write-BuildLog "  Invalid index '$userInput'. Please choose from: $($images.ImageIndex -join ', ')" -Level WARN
        }
    } until ($chosen)

    Write-BuildLog "  Selected: [$($chosen.ImageIndex)] $($chosen.ImageName)" -Level SUCCESS
    return $chosen
}

#endregion

#region Unattend XML Generation

function New-WindowsUnattendXml {
    <#
    .SYNOPSIS
        Generates a Windows Setup answer file (unattend.xml) that suppresses OOBE,
        creates a local admin account, and auto-runs SetupComplete.cmd.
    #>
    param(
        [string]$ComputerName,
        [string]$AdminUsername,
        [string]$EncodedPassword,   # Base64-encoded for unattend (PlainText=false)
        [string]$ImageVersion       # e.g. "10.0.22621.1" : used to detect Server 2012 R2 (6.3.x)
    )

    # Detect if this is a pre-Win10 image (e.g. Server 2012 R2 = 6.3.x)
    $isLegacy = $ImageVersion -and $ImageVersion.StartsWith('6.')

    # On legacy Server (2012 R2), some modern OOBE elements don't exist
    $modernOOBE = if ($isLegacy) { '' } else {
        '          <HideOnlineAccountScreens>true</HideOnlineAccountScreens>'
    }

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

  <!-- specialize pass: runs once after hardware detection, before OOBE -->
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>

    <!-- Prevent Windows Update from running during first boot -->
    <component name="Microsoft-Windows-WindowsUpdate-AU"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <NoAutoUpdate>true</NoAutoUpdate>
    </component>
  </settings>

  <!-- oobeSystem pass: runs during OOBE : suppressed entirely -->
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
$modernOOBE
      </OOBE>

      <!-- Create local administrator account -->
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$AdminUsername</Name>
            <DisplayName>$AdminUsername</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>$EncodedPassword</Value>
              <PlainText>false</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>

      <!-- Auto-logon once so SetupComplete.cmd can run in user context as fallback -->
      <AutoLogon>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>$AdminUsername</Username>
        <Password>
          <Value>$EncodedPassword</Value>
          <PlainText>false</PlainText>
        </Password>
      </AutoLogon>

    </component>
  </settings>

</unattend>
"@

    return $xml
}

function New-SysprepUnattendXml {
    <#
    .SYNOPSIS
        Generates a sysprep answer file placed at C:\Windows\System32\Sysprep\unattend.xml
        in the base VHDX.  When sysprep generalises the image it caches this file into
        Panther so every clone picks it up automatically on first boot.
        Suppresses OOBE, creates the local admin account with persistent auto-logon, and
        runs Configure-Clone.ps1 via FirstLogonCommands to disable Defender / Firewall
        and enable WinRM + CredSSP.
        Compatible: Server 2012 -> Server 2025, Windows 10, Windows 11.
    #>
    param(
        [string]$AdminUsername,
        [string]$EncodedPassword,
        [string]$ImageVersion = ''   # e.g. "10.0.22621.1" - used to exclude Win11-only OOBE elements on legacy OS
    )

    # Server 2012 / 2012 R2 report version 6.2.x / 6.3.x.
    # HideOnlineAccountScreens does not exist on these and causes Setup to fail.
    $isLegacy   = $ImageVersion -and $ImageVersion.StartsWith('6.')
    $modernOOBE = if ($isLegacy) { '' } else {
        '          <HideOnlineAccountScreens>true</HideOnlineAccountScreens>'
    }

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

  <!--
    Sysprep answer file for cloned Windows images.
    Place at C:\Windows\System32\Sysprep\unattend.xml in the base VHDX before
    running sysprep.  Sysprep caches it into Panther; every clone uses it on
    first boot.

    On first boot the clone will:
      - Suppress the OOBE / login screen
      - Create the local admin account with persistent auto-logon
      - Run Configure-Clone.ps1 (Disable Defender, Firewall; Enable WinRM, CredSSP)

    Compatible: Server 2012 -> Server 2025 / Windows 10 / Windows 11
  -->

  <!-- specialize: runs once after hardware detection, before OOBE -->
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <!-- * instructs Setup to generate a unique random computer name per clone -->
      <ComputerName>*</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>

    <component name="Microsoft-Windows-WindowsUpdate-AU"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <NoAutoUpdate>true</NoAutoUpdate>
    </component>
  </settings>

  <!-- oobeSystem: suppress OOBE, create account, auto-logon, run config script -->
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">

      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
$modernOOBE
      </OOBE>

      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$AdminUsername</Name>
            <DisplayName>$AdminUsername</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>$EncodedPassword</Value>
              <PlainText>false</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>

      <!-- Persistent auto-logon: high count means the login screen is bypassed
           on every subsequent boot, not just the first one. -->
      <AutoLogon>
        <Enabled>true</Enabled>
        <LogonCount>9999</LogonCount>
        <Username>$AdminUsername</Username>
        <Password>
          <Value>$EncodedPassword</Value>
          <PlainText>false</PlainText>
        </Password>
      </AutoLogon>

      <!-- Runs synchronously before the desktop is shown; elevated via Setup context -->
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell.exe -ExecutionPolicy Bypass -NonInteractive -NoProfile -WindowStyle Hidden -File "C:\BaseImageSetup\Configure-Clone.ps1"</CommandLine>
          <Description>Disable Defender and Firewall; enable WinRM and CredSSP</Description>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>

    </component>
  </settings>

</unattend>
"@
    return $xml
}

#endregion

#region VHDX Creation and Partitioning

function New-WindowsVHDX {
    <#
    .SYNOPSIS
        Creates a new dynamic VHDX, mounts it, initialises GPT, creates the three
        required partitions (EFI/MSR/Windows), formats them, and returns a hashtable
        with the disk number and assigned drive letters.

        All disk operations are gated by Protect-HostDisk to ensure the host OS
        is never touched.
    #>
    param(
        [string]$VHDXPath,
        [long]  $SizeBytes
    )

    Write-BuildLog "Creating VHDX: $VHDXPath ($([math]::Round($SizeBytes/1GB,1)) GB)" -Level STEP

    # Create the VHDX file
    try {
        $vhd = New-VHD -Path $VHDXPath -SizeBytes $SizeBytes -Dynamic -ErrorAction Stop
        Write-BuildLog "  VHDX created: $VHDXPath" -Level SUCCESS
    } catch {
        throw "Failed to create VHDX at '$VHDXPath'. Error: $($_.Exception.Message)"
    }

    # Mount the VHDX
    Write-BuildLog '  Mounting VHDX...' -Level INFO
    try {
        $mountedVHD = Mount-VHD -Path $VHDXPath -PassThru -ErrorAction Stop
        $diskNumber  = $mountedVHD.DiskNumber
        Write-BuildLog "  Mounted as disk $diskNumber" -Level SUCCESS
    } catch {
        throw "Failed to mount VHDX '$VHDXPath'. Error: $($_.Exception.Message)"
    }

    # Safety check : must not be a host OS disk
    Protect-HostDisk -DiskNumber $diskNumber

    # Bring the disk online if needed
    $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
    if ($disk.OperationalStatus -eq 'Offline') {
        Set-Disk -Number $diskNumber -IsOffline $false -ErrorAction Stop
        Write-BuildLog "  Disk $diskNumber brought online" -Level INFO
    }
    if ($disk.IsReadOnly) {
        Set-Disk -Number $diskNumber -IsReadOnly $false -ErrorAction Stop
        Write-BuildLog "  Disk $diskNumber set read-write" -Level INFO
    }

    # Cross-reference: confirm the disk number matches what Get-VHD reports for
    # our specific VHDX path. Guards against race conditions.
    $vhdCrossCheck = Get-VHD -Path $VHDXPath -ErrorAction SilentlyContinue
    if ($vhdCrossCheck -and $vhdCrossCheck.DiskNumber -ne $diskNumber) {
        throw "SAFETY ABORT: Disk number mismatch. Mount-VHD returned disk $diskNumber but Get-VHD reports disk $($vhdCrossCheck.DiskNumber) for '$VHDXPath'. Refusing to proceed."
    }
    Write-BuildLog "  VHD path cross-reference confirmed: disk $diskNumber maps to '$VHDXPath'" -Level INFO

    # Only pre-allocate a letter for the Windows partition.
    # The EFI partition does NOT get a drive letter - Windows blocks letter
    # assignment to EFI System Partitions via VDS even when the letter is free.
    # Instead we retrieve the EFI volume GUID after diskpart and use a temp
    # directory mount point for bcdboot.
    $winLetter = Get-AvailableDriveLetter
    Write-BuildLog "  Windows partition drive letter: $winLetter" -Level INFO

    # Cleanup helper: releases the Windows drive letter if something fails.
    function Remove-PlannedDriveLetters {
        Write-BuildLog "  Releasing Windows drive letter $winLetter from VHDX disk $diskNumber..." -Level INFO
        $dpFile = Join-Path $env:TEMP "dp_cleanup_$(Get-Random).txt"
        @(
            "select disk $diskNumber",
            'select partition 1', 'remove all noerr',
            'select partition 2', 'remove all noerr',
            'select partition 3', 'remove all noerr',
            'exit'
        ) -join "`r`n" | Out-File -FilePath $dpFile -Encoding ASCII -Force
        & diskpart /s $dpFile | Out-Null
        Remove-Item $dpFile -Force -ErrorAction SilentlyContinue

        $vdsOut = & mountvol "${winLetter}:\" /L 2>&1
        if ($LASTEXITCODE -eq 0) {
            $ownerDisk = (Get-Volume -DriveLetter $winLetter -ErrorAction SilentlyContinue |
                          Get-Partition -ErrorAction SilentlyContinue |
                          Select-Object -First 1).DiskNumber
            if ($null -eq $ownerDisk -or $ownerDisk -eq $diskNumber) {
                & mountvol "${winLetter}:\" /D 2>&1 | Out-Null
                Write-BuildLog "  Released ${winLetter}: via mountvol" -Level INFO
            } else {
                Write-BuildLog "  SAFETY: ${winLetter}: belongs to disk $ownerDisk not VHDX disk $diskNumber - skipping." -Level WARN
            }
        }
        Write-BuildLog "  Drive letter cleanup complete." -Level INFO
    }

    # Single diskpart session: GPT init + all partitions + format.
    # EFI gets NO letter assignment - VDS policy blocks it. The volume GUID
    # is retrieved afterward and used with a temp directory mount for bcdboot.
    Write-BuildLog '  Partitioning and formatting VHDX via diskpart...' -Level INFO

    $dpFile = Join-Path $env:TEMP "dp_$(Get-Random).txt"
    @(
        "select disk $diskNumber",
        'clean',
        'convert gpt',
        'create partition efi size=500',
        'format fs=fat32 label=EFI quick',
        'create partition msr size=16',
        'create partition primary',
        'format fs=ntfs label=Windows quick',
        'remove all noerr',
        "assign letter=$winLetter",
        'exit'
    ) -join "`r`n" | Out-File -FilePath $dpFile -Encoding ASCII -Force

    $dpOut  = & diskpart /s $dpFile
    $dpExit = $LASTEXITCODE
    Remove-Item $dpFile -Force -ErrorAction SilentlyContinue
    $dpOut | ForEach-Object { Write-BuildLog "  [diskpart] $_" -Level INFO }

    if ($dpExit -ne 0) {
        Remove-PlannedDriveLetters
        throw "diskpart partitioning failed (exit code $dpExit). See diskpart output above."
    }

    Start-Sleep -Seconds 2

    # Verify Windows letter is accessible
    if (-not (Test-Path "${winLetter}:\")) {
        Remove-PlannedDriveLetters
        throw "Windows partition ${winLetter}: not accessible after diskpart. Check diskpart output above."
    }

    # Retrieve EFI volume GUID - used with a temp directory mount for bcdboot
    $allParts   = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue
    $efiPart    = $allParts | Where-Object { $_.Type -eq 'System' } | Select-Object -First 1
    $winPart    = $allParts | Where-Object { $_.Type -eq 'Basic'  } | Select-Object -First 1
    $efiPartNum = if ($efiPart) { $efiPart.PartitionNumber } else { 1 }
    $winPartNum = if ($winPart) { $winPart.PartitionNumber } else { 3 }

    $efiVolumeId = ($efiPart | Get-Volume -ErrorAction SilentlyContinue).UniqueId
    if (-not $efiVolumeId) {
        throw "Could not retrieve EFI volume GUID from disk $diskNumber partition $efiPartNum. Cannot proceed with bcdboot setup."
    }

    Write-BuildLog "  Partitioning complete. Windows=${winLetter}:, EFI volume GUID: $efiVolumeId" -Level SUCCESS

    return @{
        DiskNumber        = $diskNumber
        EFIVolumeId       = $efiVolumeId   # volume GUID used with temp dir mount for bcdboot
        EFIPartNumber     = $efiPartNum
        WindowsLetter     = $winLetter
        WindowsPartNumber = $winPartNum
    }
}

#endregion

#region DISM Apply

function Invoke-DISMImageApply {
    <#
    .SYNOPSIS
        Applies a WIM image at the given index to the target drive letter using DISM.
    #>
    param(
        [string]$WIMPath,
        [int]   $ImageIndex,
        [string]$TargetDriveLetter   # e.g. 'W'
    )

    $applyDir = "$TargetDriveLetter`:\"
    Write-BuildLog "Applying WIM index $ImageIndex to $applyDir (this takes several minutes)..." -Level STEP
    Write-BuildLog "  Source: $WIMPath"

    $dismArgs = @(
        '/Apply-Image',
        "/ImageFile:`"$WIMPath`"",
        "/Index:$ImageIndex",
        "/ApplyDir:$applyDir",
        '/CheckIntegrity'
    )

    Write-BuildLog "  Running: dism $($dismArgs -join ' ')" -Level INFO

    $result   = & "$env:SystemRoot\System32\dism.exe" @dismArgs 2>&1
    $exitCode = $LASTEXITCODE

    # Print DISM output for diagnostics (filter noise)
    $result | Where-Object { $_ -match '\S' } | ForEach-Object { Write-BuildLog "  [dism] $_" -Level INFO }

    if ($exitCode -ne 0) {
        $nl = [Environment]::NewLine
        throw ('DISM /Apply-Image failed (exit code {0}).{1}Target: {2}{1}Source: {3} index {4}{1}See DISM output above.' -f $exitCode, $nl, $applyDir, $WIMPath, $ImageIndex)
    }

    # Verify Windows directory was created
    $winDir = Join-Path $applyDir 'Windows'
    if (-not (Test-Path $winDir)) {
        throw "DISM reported success but '$winDir' does not exist. The apply may have failed silently."
    }

    Write-BuildLog "  DISM apply complete. Windows directory confirmed at $winDir" -Level SUCCESS
}

#endregion

#region BCDBoot

function Invoke-BCDBootSetup {
    <#
    .SYNOPSIS
        Mounts the EFI partition via its volume GUID to a temp directory,
        runs bcdboot.exe to write boot files, then unmounts. Using a temp
        directory avoids drive letter assignment conflicts with EFI partitions.
    #>
    param(
        [string]$WindowsLetter,   # Drive letter of the applied Windows partition
        [string]$EFIVolumeId      # Volume GUID e.g. \\?\Volume{xxxxxxxx-...}\
    )

    $windowsPath = "$WindowsLetter`:\Windows"

    Write-BuildLog "Running bcdboot to make VHDX bootable (UEFI)..." -Level STEP
    Write-BuildLog "  Windows path  : $windowsPath"
    Write-BuildLog "  EFI volume ID : $EFIVolumeId"

    if (-not (Test-Path $windowsPath)) {
        throw "bcdboot cannot proceed: Windows directory not found at '$windowsPath'."
    }

    # Mount EFI volume to a temp directory (avoids VDS letter-assignment policy for ESP)
    $efiTempDir = Join-Path $env:TEMP "efi_mount_$(Get-Random)"
    New-Item -ItemType Directory -Path $efiTempDir -Force -ErrorAction Stop | Out-Null
    Write-BuildLog "  Mounting EFI volume to temp dir: $efiTempDir" -Level INFO

    try {
        $mvOut = & mountvol $efiTempDir $EFIVolumeId 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "mountvol failed to mount EFI volume (exit $LASTEXITCODE): $mvOut"
        }
        Write-BuildLog "  EFI volume mounted at $efiTempDir" -Level SUCCESS

        $bcdbootExe  = Join-Path $env:SystemRoot 'System32\bcdboot.exe'
        $bcdbootArgs = @($windowsPath, '/s', $efiTempDir, '/f', 'UEFI', '/l', 'en-US')
        Write-BuildLog "  Running: bcdboot $($bcdbootArgs -join ' ')" -Level INFO

        $result   = & $bcdbootExe @bcdbootArgs 2>&1
        $exitCode = $LASTEXITCODE
        $result | ForEach-Object { Write-BuildLog "  [bcdboot] $_" -Level INFO }

        if ($exitCode -ne 0) {
            throw ('bcdboot.exe failed (exit code {0}).{1}See output above.' -f $exitCode, [Environment]::NewLine)
        }

        # Confirm boot files were written
        $bootMgr = Get-ChildItem -Path $efiTempDir -Recurse -Filter 'bootmgfw.efi' -ErrorAction SilentlyContinue
        if (-not $bootMgr) {
            Write-BuildLog "  WARNING: bootmgfw.efi not found on EFI partition after bcdboot. Boot may fail." -Level WARN
        } else {
            Write-BuildLog "  Boot file confirmed: $($bootMgr.FullName)" -Level SUCCESS
        }

        Write-BuildLog "  bcdboot completed." -Level SUCCESS

    } finally {
        # Always unmount the temp dir
        & mountvol $efiTempDir /D 2>&1 | Out-Null
        Remove-Item $efiTempDir -Force -ErrorAction SilentlyContinue
        Write-BuildLog "  EFI temp mount cleaned up." -Level INFO
    }
}

#endregion

#region Guest Script Injection

function Install-WindowsGuestScripts {
    <#
    .SYNOPSIS
        Injects the guest configuration scripts (SetupComplete.cmd, Configure-BaseImage.ps1,
        Configure-Clone.ps1, and both unattend.xml files) into the mounted Windows VHDX partition.
    #>
    param(
        [string]$WindowsLetter,
        [string]$AdminUsername,
        [System.Security.SecureString]$AdminPassword,
        [string]$ComputerName,
        [string]$ImageVersion
    )

    Write-BuildLog 'Injecting guest scripts into VHDX...' -Level STEP

    $setupScriptDir  = "$WindowsLetter`:\Windows\Setup\Scripts"
    $baseImageSetup  = "$WindowsLetter`:\BaseImageSetup"
    $pantherDir      = "$WindowsLetter`:\Windows\Panther"
    $guestScriptsDir = Join-Path $PSScriptRoot '..\GuestScripts'

    # Resolve guest scripts directory relative to this file (PS5.1-compatible, no ?. operator)
    $resolvedGuest = Resolve-Path (Join-Path $PSScriptRoot '..\GuestScripts') -ErrorAction SilentlyContinue
    if ($resolvedGuest) {
        $guestScriptsDir = $resolvedGuest.Path
    } else {
        $guestScriptsDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'GuestScripts'
    }

    Write-BuildLog "  Guest scripts source: $guestScriptsDir" -Level INFO

    # Create target directories
    foreach ($dir in @($setupScriptDir, $baseImageSetup, $pantherDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            Write-BuildLog "  Created: $dir"
        }
    }

    # Copy SetupComplete.cmd
    $setupCompleteSrc = Join-Path $guestScriptsDir 'SetupComplete.cmd'
    if (-not (Test-Path $setupCompleteSrc)) {
        throw "SetupComplete.cmd not found at '$setupCompleteSrc'. Ensure GuestScripts folder is present."
    }
    Copy-Item -Path $setupCompleteSrc -Destination "$setupScriptDir\SetupComplete.cmd" -Force -ErrorAction Stop
    Write-BuildLog "  Copied: SetupComplete.cmd -> $setupScriptDir"

    # Copy Configure-BaseImage.ps1
    $configureScriptSrc = Join-Path $guestScriptsDir 'Configure-BaseImage.ps1'
    if (-not (Test-Path $configureScriptSrc)) {
        throw "Configure-BaseImage.ps1 not found at '$configureScriptSrc'. Ensure GuestScripts folder is present."
    }
    Copy-Item -Path $configureScriptSrc -Destination "$baseImageSetup\Configure-BaseImage.ps1" -Force -ErrorAction Stop
    Write-BuildLog "  Copied: Configure-BaseImage.ps1 -> $baseImageSetup"

    # Copy Configure-Clone.ps1 (used by sysprep unattend FirstLogonCommands on clone boot)
    $cloneScriptSrc = Join-Path $guestScriptsDir 'Configure-Clone.ps1'
    if (-not (Test-Path $cloneScriptSrc)) {
        throw "Configure-Clone.ps1 not found at '$cloneScriptSrc'. Ensure GuestScripts folder is present."
    }
    Copy-Item -Path $cloneScriptSrc -Destination "$baseImageSetup\Configure-Clone.ps1" -Force -ErrorAction Stop
    Write-BuildLog "  Copied: Configure-Clone.ps1 -> $baseImageSetup"

    # Generate and write the initial-setup unattend.xml (Panther - runs during first OOBE)
    $encodedPw   = ConvertTo-UnattendPassword -SecurePassword $AdminPassword
    $unattendXml = New-WindowsUnattendXml `
        -ComputerName    $ComputerName `
        -AdminUsername   $AdminUsername `
        -EncodedPassword $encodedPw `
        -ImageVersion    $ImageVersion
    $unattendPath = "$pantherDir\unattend.xml"
    [System.IO.File]::WriteAllText($unattendPath, $unattendXml, [System.Text.Encoding]::UTF8)
    Write-BuildLog "  Written: unattend.xml (initial OOBE) -> $unattendPath" -Level SUCCESS

    # Generate and write the sysprep unattend (C:\Windows\System32\Sysprep\unattend.xml).
    # Sysprep caches this into Panther when it generalises the image so every clone
    # picks it up on first boot: suppresses OOBE, auto-logs on, runs Configure-Clone.ps1.
    $sysprepDir = "$WindowsLetter`:\Windows\System32\Sysprep"
    if (-not (Test-Path $sysprepDir)) {
        New-Item -ItemType Directory -Path $sysprepDir -Force -ErrorAction Stop | Out-Null
        Write-BuildLog "  Created: $sysprepDir"
    }
    $sysprepUnattendXml = New-SysprepUnattendXml `
        -AdminUsername   $AdminUsername `
        -EncodedPassword $encodedPw `
        -ImageVersion    $ImageVersion
    $sysprepUnattendPath = "$sysprepDir\unattend.xml"
    [System.IO.File]::WriteAllText($sysprepUnattendPath, $sysprepUnattendXml, [System.Text.Encoding]::UTF8)
    Write-BuildLog "  Written: unattend.xml (sysprep/clone) -> $sysprepUnattendPath" -Level SUCCESS

    Write-BuildLog '  Guest script injection complete.' -Level SUCCESS
}

#endregion

#region Temp VM (Windows)

function Invoke-WindowsTempVM {
    <#
    .SYNOPSIS
        Creates a temporary Hyper-V VM, attaches the VHDX, starts it, waits for
        it to shut down (Sysprep triggers shutdown), then removes the VM.
        The VHDX file itself is preserved.
    #>
    param(
        [string]$VMName,
        [string]$VHDXPath,
        [int]   $CPUCount,
        [long]  $MemoryBytes,
        [int]   $TimeoutMinutes = 90
    )

    Write-BuildLog "Creating temporary Hyper-V VM: '$VMName'" -Level STEP

    # Abort if a VM with this name already exists
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "A VM named '$VMName' already exists. Remove it first or choose a different -TempVMName."
    }

    $vm = $null
    try {
        # Create Generation 2 VM (UEFI)
        $vm = New-VM -Name $VMName `
                     -Generation 2 `
                     -MemoryStartupBytes $MemoryBytes `
                     -NoVHD `
                     -ErrorAction Stop
        Write-BuildLog "  VM '$VMName' created (Gen2)" -Level SUCCESS

        # CPU
        Set-VMProcessor -VMName $VMName -Count $CPUCount -ErrorAction Stop
        Write-BuildLog "  CPU count: $CPUCount"

        # Disable dynamic memory for predictable builds
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -ErrorAction Stop
        Write-BuildLog "  Memory: $([math]::Round($MemoryBytes/1GB,1)) GB (static)"

        # Attach VHDX as boot device
        Add-VMHardDiskDrive -VMName $VMName -Path $VHDXPath -ControllerType SCSI -ErrorAction Stop
        Write-BuildLog "  Attached VHDX: $VHDXPath"

        # Set boot order to VHDX first
        $vmDrive  = Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop
        $bootDisk = Get-VMFirmware -VMName $VMName | Select-Object -ExpandProperty BootOrder |
                    Where-Object { $_.BootType -eq 'Drive' -and $_.Device.Path -eq $VHDXPath } |
                    Select-Object -First 1
        if ($bootDisk) {
            Set-VMFirmware -VMName $VMName -FirstBootDevice $bootDisk -ErrorAction Stop
            Write-BuildLog '  Boot order: VHDX first'
        } else {
            Write-BuildLog '  Could not set explicit boot order : VM will use default (usually VHDX if only drive attached)' -Level WARN
        }

        # Disable Secure Boot (needed for some guest OS configurations; unattend handles setup)
        Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows' -ErrorAction SilentlyContinue
        Write-BuildLog '  Secure Boot: On (MicrosoftWindows template)'

        # Checkpoint disabled : this is a disposable build VM
        Set-VM -VMName $VMName -CheckpointType Disabled -ErrorAction Stop

        # Prevent Hyper-V from auto-restarting the VM after sysprep shuts it down.
        # Without this, if the host had a previous start action set, the VM can come
        # back up before Wait-VMShutdown polls, causing the sysprep unattend to fire
        # on the base image itself.
        Set-VM -VMName $VMName -AutomaticStartAction Nothing -ErrorAction SilentlyContinue
        Write-BuildLog '  Automatic start action: Nothing'

        # Start the VM
        Write-BuildLog "Starting VM '$VMName'..." -Level STEP
        Start-VM -Name $VMName -ErrorAction Stop
        Write-BuildLog "  VM started. Windows is now running setup + sysprep." -Level SUCCESS
        Write-BuildLog "  Expected sequence inside VM: specialize -> OOBE (suppressed) -> SetupComplete.cmd -> Configure-BaseImage.ps1 (validates unattend, runs sysprep) -> shutdown"
        Write-BuildLog "  Monitor progress in Hyper-V Manager if needed (VM console shows the Windows boot screen)."

        # Wait for VM to shut down (Sysprep will trigger this)
        Wait-VMShutdown -VMName $VMName -TimeoutMinutes $TimeoutMinutes

    } catch {
        Write-BuildLog "Error during temp VM operation for '$VMName': $($_.Exception.Message)" -Level ERROR

        # Attempt to stop the VM before cleanup
        if ($vm) {
            Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        # Always remove the temp VM (not the VHDX)
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
            Write-BuildLog "  Removing temp VM '$VMName'..." -Level INFO
            Remove-VM -Name $VMName -Force -ErrorAction SilentlyContinue
            Write-BuildLog "  Temp VM removed." -Level SUCCESS
        }
    }
}

#endregion

#region Main Windows Build Orchestration

function Invoke-WindowsBuild {
    <#
    .SYNOPSIS
        Full orchestration of the Windows ISO -> generalized VHDX pipeline.
    #>
    param(
        [string]$ISOPath,
        [string]$OutputVHDXPath,
        [long]  $SizeBytes,
        [string]$AdminUsername,
        [System.Security.SecureString]$AdminPassword,
        [string]$Hostname,
        [int]   $WindowsEditionIndex,
        [string]$TempVMName,
        [int]   $CPUCount,
        [long]  $MemoryBytes
    )

    Write-BuildLog '================================================================' -Level STEP
    Write-BuildLog ' Windows Build Pipeline Starting' -Level STEP
    Write-BuildLog "  ISO              : $ISOPath" -Level STEP
    Write-BuildLog "  Output VHDX      : $OutputVHDXPath" -Level STEP
    Write-BuildLog "  Hostname (temp)  : $Hostname" -Level STEP
    Write-BuildLog "  Admin user       : $AdminUsername" -Level STEP
    Write-BuildLog "  VHDX size        : $([math]::Round($SizeBytes/1GB,1)) GB" -Level STEP
    Write-BuildLog '================================================================' -Level STEP

    $tempDir    = $null
    $isoMounted = $false
    $vhdxPath   = $OutputVHDXPath
    $diskInfo   = $null

    try {

        # ---- 1. Create temp working directory ----
        $tempDir = New-Item -ItemType Directory `
                             -Path (Join-Path $env:TEMP "WinBuild-$(Get-Date -Format 'yyyyMMdd-HHmmss')") `
                             -Force -ErrorAction Stop
        Write-BuildLog "Temp directory: $($tempDir.FullName)" -Level INFO

        # ---- 2. Mount ISO ----
        Write-BuildLog "Mounting ISO: $ISOPath" -Level STEP
        $mount = Mount-DiskImage -ImagePath $ISOPath -PassThru -ErrorAction Stop
        $isoMounted = $true
        Start-Sleep -Seconds 2   # brief pause for drive letter assignment

        $isoDrive = ($mount | Get-Volume -ErrorAction Stop).DriveLetter + ':'
        if (-not $isoDrive -or $isoDrive -eq ':') {
            throw "Could not determine drive letter of mounted ISO '$ISOPath'."
        }
        Write-BuildLog "  ISO mounted at $isoDrive" -Level SUCCESS

        # ---- 3. Locate WIM/ESD ----
        Write-BuildLog 'Locating installation image (WIM/ESD)...' -Level STEP
        $wimInfo = Get-ISOWIMPath -DriveLetter $isoDrive

        $wimPath    = $wimInfo.Path
        $tempWimPath = $null

        # If ESD, we must export to WIM for the edition selection step first
        if ($wimInfo.IsESD) {
            Write-BuildLog 'ESD detected : querying indexes before export...' -Level INFO
            $edition    = Select-WindowsEdition -ImageFile $wimPath -RequestedIndex $WindowsEditionIndex
            Write-BuildLog "Exporting selected index $($edition.ImageIndex) from ESD to temp WIM..." -Level STEP
            $tempWimPath = Export-ESDtoWIM -ESDPath $wimPath -ImageIndex $edition.ImageIndex -TempDir $tempDir.FullName
            $wimPath     = $tempWimPath
            $selectedIndex = 1   # exported WIM always has index 1
        } else {
            $edition       = Select-WindowsEdition -ImageFile $wimPath -RequestedIndex $WindowsEditionIndex
            $selectedIndex = $edition.ImageIndex
        }

        $versionProp  = $edition.PSObject.Properties['ImageVersion']
        $imageVersion = if ($versionProp -and $versionProp.Value) { $versionProp.Value } else { 'unknown' }
        Write-BuildLog "  Edition: $($edition.ImageName) (index $selectedIndex, version $imageVersion)" -Level SUCCESS

        # ---- 4. Create and partition VHDX ----
        $diskInfo = New-WindowsVHDX -VHDXPath $vhdxPath -SizeBytes $SizeBytes

        # ---- 5. Apply WIM ----
        Invoke-DISMImageApply -WIMPath $wimPath -ImageIndex $selectedIndex -TargetDriveLetter $diskInfo.WindowsLetter

        # ---- 6. Inject guest scripts ----
        Install-WindowsGuestScripts `
            -WindowsLetter $diskInfo.WindowsLetter `
            -AdminUsername $AdminUsername `
            -AdminPassword $AdminPassword `
            -ComputerName  $Hostname `
            -ImageVersion  $imageVersion

        # ---- 7. Make bootable ----
        Invoke-BCDBootSetup -WindowsLetter $diskInfo.WindowsLetter -EFIVolumeId $diskInfo.EFIVolumeId

        # ---- 8. Unmount Windows drive letter from VHDX (EFI has no letter to remove) ----
        Write-BuildLog 'Removing Windows drive letter from VHDX before dismount...' -Level STEP

        Remove-PartitionAccessPath -DiskNumber $diskInfo.DiskNumber `
                                    -PartitionNumber $diskInfo.WindowsPartNumber `
                                    -AccessPath "$($diskInfo.WindowsLetter)`:\" `
                                    -ErrorAction SilentlyContinue
        Write-BuildLog '  Windows drive letter removed.' -Level SUCCESS

        # ---- 9. Dismount VHDX ----
        Write-BuildLog 'Dismounting VHDX...' -Level INFO
        Dismount-VHD -Path $vhdxPath -ErrorAction Stop
        Write-BuildLog '  VHDX dismounted.' -Level SUCCESS
        $diskInfo = $null   # no longer mounted

        # ---- 10. Dismount ISO ----
        Write-BuildLog 'Dismounting ISO...' -Level INFO
        Dismount-DiskImage -ImagePath $ISOPath -ErrorAction Stop | Out-Null
        $isoMounted = $false
        Write-BuildLog '  ISO dismounted.' -Level SUCCESS

        # ---- 11. Clean up exported WIM ----
        if ($tempWimPath -and (Test-Path $tempWimPath)) {
            Remove-Item $tempWimPath -Force -ErrorAction SilentlyContinue
            Write-BuildLog '  Temp WIM deleted.' -Level INFO
        }

        # ---- 12. Boot temp VM, wait for Sysprep ----
        Invoke-WindowsTempVM `
            -VMName         $TempVMName `
            -VHDXPath       $vhdxPath `
            -CPUCount       $CPUCount `
            -MemoryBytes    $MemoryBytes `
            -TimeoutMinutes 90

        # ---- Done ----
        Write-BuildLog '' -Level SUCCESS
        Write-BuildLog '================================================================' -Level SUCCESS
        Write-BuildLog ' Windows Build Complete' -Level SUCCESS
        Write-BuildLog "  Output VHDX: $vhdxPath" -Level SUCCESS
        Write-BuildLog "  The VHDX has been generalised with Sysprep and is ready for cloning." -Level SUCCESS
        Write-BuildLog '================================================================' -Level SUCCESS

    } catch {
        Write-BuildLog 'Windows build pipeline FAILED.' -Level ERROR
        Write-BuildLog "  Error: $($_.Exception.Message)" -Level ERROR

        # Best-effort cleanup of VHDX mounts (EFI has no drive letter to remove)
        if ($diskInfo) {
            Remove-PartitionAccessPath -DiskNumber $diskInfo.DiskNumber -PartitionNumber $diskInfo.WindowsPartNumber `
                                        -AccessPath "$($diskInfo.WindowsLetter)`:\" -ErrorAction SilentlyContinue
        }
        if (Test-Path $vhdxPath -ErrorAction SilentlyContinue) {
            Dismount-VHD -Path $vhdxPath -ErrorAction SilentlyContinue
        }
        if ($isoMounted) {
            Dismount-DiskImage -ImagePath $ISOPath -ErrorAction SilentlyContinue | Out-Null
        }
        throw
    } finally {
        # Always clean up temp directory
        if ($tempDir -and (Test-Path $tempDir.FullName)) {
            Remove-Item -Path $tempDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-BuildLog '  Temp directory cleaned up.' -Level INFO
        }
    }
}

#endregion
