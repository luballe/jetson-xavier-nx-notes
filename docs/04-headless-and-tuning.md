# Headless operation and tuning

The board is used as a small compute node over SSH, not as a desktop.

## No desktop

```bash
sudo systemctl set-default multi-user.target     # takes effect at next boot
sudo systemctl set-default graphical.target      # to go back
```

The desktop stays installed; it just does not start. With a monitor attached you get a text console.

Measured on this board, idle, with the services below already disabled in both cases. The desktop figures are with the GNOME session logged in (auto-login) and two minutes of settling time.

| | Headless | Desktop |
|---|---|---|
| RAM in use | 542 MiB | 1455 MiB |
| RAM available | 6085 MiB | 5156 MiB |
| User-space processes | 46 | 124 |
| System services running | 29 | 36 |
| Per-user services running | 2 | 35 |
| Time to reach the boot target (`systemd-analyze`) | 31.8 s | 32.2 s |

About 0.9 GiB comes back. The largest desktop processes were `gnome-shell` (346 MiB resident), `gnome-software` (194), `update-manager` (138) and `Xorg` (100). On a Jetson the GPU shares RAM with the system, so memory freed here is also available to CUDA.

Boot time barely changes: the firmware and kernel dominate, and `systemd-analyze` stops counting when the target is reached, before the desktop session has finished loading. From `reboot` to an SSH login took about 105 s either way, most of it shutdown plus UEFI.

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

## Suspend and Wake-on-LAN

A Jetson that has been shut down cannot be started over the network: only the power button or re-applying power does that. Suspend-to-RAM (SC7) plus Wake-on-LAN gives the same result in practice, and it works on this board once it is set up the right way.

Setup, once (the setting is stored in the connection profile and survives reboots):

```bash
sudo nmcli con mod "Wired connection 1" 802-3-ethernet.wake-on-lan magic
sudo nmcli con up "Wired connection 1"
sudo ethtool eth0 | grep Wake-on        # Wake-on: g
```

Sleep and wake:

```bash
sudo systemctl suspend                  # on the Jetson
```

```python
# on any other machine in the same LAN; MAC is the Jetson's eth0 address
import socket
mac = bytes.fromhex("AABBCCDDEEFF")
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.sendto(b"\xff" * 6 + mac * 16, ("192.168.1.255", 9))
```

[scripts/host/wake-jetson](../scripts/host/wake-jetson) wraps this for a machine that is always on in the same LAN (a home server, a Raspberry Pi): it sends the packet, waits until SSH answers and prints the Jetson's address, which it finds by MAC so a changed DHCP lease does not matter. `wake-jetson --ip` only looks the address up. The MAC goes in `/etc/wake-jetson.conf`.

Measured over five wake-ups, one of them after five minutes asleep: SSH answered 11 to 18 s after the magic packet (the last one sent with the script), it was the same boot (not a restart), the NVMe link was still Gen4 with no errors, and a CUDA computation in PyTorch ran correctly afterwards. The kernel log names the wake source:

```
tegra-pmc: Resume caused by WAKE20, 2490000.ethernet:01     # magic packet
tegra-pmc: Resume caused by WAKE24, max77620-top            # RTC alarm (rtcwake)
tegra-pmc: Resume caused by WAKE80, irq 204                 # USB device
```

What went wrong on the way, so you can skip it:

| What was done | What happened |
|---|---|
| `ethtool -s eth0 wol g`, then `rtcwake -m mem` (suspends without telling systemd or NetworkManager) | The magic packet woke the board, but the Ethernet link never came back and a USB keyboard stopped responding. `ip link set eth0 down; ip link set eth0 up` on the console restored the network |
| `ethtool -s eth0 wol g`, then `systemctl suspend` | No wake: NetworkManager takes the interface down on suspend and the ethtool setting is lost |
| `wake-on-lan magic` in the NetworkManager profile, then `systemctl suspend` | Works |

Other things to know:

- **A USB keyboard wakes the board** with any key press, and so does a mouse movement on a wireless keyboard-and-mouse dongle. That is the default and is usually what you want with a console attached. During the tests it caused two "spontaneous" wake-ups. To stop it for one device: `echo disabled | sudo tee /sys/bus/usb/devices/<id>/power/wakeup` (lasts until reboot or re-plug). `grep . /sys/bus/usb/devices/*/power/wakeup` lists what may wake the board.
- **The IP address can change after a resume** if the network is brought up outside NetworkManager, because DHCP starts over. With a home router handing out a new address, an SSH session to the old one just hangs, which looks exactly like a crashed board. It is not. Check the console, or scan the LAN, before cutting power. A DHCP reservation in the router avoids the whole problem.
- **mDNS (`hostname.local`) is not a reliable substitute**: it stopped resolving from a Mac for a while right after each resume.
- Power drawn while suspended was not measured.

## Reaching the board from outside the LAN

The Jetson itself needs no VPN client if another machine at home already is a WireGuard endpoint. On the laptop, one SSH host entry covers both cases: go direct when the LAN address answers, otherwise jump through the home server.

```
# ~/.ssh/config
Match originalhost jetson !exec "nc -z -G 2 192.168.1.152 22 >/dev/null 2>&1"
    ProxyJump homeserver
Host jetson
    HostName 192.168.1.152
    User youruser
```

`Match` blocks must come before the `Host` block they refine. `nc -z -G 2` is the macOS spelling of a two-second connect test; on Linux use `nc -z -w 2`. Away from home the same jump host runs the wake script: `ssh homeserver wake-jetson`.

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
