#!/bin/bash
# One log line per minute: PCIe AER errors, NVMe controller resets, drive and CPU
# temperature, fan PWM. Every 10 minutes it writes and reads 2 GB at a random offset.
# WRITES TO THE RAW DRIVE, so only use it on a drive with nothing on it.
# Run as root. Clears the kernel ring buffer every minute (dmesg -C).
L=${LOG:-$PWD/nvme_monitor.log}
echo "time aer_per_min resets_per_min t_drive t_cpu fan_pwm note" >> "$L"
i=0
while true; do
  dmesg -C; N=""
  if [ $((i % 10)) -eq 5 ]; then
    dd if=/dev/urandom of=/dev/nvme0n1 bs=4M count=500 oflag=direct seek=$((RANDOM % 40000)) status=none; N="write2GB"
    dd if=/dev/nvme0n1 of=/dev/null bs=4M count=500 iflag=direct status=none
  fi
  sleep 60
  A=$(dmesg | grep -c "PCIe Bus Error"); F=$(dmesg | grep -c "frozen state")
  TD=$(nvme smart-log /dev/nvme0 2>/dev/null | awk '/^temperature/{print $3}')
  TC=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
  P=$(cat /sys/class/hwmon/hwmon*/pwm1 2>/dev/null | head -1)
  echo "$(date +%H:%M) $A $F $TD $TC $P $N" >> "$L"
  i=$((i+1))
done
