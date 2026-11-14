#!/bin/bash
# Full read, then 48 GiB write + read-back verification of an NVMe drive.
# DESTROYS THE DRIVE'S CONTENTS. Run as root. Log: ./nvme_test.log
L=${LOG:-$PWD/nvme_test.log}
exec > "$L" 2>&1
D=/dev/nvme0n1
echo "== start $(date +%T)"
echo "== 1 full read"
dd if=$D of=/dev/null bs=4M status=none; echo "rc=$? $(date +%T)"
echo "kernel errors: $(dmesg | grep -c -E 'frozen state|PCIe Bus Error|I/O error')"
echo "== 2 write 48 GiB of pseudo-random data and verify"
GEN() { openssl enc -aes-128-ctr -pass pass:nvme-test -nosalt -md sha256 < /dev/zero 2>/dev/null | head -c $((48*1024*1024*1024)); }
A=$(GEN | tee >(dd of=$D bs=4M oflag=direct iflag=fullblock status=none) | sha256sum | cut -d" " -f1)
sync; echo 3 > /proc/sys/vm/drop_caches; echo "written $(date +%T)"
B=$(dd if=$D bs=4M iflag=direct status=none | head -c $((48*1024*1024*1024)) | sha256sum | cut -d" " -f1)
echo "expected=$A"; echo "read    =$B"; [ "$A" = "$B" ] && echo VERIFIED_OK || echo VERIFICATION_FAILED
echo "kernel errors: $(dmesg | grep -c -E 'frozen state|PCIe Bus Error|I/O error')"
nvme smart-log /dev/nvme0 | grep -E "critical_warning|media_errors|num_err_log|^temperature"
echo "== end $(date +%T)"
