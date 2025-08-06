#!/bin/bash

nmcli device wifi rescan
nmcli -f SIGNAL,SSID,FREQ,CHAN,ACTIVE,IN-USE  device wifi lis
nmcli -f device,type,autoconnect,active,state connection show
lsusb

if [[ ${1} == "-s" ]]; then
   exit 254
fi
