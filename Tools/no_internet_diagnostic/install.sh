#!/bin/bash
#
LOG=/boot/firmware/log
if [[ ! -d ${LOG} ]]; then
   mkdir ${LOG}
fi

SYSLOG=${LOG}/systemlog.txt
nmcli device wifi rescan 
nmcli -f SIGNAL,SSID,FREQ,CHAN,ACTIVE,IN-USE  device wifi list >${SYSLOG}
nmcli -f device,type,autoconnect,active,state connection show >>${SYSLOG}
lsusb >>${SYSLOG}
ls -la /dev/serial/by-id/ >>${SYSLOG}

serviceList="NetworkManager \
             RtkbaseSystemConfigure \
             rtkbase_system_configure \
             rtkbase_web \
             str2str_tcp \
             rtkbase_check_internet \
             rtkbase_check_satelites \
             rtkbase_septentrio_NAT \
             rtkbase_DHCP"

for service_name in ${serviceList}; do
    journalctl -u "${service_name}.service" --reverse >"${LOG}/${service_name}.txt" 2>&1
done
