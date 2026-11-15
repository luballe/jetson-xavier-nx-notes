# NVMe SSD: a bad pairing, and moving the system off the microSD

## Summary

- A Samsung 970 EVO Plus 250 GB (firmware 2B2QEXM7) produces PCIe link errors in this board's M.2 Key M slot. Under the flashing initrd the errors reset the drive every couple of seconds, which is what silently broke the first NVMe install.
- The drive itself is healthy. The slot is healthy. A SanDisk Optimus GX 7100 500 GB in the same slot ran the same tests with zero errors.
- The root cause of the Samsung's behaviour was not found.

## Symptoms with the Samsung drive

In the flashing initrd:

```
nvme nvme0: frozen state error detected, reset controller
pcieport 0005:00:00.0: AER: ... SDES (Surprise Down) ... UnsupReq
```

The controller reset about every 1.8 seconds, with I/O errors. Root port `0005:00:00.0` is the PCIe controller behind the M.2 Key M slot.

In the full OS the picture was different, and misleading in the other direction:

- SMART was perfect: 0 % wear, 0 media errors, about 1,100 power-on hours.
- A full 250 GB read completed cleanly.
- 48 GiB of random data written and read back matched by SHA-256.
- But about 6 minutes after power-on there was a 20-minute episode of continuous AER errors (roughly 5 per second, even idle), with no controller resets and no I/O errors.

## What was tried and did not help

| Attempt | Result |
|---|---|
| Cleaning and reseating the contacts | No change |
| ASPM policy set to `performance` | No change (ASPM was already disabled on the link) |
| Forcing the link to Gen1 with `max-link-speed = <1>` in `/pcie@141a0000` | Link did drop to 2.5 GT/s, errors persisted |
| `nvidia,max-speed` device-tree property | Has no effect on the 5.10 kernel |
| Disabling the drive's autonomous power states (APST) | Pattern changed from 2 errors per write burst to 1 error per minute; not a fix |
| Firmware update | None available: 2B2QEXM7 is the latest for this hardware revision of the 970 EVO Plus |

No documented incompatibility between this drive and the Xavier NX was found. Forum threads show similar AER errors on the same root port with assorted drives.

## Three-hour log with the Samsung drive

A script logged AER errors per minute and wrote and read 2 GB every 10 minutes ([scripts/jetson/nvme_monitor.sh](../scripts/jetson/nvme_monitor.sh)).

- 172 minutes logged, 48 errors, never more than 2 in a minute, no controller resets.
- All 17 scheduled writes produced exactly 2 errors each.
- Six more pairs appeared exactly 30 minutes apart, matching the default polling interval of `smartd`.
- Idle minutes had zero errors.

So the errors were tied to moments when the drive was asked to do something after sitting idle, not to temperature (steady at 46 °C) and not to random noise.

## The comparison that settled it

Same slot, same OS, same scripts, different drive:

| | SanDisk Optimus GX 7100 500 GB | Samsung 970 EVO Plus 250 GB |
|---|---|---|
| Negotiated link | Gen4 x4 (16 GT/s) | Gen3 x4 (8 GT/s) |
| Peak power state | 4.1 W | 7.8 W |
| Full-disk read | Clean | Clean |
| 48 GiB write + SHA-256 read-back | Match | Match |
| AER errors under test | 0 | Thousands in one episode |
| 31-minute log with 2 GB writes | 0 errors | 2 errors per write |

The slot sustaining a clean Gen4 link under load rules it out as the problem.

Practical advice for this board: test any NVMe drive with the scripts below before trusting it as a system disk, and prefer low-power drives.

## Test procedure

Both scripts destroy the contents of the NVMe drive.

- [scripts/jetson/nvme_test.sh](../scripts/jetson/nvme_test.sh): full read, then 48 GiB of pseudo-random data written and read back with a SHA-256 comparison, and a count of kernel errors.
- [scripts/jetson/nvme_monitor.sh](../scripts/jetson/nvme_monitor.sh): one line per minute with AER count, controller resets, drive and CPU temperature and fan PWM, plus a 2 GB write/read every 10 minutes.

Useful one-liners:

```bash
sudo nvme smart-log /dev/nvme0
sudo nvme id-ctrl /dev/nvme0 | grep -E "^(mn|fr|ps) "
sudo lspci -vv -s 0005:01:00.0 | grep -E "LnkSta:|LnkCtl:"
sudo dmesg | grep -c "PCIe Bus Error"
```

## Migrating the running system from microSD to NVMe

The system was already installed and configured on the microSD, so it was cloned instead of reflashed. No recovery mode needed. See [scripts/jetson/migrate_sd_to_nvme.sh](../scripts/jetson/migrate_sd_to_nvme.sh).

Steps the script performs:

1. Copy the microSD's GPT to the NVMe (`sgdisk --backup` / `--load-backup`), move the backup header to the end of the disk (`-e`) and randomise the GUIDs (`-G`).
2. Delete partition 1 (`APP`, the root filesystem) and recreate it from the same start sector to the end of the disk.
3. `dd` partitions 2 to 22 (kernel, device trees, recovery, `esp`, and so on) and verify each by checksum.
4. `mkfs.ext4` on the new `APP` partition and `rsync -aAXHx --numeric-ids /` into it.
5. Point `root=PARTUUID=...` in `/boot/extlinux/extlinux.conf` on the new disk at the new partition.

Why this layout: the UEFI launcher loads from the `esp` partition and looks for a partition named `APP` on the same device, so the partition names must be preserved.

Results:

- About 6 minutes for a 6 GB system.
- The UEFI already listed the NVMe first in its boot order, so it booted from the SSD on the next restart with the microSD still inserted, and again with the microSD removed.
- The microSD was left untouched as a fallback boot device (F11 at the logo selects it).

### The boot order does not stay put

Weeks later the microSD was taken out and, later still, put back in. On the next power-up the board booted **from the microSD**, into the old system, without any message. The UEFI had re-created the entry for the card and placed it first:

```
$ sudo efibootmgr
BootCurrent: 0001
BootOrder: 0001,0009,0000,0002,...
Boot0001* UEFI SD Device
Boot0009* UEFI <NVMe model and serial>
```

Nothing is damaged by this, but it is easy to miss over SSH: the hostname and the address are the same, and only the missing services and the old files give it away. Check before doing anything else:

```bash
findmnt -no SOURCE /            # /dev/nvme0n1p1 or /dev/mmcblk0p1
```

To put the SSD first again (from either system), keeping the card as the fallback:

```bash
sudo efibootmgr -o 0009,0001,0000,0002,0003,0004,0005,0006,0007
sudo reboot
```

`sudo efibootmgr -n 0001` boots the card once, on the next restart only, which is the safe way to test a card. Re-check the order whenever a card is inserted or removed.

A caution: a failed boot or two is harmless, but repeated failed boots trigger the recovery-boot state described in [01-recovery-and-flashing.md](01-recovery-and-flashing.md).
