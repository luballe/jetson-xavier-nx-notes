#!/bin/bash
# Clone a running Jetson Xavier NX system from microSD (mmcblk0) to NVMe (nvme0n1),
# keeping NVIDIA's partition layout. ERASES THE NVMe DRIVE. Run as root from the
# system booted off the microSD. The microSD is not modified.
L=${LOG:-$PWD/migrate.log}
exec > "$L" 2>&1
set -e
S=/dev/mmcblk0; D=/dev/nvme0n1
echo "== start $(date +%T)"
[ "$(findmnt -no SOURCE /)" = "${S}p1" ] || { echo "root is not the microSD, aborting"; exit 1; }
blkdiscard $D
# Copy the GPT, move the backup header to the end of the bigger disk, new GUIDs.
sgdisk --backup=/tmp/sd.gpt $S
sgdisk --load-backup=/tmp/sd.gpt $D
sgdisk -e $D
sgdisk -G $D
# Recreate APP (partition 1) from the same start sector to the end of the disk.
START=$(sgdisk -i 1 $S | awk '/First sector/{print $3}')
sgdisk -d 1 $D
sgdisk -n 1:${START}:0 -c 1:APP -t 1:8300 $D
partprobe $D; sleep 3; udevadm settle
sgdisk -p $D
echo "== copying partitions 2..N $(date +%T)"
for i in $(sgdisk -p $S | awk '$1 ~ /^[0-9]+$/ && $1 != 1 {print $1}'); do
  dd if=${S}p$i of=${D}p$i bs=1M conv=fsync status=none
  a=$(sha256sum < ${S}p$i | cut -c1-16); b=$(sha256sum < ${D}p$i | cut -c1-16)
  [ "$a" = "$b" ] && echo "p$i ok" || { echo "p$i DIFFERS"; exit 1; }
done
echo "== root filesystem $(date +%T)"
mkfs.ext4 -F -q ${D}p1
mkdir -p /mnt/nvroot; mount ${D}p1 /mnt/nvroot
rsync -aAXHx --numeric-ids / /mnt/nvroot/
sync
rsync -aAXHx --numeric-ids / /mnt/nvroot/          # second pass for files that changed
U=$(blkid -s PARTUUID -o value ${D}p1)
cp -p /mnt/nvroot/boot/extlinux/extlinux.conf /mnt/nvroot/boot/extlinux/extlinux.conf.sd
sed -i "s|root=PARTUUID=[0-9a-f-]*|root=PARTUUID=$U|" /mnt/nvroot/boot/extlinux/extlinux.conf
grep APPEND /mnt/nvroot/boot/extlinux/extlinux.conf
echo "files: microSD=$(find / -xdev | wc -l) NVMe=$(find /mnt/nvroot -xdev | wc -l)"
ls -l /mnt/nvroot/sbin/init /mnt/nvroot/boot/Image /mnt/nvroot/boot/initrd
sync; umount /mnt/nvroot
e2fsck -fn ${D}p1 | tail -2
echo "kernel errors: $(dmesg | grep -c -E 'frozen state|PCIe Bus Error|I/O error')"
echo "== done $(date +%T)  (reboot; check with: findmnt -no SOURCE /)"
