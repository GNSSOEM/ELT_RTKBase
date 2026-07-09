#!/bin/bash

SEPTENTRIO_STANDART_IP="192.168.3.1"
SEPTENTRIO_STANDART_NET="${SEPTENTRIO_STANDART_IP}/23"
MOBILE_STANDART_IP="192.168.8.1"

delete_by_ip(){
   local ip=$1
   table=''

   iptables-save |
   while IFS= read -r line; do
       case "$line" in
           \**)
               table=${line#\*}
               ;;
           -A\ *"$ip"*)
               iptables -t "$table" ${line/-A/-D}
               ;;
       esac
   done
}

addIfNotExist()
{
   local rule="${1}"
   #echo rule=${rule}
   if ! /sbin/iptables -C ${rule} 2>/dev/null; then
      #echo /sbin/iptables -A ${rule}
      /sbin/iptables -A ${rule}
   #else
      #echo have ${rule}
   fi
}

addIfNotExistNAT()
{
   local rule="${1}"
   #echo rule=${rule}
   if ! /sbin/iptables -t nat -C ${rule} 2>/dev/null; then
      #echo /sbin/iptables -t nat -A ${rule}
      /sbin/iptables -t nat -A ${rule}
   #else
      #echo have ${rule}
   fi
}


nm-online -s >/dev/null
SEPTENTRIO_UUID=`nmcli --fields UUID,DEVICE con show --active | grep septentrio | awk -F ' ' '{print $1}'`
if [[ -n "${SEPTENTRIO_UUID}" ]]; then
   SEPTENTRIO_IP="${SEPTENTRIO_STANDART_IP}"
   SEPTENTRIO_NET="${SEPTENTRIO_IP}/32"
   SEPTENTRIO_HOST="192.168.3.2/24"
   old_ip=`nmcli  --fields ipv4.addresses connection show uuid "${SEPTENTRIO_UUID}" | awk -F ' ' '{print $2}'`
   if [[ "${old_ip}" != "${SEPTENTRIO_HOST}" ]]; then
      #echo old_ip=${old_ip} SEPTENTRIO_HOST=${SEPTENTRIO_HOST}
      nmcli connection modify uuid "${SEPTENTRIO_UUID}" ipv4.addresses "${SEPTENTRIO_HOST}"  ipv4.gateway ""   ipv4.dns ""   ipv4.method "manual"
      nmcli connection down uuid "${SEPTENTRIO_UUID}"
      nmcli --wait 3 connection up uuid "${SEPTENTRIO_UUID}"
   fi
fi

MOBILE_USB=`lsusb | grep Mobile`
if [[ -n ${MOBILE_USB} ]] || [[ -L /sys/class/net/mobile ]]; then
   for i in `seq 1 15`; do
       MOBILE_UUID=`nmcli --fields UUID,DEVICE con show | grep mobile | awk -F ' ' '{print $1}'`
       if [[ -n "${MOBILE_UUID}" ]]; then
          break
       else
          sleep 1
       fi
   done
fi

if [[ -n "${MOBILE_UUID}" ]]; then
   MOBILE_STATE=`nmcli --fields STATE,DEVICE con show | grep mobile | awk -F ' ' '{print $1}'`
   #echo MOBILE_STATE=${MOBILE_STATE}
   if [[ "${MOBILE_STATE}" != "activated" ]]; then
      nmcli --wait 3 connection up uuid "${MOBILE_UUID}"
   fi
   for i in `seq 1 15`; do
       MOBILE_IP=`nmcli --fields ip4.gateway connection show "${MOBILE_UUID}" | awk -F ' ' '{print $2}'`
       #echo i=${i} MOBILE_IP=${MOBILE_IP}
       if [[ "${MOBILE_IP}" == "--" ]]; then
          MOBILE_IP=""
       fi
       if [[ -n "${MOBILE_IP}" ]]; then
          break
       else
          sleep 1
       fi
   done
fi

needChange=NO

HAS_SEPTENTRIO_NAT=`/sbin/iptables -n -L -t nat | grep -c "${SEPTENTRIO_STANDART_IP}"`
#echo SEPTENTRIO_IP=${SEPTENTRIO_IP} HAS_SEPTENTRIO_NAT=${HAS_SEPTENTRIO_NAT}
if (( (${#SEPTENTRIO_IP} == 0) == (${HAS_SEPTENTRIO_NAT} == 0) )); then
   echo NAT for septentrio already setuped
else
   if [[ ${HAS_SEPTENTRIO_NAT} != 0 ]]; then
      echo drop NAT for septentrio
      delete_by_ip "${SEPTENTRIO_STANDART_IP}"
      delete_by_ip "${SEPTENTRIO_STANDART_NET}"
   else
      echo setup NAT for septentrio
   fi
   needChange=YES
fi

HAS_MOBILE_NAT=`/sbin/iptables -n -L -t nat | grep -c "${MOBILE_STANDART_IP}"`
#echo MOBILE_IP=${MOBILE_IP} MOBILE_UUID=${MOBILE_UUID} HAS_MOBILE_NAT=${HAS_MOBILE_NAT}
if (( ("${#MOBILE_IP}" == 0) == ("${HAS_MOBILE_NAT}" == 0) )); then
   echo NAT for mobile already setuped
else
   if [[ ${HAS_MOBILE_NAT} != 0 ]]; then
      echo drop NAT for mobile
      delete_by_ip "${MOBILE_STANDART_IP}"
   else
      echo setup NAT for mobile
   fi
   needChange=YES
fi

HOTSPOT=Hotspot
HAVE_HOTSPOT=`nmcli --get-values NAME connection show --activ | grep ${HOTSPOT}`
HAS_HOTSPOT=`iptables-save | grep -c "wlan0"`
#echo HAVE_HOTSPOT=${HAVE_HOTSPOT} HAS_HOTSPOT=${HAS_HOTSPOT}
if (( ("${#HAVE_HOTSPOT}" == 0) == ("${HAS_HOTSPOT}" == 0) )); then
   echo NAT for hotspot already setuped
else
   if [[ ${HAS_HOTSPOT} != 0 ]]; then
      echo drop NAT for hotspot
      delete_by_ip "wlan0"
   else
      echo setup NAT for hotspot
      delete_by_ip "${SEPTENTRIO_STANDART_NET}"
   fi
   needChange=YES
fi

if /sbin/iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
   echo NAT already intited
else
   echo NAT not yet intited
   needChange=YES
fi

#echo MOBILE_IP="${MOBILE_IP}" SEPTENTRIO_IP="${SEPTENTRIO_IP}"
if [[ "${needChange}" == "YES" ]]; then
   echo -- Setting up redirections --
   echo 1 >/proc/sys/net/ipv4/ip_forward
   #/sbin/iptables -F
   #/sbin/iptables -X
   #/sbin/iptables -t nat -F
   #/sbin/iptables -t nat -X
   /sbin/iptables -P FORWARD DROP
   addIfNotExist "FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT"
else
   exit 0
fi

if [[ -n "${HAVE_HOTSPOT}" ]]; then
   if [[ -n "${SEPTENTRIO_IP}" ]]; then
      addIfNotExistNAT "POSTROUTING ! -o wlan0 ! -d ${SEPTENTRIO_NET} -j MASQUERADE"
      addIfNotExist "FORWARD -i wlan0 -d ${SEPTENTRIO_NET} -j ACCEPT"    # wlan0 -> Septentrio
      addIfNotExist "FORWARD -s ${SEPTENTRIO_NET} ! -o wlan0 -j ACCEPT"  # Septentrio -> Internet
   else
      iptables -t nat -A POSTROUTING ! -o wlan0 -j MASQUERADE
   fi
   iptables -A FORWARD -i wlan0 ! -o wlan0 -j ACCEPT
else
   if [[ -n "${SEPTENTRIO_IP}" ]]; then
      addIfNotExistNAT "POSTROUTING -s ${SEPTENTRIO_NET} -j MASQUERADE"
      addIfNotExist "FORWARD -s ${SEPTENTRIO_NET} -j ACCEPT"
   fi
fi

while read PROTO ORIGPORT NATTOADDR NATTOPORT COMMENT
do
  if ! ( echo "${PROTO}" | grep -Eq '(#.*)|(^$)' ) ; then
     if [[ "${NATTOPORT}" != "" ]]; then
        echo "    PROTO=${PROTO} ORIGPORT=${ORIGPORT} TOADDR=${NATTOADDR} TOPORT=${NATTOPORT}"
        addIfNotExistNAT "PREROUTING -p ${PROTO} --destination-port ${ORIGPORT} ! -s ${NATTOADDR}/32 -j DNAT --to-destination ${NATTOADDR}:${NATTOPORT}"
        addIfNotExistNAT "POSTROUTING -d ${NATTOADDR} -p ${PROTO} --destination-port ${NATTOPORT} -j MASQUERADE"
        addIfNotExist "FORWARD -d ${NATTOADDR} -p ${PROTO} --destination-port ${NATTOPORT} -j ACCEPT"
     fi
  fi
done <<EOF

# Septentrio Web server
#tcp 8080 ${SEPTENTRIO_IP} 80
#tcp 443 ${SEPTENTRIO_IP} 443

# Mosaic Settings
tcp 28784 ${SEPTENTRIO_IP} 28784

# NTP server
udp 123 ${SEPTENTRIO_IP} 123

# PTP server
udp 319 ${SEPTENTRIO_IP} 319
udp 320 ${SEPTENTRIO_IP} 320

# FTP server
#tcp 21 ${SEPTENTRIO_IP} 21

# work tcp ports
tcp 3000 ${SEPTENTRIO_IP} 3000
tcp 3001 ${SEPTENTRIO_IP} 3001
tcp 3002 ${SEPTENTRIO_IP} 3002
tcp 3003 ${SEPTENTRIO_IP} 3003
tcp 3004 ${SEPTENTRIO_IP} 3004
tcp 3005 ${SEPTENTRIO_IP} 3005
tcp 3006 ${SEPTENTRIO_IP} 3006
tcp 3007 ${SEPTENTRIO_IP} 3007
tcp 3008 ${SEPTENTRIO_IP} 3008
tcp 3009 ${SEPTENTRIO_IP} 3009

# work udp ports
udp 3000 ${SEPTENTRIO_IP} 3000
udp 3001 ${SEPTENTRIO_IP} 3001
udp 3002 ${SEPTENTRIO_IP} 3002
udp 3003 ${SEPTENTRIO_IP} 3003
udp 3004 ${SEPTENTRIO_IP} 3004
udp 3005 ${SEPTENTRIO_IP} 3005
udp 3006 ${SEPTENTRIO_IP} 3006
udp 3007 ${SEPTENTRIO_IP} 3007
udp 3008 ${SEPTENTRIO_IP} 3008
udp 3009 ${SEPTENTRIO_IP} 3009

# Mobile Web server
tcp 7080 ${MOBILE_IP} 80
#tcp 7443 ${MOBILE_IP} 443

EOF

echo -- FINISHED --
exit 0
