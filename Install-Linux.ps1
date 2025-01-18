# Requires the module posh-ssh / HyperV / unattended linux iso
# Install-Module -Name Posh-SSH

$vmname = "Ubuntu-Server-24.04"
$vmpath = "C:\Users\Phil\Documents\VMs\Ubuntu-Server-22.04"
$vhdxpath = "$vmpath\$vmname\Virtual Hard Disks\$vmname.vhdx"
$isopath = "C:\Users\Phil\Documents\VMs\test\ubuntu-24.04.1-server-autoinstall-amd64.iso"

# make vm
New-VM -Name $vmname -Path $vmpath -Generation 2 -MemoryStartupBytes 2GB  -SwitchName "Default Switch" 

# set secureboot to off for linux to boot
Set-VMFirmware -VMName $vmname -EnableSecureBoot Off

# make hard drive and attach it
New-VHD -Path $vhdxpath -SizeBytes 20GB -Dynamic -BlockSizeBytes 1MB
Add-VMHardDiskDrive -VMName $vmname -Path $vhdxpath

# make the dvd drive and attach it with the iso inside
Add-VMDvdDrive -VMName $vmname
Set-VMDvdDrive -VMName $vmname -Path $isopath

# set the boot order for dvd first
Set-VMFirmware -VMName $vmname -BootOrder $(Get-VMDvdDrive -VMName $vmname), $(Get-VMHardDiskDrive -VMName $vmname), $(Get-VMNetworkAdapter -VMName $vmname)

# disable checkpointing for space
Set-VM -Name $vmname -CheckpointType Disabled

# enable full services to host
Enable-VMIntegrationService -VMName $vmname -Name "Guest Service Interface"

# start the host 
Start-VM -Name $vmname

# wait for vm to install 
Start-Sleep -Seconds 300

# Get the IP of the instance
$ip = (get-vm -Name $vmname).NetworkAdapters.IPAddresses[0]

# set the credential object
$password = "ubuntu" | ConvertTo-SecureString -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("ubuntu",$password);

# create an ssh session
$sess = (New-SSHSession -Computername $ip -Credential $cred -AcceptKey).SessionId

# invoke commands to complete set up 
Invoke-SSHCommand -SessionId $sess -Command "whoami > ~/whoami.txt"

# can copy items over with scp as well for items like ansible configuration
#Set-SCPItem -Computername <ip> -Credential $cred -AcceptKey -Path <local> -Destination <remote> 

Remove-SSHSession -SessionId $sess