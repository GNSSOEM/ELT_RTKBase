#!/bin/bash

if lsb_release -c | grep -q 'trixie'; then
   sudo cpupower frequency-set -g powersave
else
   sudo cpufreq-set -g powersave
fi
#MODEL=`cat /proc/cpuinfo | grep Model`
#echo MODEL=${MODEL}
#PI4=`echo ${MODEL} | grep "Pi 4"`
#echo PI4=${PI4}
#if [[ "${PI4}" != "" ]]
#then
#   USB_COUNT=`lsusb -t | wc -l`
#   if [[ "${USB_COUNT}" -gt 3 ]]
#   then
#       USB_PORT=Y
#   fi
#   #echo USB_COUNT=${USB_COUNT} USB_PORT=${USB_PORT}
#   if [[ "${USB_PORT}" != "Y" ]]
#   then
#      sudo uhubctl -l 1-1 -a 0 # turn off USB
#      #sudo uhubctl -l 2 -a 0
#   fi
#fi
sudo vcgencmd display_power 0
