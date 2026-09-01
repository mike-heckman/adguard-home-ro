#!/bin/bash

#
# Remount /boot/firmware as read-write, disable overlayfs, create flag, and reboot
# to perform periodic system & AdGuard software update(s).
#

if ! mount -o remount,rw /boot/firmware 2>/dev/null; then
    echo "Failed to remount /boot/firmware as read-write. Exiting." >> /var/log/adguard-update-trigger.log
    exit 1
fi

if ! raspi-config nonint disable_overlayfs; then
    echo "Failed to disable overlayfs. Exiting." >> /var/log/adguard-update-trigger.log
    exit 1
fi

if ! touch /boot/firmware/adguard-update-pending; then
    echo "Failed to create adguard-update-pending flag. Exiting." >> /var/log/adguard-update-trigger.log
    exit 1
fi

reboot