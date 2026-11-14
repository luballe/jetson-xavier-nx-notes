# Recovery and flashing

How a non-booting Xavier NX Developer Kit was reflashed from an Ubuntu host, with the dead ends included.

## Background

- The kit is the 2020 developer kit: module P3668-0000 (the variant with a microSD slot) on carrier P3509.
- It stopped booting after the boot device was switched from microSD to SSD.
- Old SD-card images on hand were JetPack 4.4 DP (L4T 32.4.2) and JetPack 5.1.2 (L4T 35.4.1). Neither was used. Writing an old SD image does not help when the QSPI firmware is from a different generation: JetPack 4 uses CBoot and JetPack 5 uses UEFI, and the two do not mix.
- The last release for Xavier NX is the Jetson Linux 35.x line. This work used **35.6.5**.

## What you need

- An x86-64 Ubuntu host. NVIDIA documents 18.04/20.04 for this release; 24.04 worked.
- A micro-USB data cable from the host to the Jetson.
- A jumper for the recovery pins.
- About 30 GB free on the host.

## Recovery mode

1. Unplug power.
2. Put a jumper on pins 9 and 10 (`FC REC` and `GND`) of the button header J14, under the module.
3. Connect the micro-USB cable to the host and plug power back in.
4. On the host, `lsusb` shows `0955:7e19 NVIDIA Corp. APX`.

Remove the jumper once the device is in recovery. Every mode change needs a power cycle, and getting back into recovery needs the jumper again.

USB IDs seen during the process:

| ID | Meaning |
|---|---|
| `0955:7e19` | Recovery mode (APX) |
| `0955:7035` | Booted into the flashing initrd |
| `0955:7020` | Normal L4T system running |

## Preparing the host

```bash
mkdir ~/jetson && cd ~/jetson
B=https://developer.nvidia.com/downloads/embedded/l4t/r35_release_v6.5/release
wget $B/jetson_linux_r35.6.5_aarch64.tbz2
wget $B/tegra_linux_sample-root-filesystem_r35.6.5_aarch64.tbz2

sudo apt install lbzip2            # tar fails on .tbz2 without it
tar xf jetson_linux_r35.6.5_aarch64.tbz2
sudo tar xpf tegra_linux_sample-root-filesystem_r35.6.5_aarch64.tbz2 -C Linux_for_Tegra/rootfs/
cd Linux_for_Tegra
sudo ./tools/l4t_flash_prerequisites.sh
sudo ./apply_binaries.sh
```

See [scripts/host/prepare.sh](../scripts/host/prepare.sh).

## The commands that worked

### QSPI firmware only (about 2.5 minutes)

```bash
sudo ./flash.sh jetson-xavier-nx-devkit-qspi mmcblk0p1
```

The last argument names the root device the firmware will expect (`mmcblk0p1` for microSD, `nvme0n1p1` for NVMe). This is also the fix for the recovery-boot loop described below.

### A booted initrd for diagnosis

```bash
sudo ./tools/kernel_flash/l4t_initrd_flash.sh --initrd --showlogs --network usb0 \
    jetson-xavier-nx-devkit-qspi internal
sshpass -p root ssh root@fc00:1:1:0::2
```

This boots a small Linux over USB without writing anything. It gives a root shell on the Jetson, which made it possible to inspect the SSD, read kernel logs and write the microSD directly. `--flash-only --initrd` on its own fails with `Stat for mb1_b_t194_prod.bin failed`; the full invocation above regenerates what it needs.

In this environment the fan runs at 100 % (nothing controls it) and the microSD is `/dev/mmcblk1`. In the normal system it is `/dev/mmcblk0`.

To power the board off from the initrd shell:

```bash
echo 1 > /proc/sys/kernel/sysrq; echo o > /proc/sysrq-trigger
```

### microSD image, written through the initrd

`sudo ./flash.sh jetson-xavier-nx-devkit internal` hung twice at `tegradevflash_v2 --iscpubl`. The route that worked was to build an SD image and write it through the initrd shell:

```bash
cd tools
sudo ./jetson-disk-image-creator.sh -o ~/jetson/sd-blob.img -b jetson-xavier-nx-devkit -d SD
# boot the initrd as above, then:
sudo cat ~/jetson/sd-blob.img | sshpass -p root ssh root@fc00:1:1:0::2 \
    "dd of=/dev/mmcblk1 bs=4M conv=fsync"
```

Then read the card back and compare SHA-256 with the image. See [scripts/host/write_sd_via_initrd.sh](../scripts/host/write_sd_via_initrd.sh). `-d SD` is required.

The sequence that finally produced a booting system was: QSPI flash, SD image through the initrd, QSPI flash again, then let the first boot run to completion.

## Failures and what they really were

### Flash to NVMe reported success, but the root partition was empty

`l4t_initrd_flash.sh --external-device nvme0n1p1 ... jetson-xavier-nx-devkit-qspi internal` logged that the external device was flashed, then the Jetson reset in the middle of the QSPI write. The QSPI was completed with `flash.sh`, and the board showed video, so it looked fixed.

It was not. The NVMe root partition was empty: the SSD was dropping off the PCIe bus (see [02-nvme-ssd.md](02-nvme-ssd.md)) and the data never reached the disk.

Lesson: video output proves the firmware works, nothing more. Verify the root filesystem before calling a flash done.

### "It powers off by itself after the boot log"

Three wrong diagnoses in a row:

1. **Power adapter.** The original adapter is 19 V 2.37 A (45 W). It was fine.
2. **Overheating.** The heatsink was hot and the fan was not spinning. That is normal: JetPack 5 keeps the fan off below roughly 50 °C, and a board stuck in firmware has no fan control at all.
3. **Running without video.** No.

The real cause was a kernel waiting forever for a root filesystem that did not exist. The screen goes blank and the board looks off.

### "NVIDIA logo, then black after about 10 seconds"

A phone video of the screen caught one line: `L4TLauncher: Attempting Recovery Boot`.

After several failed boots the UEFI marks the normal boot chain as unbootable and tries the recovery kernel. With a QSPI-only layout there is no recovery kernel, so it hangs. Unplugging the board repeatedly during boot is what triggers it.

Fix: reflash the QSPI (the 2.5-minute command above), then let the next boot finish without interrupting it.

### The UEFI prefers a bootable NVMe over the microSD

With a working microSD system, reinstalling an SSD that still had old boot partitions made the UEFI boot from the SSD and panic (`no /sbin/init`). Press F11 at the logo for the boot menu, or wipe the SSD (`blkdiscard`, `sgdisk --zap-all`) before installing it.

### Smaller things

- The host's built-in SD reader did not detect the card at all, which is why the card was written through the Jetson.
- When writing wrappers that run remote commands over ssh, `pkill -f pattern` also matches the ssh command carrying the pattern and kills your own session. Use the bracket trick: `pkill -f "[f]lash.sh"`.
- Long remote jobs: write the script locally, `scp` it, and start it with `setsid nohup` so it survives the ssh session.

## After first boot

The first boot runs the OEM setup wizard on the attached display (user, locale, and so on). After that:

- Add your SSH key and, if you want unattended administration, a sudoers drop-in.
- Shut down from software (`sudo poweroff`). Pulling power during boot is what leads to the recovery-boot state.
