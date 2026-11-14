#!/bin/bash
# From the host, watch an NVMe drive inside the flashing initrd: controller state,
# reset count, AER errors and I/O errors, with a 256 MB test read on each pass.
# Run boot_initrd.sh first.
SSH="sshpass -p root ssh -q -o ConnectTimeout=4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@fc00:1:1:0::2"
for i in $(seq 1 40); do
  R=$($SSH 'printf "state=%s resets=%s aer=%s ioerr=%s" "$(cat /sys/class/nvme/nvme0/state 2>/dev/null)" "$(dmesg | grep -c "frozen state")" "$(dmesg | grep -c "PCIe Bus Error")" "$(dmesg | grep -c "I/O error")"' 2>/dev/null) || R="NO RESPONSE"
  echo "$(date +%T) $R"
  $SSH 'dd if=/dev/nvme0n1 of=/dev/null bs=1M count=256 skip='$((i*300))' 2>&1 | tail -1'
  sleep 8
done
