# A bootable backup image of the running system

The system on the NVMe SSD took weeks to get right. This is how it was turned into one image file that can be written to a microSD card and booted, and how that was verified.

## Why not just `dd` the SSD

The SSD's root partition is 465 GB with 26 GB in use; a 64 GB card cannot take a raw copy. The image is built instead:

- The 21 small partitions (kernel, device tree, the A/B firmware slots, recovery, the EFI system partition) are copied byte for byte. They are the same size and at the same sectors on a card as on the SSD.
- The root filesystem (`APP`) is created new at 36 GiB and filled with `rsync`.
- The partitions get new GUIDs, and `root=PARTUUID=...` in the image's `/boot/extlinux/extlinux.conf` is pointed at the image's own `APP` partition. With identical GUIDs on the SSD and the card, the kernel could mount the wrong root when both are present.

[scripts/jetson/make_backup_image.sh](../scripts/jetson/make_backup_image.sh) does this on the running board, onto the SSD itself:

```bash
sudo -E APP_GIB=36 ./make_backup_image.sh        # writes ~/backup-img/jetson-xavier-nx-YYYYMMDD.img
```

| Step | Result here |
|---|---|
| Build | 16 minutes. 39.4 GB apparent size, 24 GB allocated (it is a sparse file) |
| Small partitions | Each compared with its source after copying |
| Filesystem | `e2fsck -fn` clean; 24 GB used of 36 GB |

The copy is taken from a live system, so a file being written at that moment may be caught half-way. Nothing heavy was running, and the boot test below is what counts.

## Writing and verifying the card

[scripts/jetson/write_backup_image.sh](../scripts/jetson/write_backup_image.sh) writes the image to the card in the board's own slot, reads the card back and compares it with the image, then moves the backup GPT header to the end of the card:

```bash
sudo ./write_backup_image.sh ~/backup-img/jetson-xavier-nx-YYYYMMDD.img
```

Writing 39.4 GB took 10.5 minutes (about 62 MB/s) and the read-back comparison 7.5 minutes, on a 64 GB card.

## Boot test

`efibootmgr -n 0001` (boot the card once) **was ignored**: the board came back on the SSD, with nothing to say why. What worked was putting the card first, testing, and putting the SSD first again from the system running on the card:

```bash
sudo efibootmgr -o 0001,0009,0000,0002,0003,0004,0005,0006,0007 && sudo reboot   # 0001 = SD, 0009 = NVMe
findmnt -no SOURCE /                                                             # /dev/mmcblk0p1
# ... checks ...
sudo efibootmgr -o 0009,0001,0000,0002,0003,0004,0005,0006,0007 && sudo reboot
```

Booted from the card: `systemctl is-system-running` said `running` with no failed units, the services were up, PyTorch ran a matrix product on the GPU, OpenCV saw its CUDA device, and the power mode was the one configured. If a card does not boot, the firmware falls through to the next entry; if it hangs half-way, pull the card and power-cycle.

The boot order is stored in the board's flash, not on the disks, so it can be changed from either system. See also [the boot order does not stay put](02-nvme-ssd.md#the-boot-order-does-not-stay-put).

## Storing it

```bash
ssh jetson 'zstd -T6 -3 -c ~/backup-img/jetson-xavier-nx-YYYYMMDD.img' > jetson-xavier-nx-YYYYMMDD.img.zst
zstd -dc jetson-xavier-nx-YYYYMMDD.img.zst | shasum -a 256        # must equal the .sha256 written by the build
```

39.4 GB compressed to 9.9 GB in about four minutes over gigabit Ethernet, and the checksum of the decompressed stream matched.

The image contains everything in the home directory, credentials included (SSH keys, tokens). Store it accordingly.

## Restoring

```bash
zstd -dc jetson-xavier-nx-YYYYMMDD.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync     # Linux
zstd -dc jetson-xavier-nx-YYYYMMDD.img.zst | sudo dd of=/dev/rdiskN bs=4m             # macOS
```

On a larger card, grow the root afterwards:

```bash
sudo sgdisk -e /dev/mmcblk0 && sudo parted /dev/mmcblk0 resizepart 1 100% && sudo resize2fs /dev/mmcblk0p1
```

To go back to an SSD, boot from the card and follow [the microSD-to-NVMe migration](02-nvme-ssd.md#migrating-the-running-system-from-microsd-to-nvme). Growing the root and restoring to a new SSD from this image were **not tested**.
