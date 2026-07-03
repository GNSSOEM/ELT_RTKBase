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

cidr_range() {
    local net=${1%/*}
    local prefix=${1#*/}

    local net_int=$(ip2int "$net")
    local mask=$(( (0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF ))

    local start=$(( net_int & mask ))
    local end=$(( start | (~mask & 0xFFFFFFFF) ))

    echo "$start $end"
}

subnets_overlap() {
    local r1 r2
    read -r s1 e1 <<< "$(cidr_range "$1")"
    read -r s2 e2 <<< "$(cidr_range "$2")"

    #echo $s1 \<\= $e2 \&\& $s2 \<\= $e1
    (( $s1 <= $e2 && $s2 <= $e1 ))
}


SEPTENTRIO="septentrio"
MOBILE="mobile"

ETH_UUID_LIST=$(nmcli --fields TYPE,UUID connection show | grep -w "ethernet" | awk -F ' ' '{print $2}')
#echo ETH_UUID_LIST=${ETH_UUID_LIST}
for UUID in ${ETH_UUID_LIST}; do
    DEVICE=$(nmcli --fields connection.interface-name connection show uuid "${UUID}" | awk -F ' ' '{print $2}')
    if [[ "${DEVICE}" == "${SEPTENTRIO}" ]]; then
       HAS_SEPTENTRIO=YES
       SEPTENTRIO_UUID="${UUID}"
       SEPTENTRIO_NET=$(nmcli --get-values IP4.ADDRESS connection show uuid "${UUID}")
       if [[ -z "${SEPTENTRIO_NET}" ]]; then
          SEPTENTRIO_NET=$(nmcli --get-values ipv4.addresses connection show uuid "${UUID}")
       fi
       if [[ -z "${SEPTENTRIO_NET}" ]]; then
          SEPTENTRIO_NET="192.168.3.2/2"
       fi
    fi
    if [[ "${DEVICE}" == "${MOBILE}" ]]; then
       HAS_MOBILE=YES
       MOBILE_UUID="${UUID}"
       MOBILE_NET=$(nmcli --get-values IP4.ADDRESS connection show uuid "${UUID}")
       if [[ -z "${MOBILE_NET}" ]]; then
          MOBILE_NET=$(nmcli --get-values ipv4.addresses connection show uuid "${UUID}")
       fi
       if [[ -z "${MOBILE_NET}" ]]; then
          MOBILE_NET="192.168.8.100/24"
       fi
    fi
done

if [[ -n "${HAS_SEPTENTRIO}" ]] then
   SEPTENTRIO_GOOD=YES
else
   SEPTENTRIO_GOOD=NO
fi
if [[ -n "${HAS_MOBILE}" ]] then
   MOBILE_GOOD=YES
else
   MOBILE_GOOD=NO
fi
#echo HAS_SEPTENTRIO=${HAS_SEPTENTRIO} SEPTENTRIO_UUID=${SEPTENTRIO_UUID} SEPTENTRIO_NET=${SEPTENTRIO_NET} SEPTENTRIO_GOOD=${SEPTENTRIO_GOOD} 
#echo HAS_MOBILE=${HAS_MOBILE} MOBILE_UUID=${MOBILE_UUID} MOBILE_NET=${MOBILE_NET} MOBILE_GOOD=${MOBILE_GOOD}

if [[ -n "${HAS_SEPTENTRIO}" ]] || [[ -n "${HAS_MOBILE}" ]]; then
   UUID_LIST=$(nmcli --get-values UUID connection show --active)
   #echo UUID_LIST=${UUID_LIST}
   for UUID in ${UUID_LIST}; do
       DEVICE=$(nmcli --get-values connection.interface-name connection show uuid "${UUID}")
       NETS=$(nmcli --get-values IP4.ADDRESS connection show uuid "${UUID}")
       #echo DEVICE=${DEVICE} NETS=${NETS}
       for NET in "${NETS}"; do
           if [[ -n "${NET}" ]]; then
              if [[ -n "${HAS_SEPTENTRIO}" ]] && [[ "${DEVICE}" != "${SEPTENTRIO}" ]]; then
                 if subnets_overlap "${SEPTENTRIO_NET}" "${NET}"; then
                    echo "${DEVICE}" "${NET}" disable "${SEPTENTRIO}" USB ethernet device "${SEPTENTRIO_NET}"
                    SEPTENTRIO_GOOD=NO
                 fi
              fi
              if [[ -n "${HAS_MOBILE}" ]] && [[ "${DEVICE}" != "${MOBILE}" ]]; then
                 if subnets_overlap "${MOBILE_NET}" "${NET}"; then
                    echo "${DEVICE}" "${NET}" disable "${MOBILE}" USB ethernet device "${MOBILE_NET}"
                    MOBILE_GOOD=NO
                 fi
              fi
           fi
       done
   done
fi

CHANGE=NO
up_down_device() {
   local good="${!1}"
   local uuid="${2}"
   local isactive=$(nmcli --get-values UUID connection show --active | grep -w "${uuid}")
   local have=$(nmcli --get-values UUID connection show | grep -w "${uuid}")
   #echo good=${good} uuid=${uuid} isactive=${isactive} have=${have}
   if [[ -z "${have}" ]]; then
      CHANGE=YES
      eval ${1}="DOWN"
      #echo ${1}=${!1}
   elif [[ "${good}" == "YES" ]]; then
      if [[ -z "${isactive}" ]]; then
         echo nmcli connection up uuid "${uuid}"
         nmcli connection up uuid "${uuid}"
         CHANGE=YES
      fi
   elif [[ -n "${isactive}" ]]; then
      echo nmcli connection down uuid "${uuid}"
      nmcli connection down uuid "${uuid}"
      CHANGE=YES
   fi
}

start_stop_service(){
   local service_name=${1}
   local action=${2}
   local service_active=$(systemctl is-active "${service_name}")
   #echo service_name=${service_name} service_active=${service_active} action=${action}
   if [[ "${action}" == "YES" ]]; then
      if [ "${service_active}" != "active" ]; then
         echo systemctl start "${service_name}"
         systemctl start "${service_name}"
         CHANGE=YES
      fi
   else
      if [ "${service_active}" != "inactive" ]; then
         echo systemctl stop "${service_name}"
         systemctl stop "${service_name}"
         CHANGE=YES
      fi
   fi
}

if [[ -n "${HAS_SEPTENTRIO}" ]]; then
   up_down_device SEPTENTRIO_GOOD "${SEPTENTRIO_UUID}"

   start_stop_service rtkbase_DHCP.service "${SEPTENTRIO_GOOD}"
   start_stop_service rtkbase_gnss_web_proxy.service "${SEPTENTRIO_GOOD}"
fi 

if [[ -n "${HAS_MOBILE}" ]]; then
   up_down_device MOBILE_GOOD "${MOBILE_UUID}"

   start_stop_service rtkbase_modem_web_proxy.service "${MOBILE_GOOD}"
fi 

#echo CHANGE=${CHANGE}
if [[ "${CHANGE}" == "YES" ]]; then
   echo systemctl restart rtkbase_septentrio_NAT.service
   systemctl restart rtkbase_septentrio_NAT.service
fi
