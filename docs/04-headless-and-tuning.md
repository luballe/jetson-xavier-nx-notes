# Headless operation and tuning

The board is used as a small compute node over SSH, not as a desktop.

## No desktop

```bash
sudo systemctl set-default multi-user.target     # takes effect at next boot
sudo systemctl set-default graphical.target      # to go back
```

The desktop stays installed; it just does not start. With a monitor attached you get a text console.

Measured on this board after a fresh boot: about 545 MiB of RAM in use and 6.1 GiB available without the desktop. With the desktop running, the session alone was 57 processes. On a Jetson the GPU shares RAM with the system, so memory freed here is also available to CUDA.

## Services disabled

```bash
sudo systemctl disable --now bluetooth ModemManager kerneloops apport \
    snapd.socket snapd.seeded snapd.apparmor snapd wpa_supplicant
sudo sed -i 's/^enabled=1/enabled=0/' /etc/default/apport
sudo systemctl mask wpa_supplicant        # otherwise NetworkManager starts it again at boot
sudo nmcli radio wifi off
sudo rfkill block wifi
sudo rfkill block bluetooth
```

| Service | Why it was safe to turn off here |
|---|---|
| Bluetooth | Not used |
| ModemManager | No cellular modem |
| apport, kerneloops | Ubuntu crash reporting |
| snapd | No snaps installed |
| Wi-Fi, wpa_supplicant | Wired Ethernet only |

Kept on purpose: `nvargus-daemon` (CSI cameras), `nvfancontrol`, `nvpmodel`, zram.

Nothing was uninstalled, so `systemctl unmask`, `systemctl enable --now <unit>` and `rfkill unblock` undo it. Check that you are connected over Ethernet before switching Wi-Fi off.

## Power modes

```bash
sudo nvpmodel -q              # current mode
sudo nvpmodel -m 8            # MODE_20W_6CORE
```

| ID | Mode |
|---|---|
| 0 / 1 / 2 | 15 W with 2 / 4 / 6 cores |
| 3 / 4 | 10 W with 2 / 4 cores |
| 5 | 10 W desktop (the default; 4 cores) |
| 6 / 7 / 8 | 20 W with 2 / 4 / 6 cores |

Switching from mode 5 to mode 8 worked without a reboot, and the setting persists across reboots. A two-hour, six-core compile in mode 8 held the SoC at 50 °C with the stock fan and the original 45 W adapter.

## Fan

`nvfancontrol` keeps the fan off below roughly 50 °C. A silent fan on a warm heatsink is normal. A fan pinned at 100 % means nothing is controlling it, which is the case in recovery and in the flashing initrd.

## zram

The default configuration creates compressed swap in RAM (one device per CPU core, six here, about 3.4 GB total). It was left enabled.

- It costs nothing while there is no memory pressure.
- Under pressure it trades some CPU for not killing a process, and it does not wear the SSD.
- It does not help the GPU: memory held by CUDA cannot be swapped, so a model that does not fit still fails.

## jtop

```bash
sudo -H python3 -m pip install -U jetson-stats
sudo jtop --install-service
```

With a system-wide pip install on this release, `--install-service` reported `Unable to locate jtop_env.sh template file`: the files are installed under `/usr/local/share/jetson_stats` and the tool looks under `/usr/share`. A symlink fixed it:

```bash
sudo ln -s /usr/local/share/jetson_stats /usr/share/jetson_stats
sudo jtop --install-service
```

Log out and back in afterwards (the installer adds your user to the `jtop` group).

The process table in jtop is **not** a general process list. It shows only processes that hold GPU memory or have a handle open on the GPU driver. Use `htop` for everything else.

## A harmless firmware-update loop

After flashing the QSPI with `flash.sh`, the system shows this on every boot:

```
nv-l4t-bootloader-config.sh: Info. System version(deb version): 2295301, BSP version(QSPI version): 1
nv-l4t-bootloader-config.sh: INFO. Copy capsule payload: TEGRA_BL.Cap.
*** System restart required ***   (nvidia-l4t-bootloader)
```

What happens:

1. The firmware's ESRT table reports version `1` because it was written over USB, not through a capsule update.
2. NVIDIA's boot-time service sees a package version higher than `1` and stages a UEFI capsule update.
3. On the next reboot the UEFI rejects the capsule (`last_attempt_status` 6162) and boots normally. Firmware is unchanged; both boot slots stay `normal`.
4. Repeat.

The only visible effect is a permanent "restart required" notice. It was left alone: fixing it means touching the boot firmware again, and the firmware on the board is already the 35.6.5 build.

Checks:

```bash
sudo nvbootctrl dump-slots-info
sudo cat /sys/firmware/efi/esrt/entries/entry0/{fw_version,last_attempt_status}
```
