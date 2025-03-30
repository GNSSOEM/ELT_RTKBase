#!/bin/bash

for sysdevpath in $(find /sys/bus/usb/devices/usb*/ -name dev); do
    syspath="${sysdevpath%/dev}"
    devname="$(udevadm info -q name -p "${syspath}")"
    echo sysdevpath=${sysdevpath} syspath=${syspath} devname=${devname}
    if [[ "$devname" == "bus/"* ]]; then continue; fi
    udevadm info -q property -p "${syspath}"
done

