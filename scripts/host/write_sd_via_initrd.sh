#!/bin/bash
# Write an SD image to the microSD inside the Jetson through the flashing initrd,
# then read it back and compare SHA-256. Run boot_initrd.sh first.
# Useful when the host has no working SD reader.
IMG=${1:-$HOME/jetson/sd-blob-35.6.5.img}
SSH="sshpass -p root ssh -q -o ServerAliveInterval=20 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@fc00:1:1:0::2"
SZ=$(stat -c %s "$IMG")
echo "start $(date +%T) bytes=$SZ"
sudo cat "$IMG" | $SSH "dd of=/dev/mmcblk1 bs=4M conv=fsync 2>&1 | tail -1; sync; blockdev --flushbufs /dev/mmcblk1; echo 3 > /proc/sys/vm/drop_caches"
L=$(sudo sha256sum "$IMG" | cut -d" " -f1)
R=$($SSH "head -c $SZ /dev/mmcblk1 | sha256sum | cut -d' ' -f1")
echo "local=$L"; echo "card =$R"
[ -n "$R" ] && [ "$L" = "$R" ] && echo VERIFIED_OK || echo VERIFICATION_FAILED
echo "end $(date +%T)"
