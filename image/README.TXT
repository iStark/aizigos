AIZigOS lives on this volume.

The kernel you booted is /EFI/BOOT/BOOTX64.EFI. It read this file back off the
same disk it was loaded from, through its own ATA driver and its own FAT32
reader, and printed it in the shell you are looking at.

Try: ls /, ls /EFI/BOOT, cat /README.TXT
