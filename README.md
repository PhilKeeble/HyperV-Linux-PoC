# HyperV Linux Automation POC

# Summary

This is a POC I made for automating a full linux install within HyperV for Ubuntu Server 24.04.1 LTS.

# Setup ISO

Before doing this you need an unattended install ISO. The only way I have tried so far is with WSL.

Download the Ubuntu Server Live 24.04.1 ISO. This seems to be quite version specific. I downloaded mine on the 17th January 2025 if you need to find the same version.

Head into WSL (I used ubuntu) and install the prerequisites (isolinux is uncertain if necessary).

```
sudo apt update
sudo apt install xorriso sed curl gpg 7zip isolinux
```

extract the iso and add the meta data files its expecting (still empty).

```
cd /tmp
mkdir -p iso/nocloud/
7z x ubuntu-24.04.1-live-server-amd64.iso -x'![BOOT]' -oiso
touch iso/nocloud/meta-data
```

Copy the `user-data` from this directory into userdata.

```
cp user-data iso/nocloud/user-data
```

You will then need to make edits to the grub loader to match the file contained in this repo as well.

```
cp grub.cfg iso/boot/grub/grub.cfg
```

Use xorriso to get a report of the ISO configuration (the one that was downloaded)

```
xorriso -indev ubuntu-24.04.1-live-server-amd64.iso -report_el_torito as_mkisofs
```

This will give you output such as below:

```
ubuntu@DESKTOP-EUDTLFT:/mnt/c/Users/Phil/Documents/VMs/test/iso$ xorriso -indev ../ubuntu-24.04.1-live-server-amd64.iso -report_el_torito as_mkisofs
xorriso 1.5.6 : RockRidge filesystem manipulator, libburnia project.

xorriso : NOTE : Loading ISO image tree from LBA 0
xorriso : UPDATE :    1065 nodes read in 1 seconds
libisofs: NOTE : Found hidden El-Torito image for EFI.
libisofs: NOTE : EFI image start and size: 1351729 * 2048 , 10144 * 512
xorriso : NOTE : Detected El-Torito boot information which currently is set to be discarded
Drive current: -indev '../ubuntu-24.04.1-live-server-amd64.iso'
Media current: stdio file, overwriteable
Media status : is written , is appendable
Boot record  : El Torito , MBR protective-msdos-label grub2-mbr cyl-align-off GPT
Media summary: 1 session, 1354431 data blocks, 2645m data, 1347g free
Volume id    : 'Ubuntu-Server 24.04.1 LTS amd64'
-V 'Ubuntu-Server 24.04.1 LTS amd64'
--modification-date='2024082715393700'
--grub2-mbr --interval:local_fs:0s-15s:zero_mbrpt,zero_gpt:'../ubuntu-24.04.1-live-server-amd64.iso'
--protective-msdos-label
-partition_cyl_align off
-partition_offset 16
--mbr-force-bootable
-append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b --interval:local_fs:5406916d-5417059d::'../ubuntu-24.04.1-live-server-amd64.iso'
-appended_part_as_gpt
-iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7
-c '/boot.catalog'
-b '/boot/grub/i386-pc/eltorito.img'
-no-emul-boot
-boot-load-size 4
-boot-info-table
--grub2-boot-info
-eltorito-alt-boot
-e '--interval:appended_partition_2_start_1351729s_size_10144d:all::'
-no-emul-boot
-boot-load-size 10144
```

These flags will inform the next command which you will need to modify for your own use. For me the working command was (executed from within the iso directory if you want the file paths to be the same):

```
xorriso -as mkisofs -f \
-V 'Ubuntu 24.04.1 LTS AUTOINSTALL' \
-o ../ubuntu-24.04.1-server-autoinstall-amd64.iso \
--grub2-mbr '../BOOT/1-Boot-NoEmul.img' \
--protective-msdos-label \
-partition_cyl_align off \
-partition_offset 16 \
--mbr-force-bootable \
-append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b '../BOOT/2-Boot-NoEmul.img' \
-appended_part_as_gpt \
-iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
-c '/boot.catalog' \
-b '/boot/grub/i386-pc/eltorito.img' \
-no-emul-boot \
-boot-load-size 4 \
-boot-info-table \
--grub2-boot-info \
-eltorito-alt-boot \
-e '--interval:appended_partition_2:::' \
-no-emul-boot \
-boot-load-size 10144 \
.
```

This should output the ISO which should be ready for the next steps.

# Setup HyperV

You obviously need Hyper V installed. You will also need the Posh-SSH module.

```
Install-Module -Name Posh-SSH
```

Then edit the variables inside the `Install-Linux.ps1` script to match your file paths for the various pieces. 

Then execute the script

```
.\Install-Linux.ps1
```

When it is complete you will see something like:

```
Output     : {}
ExitStatus : 0
Error      :
Host       : 172.25.102.50
Duration   : 00:00:00.3814776

True
```

This means it completed and HyperV was able to recover the IP and then SSH into the box and the file `~/whoami.txt` will be on the file system for the ubuntu user. The password for ubuntu is `ubuntu`.

There is also an example SCP command included and the packages can be managed through the autoinstall file, which should be enough to facilitate moving an ansible file over and running it to configure the Ubuntu box in a lab environment.