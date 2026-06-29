#!/bin/bash

ip2int() {
    local IFS=.
    local a b c d
    read -r a b c d <<< "$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

ip_in_subnet() {
    local ip=$1
    local network=$2

    local net=${network%/*}
    local prefix=${network#*/}

    local ip_int=$(ip2int "$ip")
    local net_int=$(ip2int "$net")

    local mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))

    (( (ip_int & mask) == (net_int & mask) ))
}

start_stop_service(){
   local service_name=$1
   local action=$2
   local service_active=$(systemctl is-active "${service_name}")
   #echo service_name=${service_name} service_active=${service_active} action=${action}
   if [[ "${action}" == "YES" ]]; then
      if [ "${service_active}" != "active" ]; then
         echo systemctl start "${service_name}"
         systemctl start "${service_name}"
      fi
   else
      if [ "${service_active}" != "inactive" ]; then
         echo systemctl stop "${service_name}"
         systemctl stop "${service_name}"
      fi
   fi
}

SEPTENTRIO="septentrio"

ETH_UUID_LIST=$(nmcli --fields TYPE,UUID connection show | grep -w "ethernet" | awk -F ' ' '{print $2}')
#echo ETH_UUID_LIST=${ETH_UUID_LIST}
for UUID in ${ETH_UUID_LIST}; do
    DEVICE=$(nmcli --fields connection.interface-name connection show uuid "${UUID}" | awk -F ' ' '{print $2}')
    if [[ "${DEVICE}" == "${SEPTENTRIO}" ]]; then
       HAS_SEPTENTRIO=YES
       SEPTENTRIO_UUID="${UUID}"
       break
    fi
done
#echo HAS_SEPTENTRIO=${HAS_SEPTENTRIO}  SEPTENTRIO_UUID=${SEPTENTRIO_UUID}

if [[ -z "${HAS_SEPTENTRIO}" ]]; then
   echo Hasn\'t ${SEPTENTRIO}
   exit 1
fi


GOOD=YES
UUID_LIST=$(nmcli --fields UUID connection show --active | grep -v -w UUID)
#echo UUID_LIST=${UUID_LIST}
for UUID in ${UUID_LIST}; do
    DEVICE=$(nmcli --fields connection.interface-name connection show uuid "${UUID}" | awk -F ' ' '{print $2}')
    if [[ "${DEVICE}" != "${SEPTENTRIO}" ]]; then
       NETS=$(nmcli --fields IP4.ADDRESS connection show uuid "${UUID}" | awk -F ' ' '{print $2}')
       #echo DEVICE=${DEVICE} NETS=${NETS}
       for NET in "${NETS}"; do
           if ip_in_subnet "192.168.3.1" "${NET}"; then
              echo "${DEVICE}" "${NET}" disable septenrio USB ethernet device "192.168.3.1"
              GOOD=NO
              break 2
           fi
           if ip_in_subnet "192.168.3.2" "${NET}"; then
              echo "${DEVICE}" "${NET}" disable septenrio USB ethernet host "192.168.3.2"
              GOOD=NO
              break 2
           fi
       done
    fi
done

SEPTENTRIO_ISACTIVE=$(nmcli --fields DEVICE connection show --active | grep "${SEPTENTRIO}")
#echo GOOD=${GOOD} SEPTENTRIO_ISACTIVE=${SEPTENTRIO_ISACTIVE}
CHANGE=NO
if [[ "${GOOD}" == "YES" ]]; then
   if [[ -z "${SEPTENTRIO_ISACTIVE}" ]]; then
      echo nmcli connection up uuid "${SEPTENTRIO_UUID}"
      nmcli connection up uuid "${SEPTENTRIO_UUID}"
      CHANGE=YES
   fi
else
   if [[ -n "${SEPTENTRIO_ISACTIVE}" ]]; then
      echo nmcli connection down uuid "${SEPTENTRIO_UUID}"
      nmcli connection down uuid "${SEPTENTRIO_UUID}"
      CHANGE=YES
   fi
fi

start_stop_service rtkbase_DHCP.service "${GOOD}"
start_stop_service rtkbase_gnss_web_proxy.service "${GOOD}"
if [[ "${CHANGE}" == "YES" ]]; then
   echo systemctl start rtkbase_septentrio_NAT.service
   systemctl start rtkbase_septentrio_NAT.service
fi
