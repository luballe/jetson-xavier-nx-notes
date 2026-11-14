#!/bin/bash
# Turn the Jetson into a headless node: no desktop at next boot, unused services off,
# radios blocked. Run as root while connected over Ethernet. Nothing is uninstalled.
systemctl set-default multi-user.target
systemctl disable --now bluetooth ModemManager kerneloops apport \
    snapd.socket snapd.seeded snapd.apparmor snapd wpa_supplicant
sed -i 's/^enabled=1/enabled=0/' /etc/default/apport
nmcli radio wifi off
rfkill block wifi
rfkill block bluetooth
