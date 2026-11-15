# A UPS, clean shutdown and automatic restart

A CyberPower CP1500AVRLCD3 (1500 VA / 900 W, line-interactive, simulated sine wave) feeds the Jetson, the router, the fibre terminal and a home server. The server reads the UPS over USB with [NUT](https://networkupstools.org/) and the Jetson is a network client.

**Status: installed and working on mains; not yet tested with a real power cut.** The low-battery sequence was only exercised as a dry run. This page will be updated after the test.

## Why the Jetson needs more than a shutdown

The devkit starts by itself when power is applied, but it cannot be started any other way once it has been shut down (see [suspend and Wake-on-LAN](04-headless-and-tuning.md#suspend-and-wake-on-lan)). So with a UPS there is a gap:

1. Power fails, the battery runs low, the Jetson shuts down cleanly.
2. Mains power returns before the UPS is empty. The UPS never cut its output.
3. The Jetson never sees power "applied", and stays off until someone unplugs it.

The usual answer is to have the UPS cut its output for a moment after the clients are down and restore it when mains power is back. Everything on the battery outlets restarts, the router included.

## Layout

| Machine | Role | Reacts to low battery by |
|---|---|---|
| Home server (a laptop, with its own battery), Ubuntu 24.04, NUT 2.8.1 | Runs the driver and `upsd`; monitors only | Waiting for the Jetson to go, then telling the UPS to cycle its output |
| Jetson, Ubuntu 20.04, NUT 2.7.4 | `upsmon` client | Shutting down |

The two NUT versions talk to each other without trouble. The older client uses the keyword `slave` where the newer one says `secondary`.

Wiring notes from the manual: plug the UPS straight into a grounded wall outlet (no extension leads or power strips), check that the red wiring-fault light on the back stays off, never put a laser printer on the battery outlets, and charge for 8 hours before relying on the battery. Only half of the outlets are battery-backed; the other half are surge-only.

## Server

```bash
sudo apt install nut
lsusb | grep -i cyber        # 0764:0601 Cyber Power System, Inc.
```

`/etc/nut/nut.conf`

```
MODE=netserver
```

`/etc/nut/ups.conf`

```
[cyberpower]
    driver = usbhid-ups
    port = auto
    vendorid = 0764
    productid = 0601
    offdelay = 60        # seconds between the shutdown command and the output going off
    ondelay = 70         # must be larger than offdelay
```

`/etc/nut/upsd.conf`

```
LISTEN 0.0.0.0 3493
```

`/etc/nut/upsd.users` (generate the passwords, for example with `openssl rand -hex 16`; keep the file mode 640, owner `root:nut`)

```
[admin]
    password = ...
    actions = SET
    instcmds = ALL
[local]
    password = ...
    upsmon primary
[monitor]
    password = ...
    upsmon secondary
```

`/etc/nut/upsmon.conf`. The server is a laptop, so the UPS running out does not take it down and it should not shut itself down. A power value of `0` with `MINSUPPLIES 0` means "monitor only":

```
MONITOR cyberpower@localhost 0 local <password> primary
MINSUPPLIES 0
SHUTDOWNCMD "/bin/true"
NOTIFYFLAG ONLINE  SYSLOG+WALL
NOTIFYFLAG ONBATT  SYSLOG+WALL
NOTIFYFLAG LOWBATT SYSLOG+WALL+EXEC
NOTIFYCMD /usr/local/sbin/ups-notify
```

After installing the package the USB device still has its old permissions, so reload udev (or re-plug the cable) before starting the driver:

```bash
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=usb --action=add
sudo systemctl restart nut-driver.target nut-server nut-monitor
upsc cyberpower@localhost
```

What it reported with all four machines connected:

```
device.model: CP1500AVRLCD3
ups.status: OL
ups.load: 4                  # percent of 900 W, about 36 W
battery.charge: 100
battery.runtime: 17475       # seconds; the UPS's own estimate, not verified
battery.charge.low: 10
battery.runtime.low: 300
input.voltage: 122.0
```

With nothing but the router and the Jetson the load read `0` and the runtime `27000`: at loads this small the estimate is coarse.

## The low-battery handler

[scripts/host/ups-notify](../scripts/host/ups-notify) is run by `upsmon` (as user `nut`) on the `LOWBATT` event:

1. It watches the list of clients connected to `upsd` (`upsc -c`), for up to two minutes, until the remote ones are gone. That is how it knows the Jetson is shutting down, without needing its address.
2. If the clients went away, or the UPS is still on battery, it sends `shutdown.return`: output off after `offdelay`, back on when mains power is present.
3. If the clients are still connected and the UPS is back on mains, it does nothing.

It reads the `admin` password from a file that group `nut` can read. `DRYRUN=1` logs the decision instead of sending the command:

```bash
sudo -u nut env NOTIFYTYPE=LOWBATT DRYRUN=1 WAIT=40 /usr/local/sbin/ups-notify
```

Dry runs gave the right answer in both cases: "nothing to do" with the Jetson connected and the UPS on mains, and "asking the UPS to cut the output" when the Jetson's `upsmon` was stopped during the wait.

## Jetson

```bash
sudo apt install nut-client
```

`/etc/nut/nut.conf`

```
MODE=netclient
```

`/etc/nut/upsmon.conf`

```
MONITOR cyberpower@<server address> 1 monitor <password> slave
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
DEADTIME 15
FINALDELAY 5
```

```bash
sudo systemctl enable --now nut-monitor
upsc cyberpower@<server address> ups.status      # OL
```

The Jetson shuts down when the UPS is on battery and reports low battery (10 % charge or 300 s of runtime, the UPS defaults). It also shuts down if it loses contact with the server while the UPS was last seen on battery, which covers the server dying first.

On the server, `upsc -c cyberpower@localhost` should list the Jetson's address next to `127.0.0.1`.

## Where to plug a laptop server

The server's charger can go on a surge-only outlet (the laptop has its own battery) or on a battery outlet. The battery outlet is the better choice:

| | Surge-only outlet | Battery outlet |
|---|---|---|
| Server runtime in an outage | Its own battery | UPS runtime plus its own battery |
| Wear on the laptop battery | One discharge per outage | Almost none |
| Extra load on the UPS | None | 15 to 25 W |

The server is the machine that gives the restart order and the one that cannot power itself on again (a laptop needs its button pressed), so it should be the last one to go down. On a surge-only outlet, an outage longer than the laptop's battery leaves the house unreachable from outside until someone presses that button, and an outage in which the laptop dies before the UPS reaches low battery shuts the Jetson down early with nobody left to order the restart.

## Still to do

- A real test: unplug the UPS from the wall. Raising `battery.charge.low` for the test (`upsrw -s battery.charge.low=95 ...`) triggers the sequence within minutes instead of hours.
- Confirm that this model honours `shutdown.return` when mains power has already returned, and the real values of the off and on delays (some CyberPower units round them to whole minutes).
- Measure the real runtime.
