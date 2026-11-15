#!/bin/bash
# Build a bootable microSD image of the running NVMe system (Jetson Xavier NX, JetPack 5 layout).
# Run with sudo -E on the Jetson, booted from the NVMe. OUT and APP_GIB can be set in the environment.
# Small partitions are copied as they are; the root filesystem is recreated at APP_GIB and filled with rsync.
set -eu
SRC=/dev/nvme0n1; OUT=${OUT:-$HOME/backup-img}; APP_GIB=${APP_GIB:-36}
IMG=$OUT/jetson-xavier-nx-$(date +%Y%m%d).img; LOG=$OUT/build.log
mkdir -p $OUT; exec > >(tee $LOG) 2>&1
echo "START $(date -Is)"
[ "$(findmnt -no SOURCE /)" = ${SRC}p1 ] || { echo "root is not the NVMe"; exit 1; }
APP_START=$(sgdisk -i 1 $SRC | awk '/First sector/{print $3}')
SECTORS=$(( APP_START + APP_GIB*1024*1024*2 + 2048 ))
rm -f $IMG; truncate -s $(( SECTORS*512 )) $IMG
LOOP=$(losetup --show -f -P $IMG); echo "loop $LOOP, $SECTORS sectors"
sgdisk -o $LOOP >/dev/null
for n in $(seq 2 22); do
  s=$(sgdisk -i $n $SRC | awk '/First sector/{print $3}'); e=$(sgdisk -i $n $SRC | awk '/Last sector/{print $3}')
  name=$(sgdisk -i $n $SRC | sed -n "s/^Partition name: '\(.*\)'/\1/p"); code=$(sgdisk -i $n $SRC | awk '/Partition GUID code/{print $4}')
  sgdisk -n $n:$s:$e -t $n:$code -c $n:"$name" $LOOP >/dev/null
done
sgdisk -n 1:$APP_START:0 -t 1:8300 -c 1:APP $LOOP >/dev/null
partprobe $LOOP; sleep 2
for n in $(seq 2 22); do dd if=${SRC}p$n of=${LOOP}p$n bs=4M status=none conv=fsync; cmp -s ${SRC}p$n ${LOOP}p$n || { echo "partition $n differs"; exit 1; }; done
echo "small partitions copied and verified"
mkfs.ext4 -q -F -L APP ${LOOP}p1
mkdir -p /mnt/img; mount ${LOOP}p1 /mnt/img
rsync -aHAXx --numeric-ids \
  --exclude '/tmp/*' --exclude '/var/tmp/*' --exclude '/var/cache/apt/archives/*.deb' \
  --exclude '/mnt/*' --exclude '/media/*' --exclude '/lost+found' --exclude "$OUT" \
  / /mnt/img/
NEW=$(sgdisk -i 1 $LOOP | awk '/Partition unique GUID/{print tolower($4)}')
OLD=$(sgdisk -i 1 $SRC | awk '/Partition unique GUID/{print tolower($4)}')
grep -q "root=PARTUUID=$OLD" /mnt/img/boot/extlinux/extlinux.conf || { echo "unexpected extlinux.conf"; exit 1; }
sed -i "s/root=PARTUUID=$OLD/root=PARTUUID=$NEW/" /mnt/img/boot/extlinux/extlinux.conf
echo "extlinux root entries pointing at the image: $(grep -c "root=PARTUUID=$NEW" /mnt/img/boot/extlinux/extlinux.conf)"
df -h /mnt/img | tail -1
sync; umount /mnt/img; e2fsck -fn ${LOOP}p1 | tail -1
sgdisk -v $LOOP | tail -2
losetup -d $LOOP
ls -ls $IMG | awk '{print "allocated KiB:",$1,"apparent bytes:",$6}'
sha256sum $IMG | tee $IMG.sha256
chown -R ${SUDO_USER:-root}: $OUT
echo "END $(date -Is)"; echo DONE > $OUT/build.done
