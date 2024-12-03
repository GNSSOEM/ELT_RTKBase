#!/bin/bash

BASEDIR="$(dirname "$0")"
source <( grep '^receiver=' "${BASEDIR}"/settings.conf ) #import settings
#echo receiver=${receiver}

if [[ ! "${receiver}" =~ Septentrio ]]; then
   echo NAT for ${receiver} NOT needed
   exit
fi

SEPTENTRIO_IP="192.168.3.1"
SEPTENTRIO_NET="${SEPTENTRIO_IP}/32"
SEPTENTRIO_HOST="192.168.3.2/24"

UUID=`nmcli --fields UUID,DEVICE con show | grep usb0 | awk -F ' ' '{print $1}'`
if [[ "${UUID}" != "" ]]; then
   old_ip=`nmcli connection show uuid "${UUID}" | grep "ipv4.addresses:" | awk -F ' ' '{print $2}'`
   if [[ "${old_ip}" != "${SEPTENTRIO_HOST}" ]]; then
      echo old_ip=${old_ip} SEPTENTRIO_HOST=${SEPTENTRIO_HOST}
      nmcli connection modify uuid "${UUID}" ipv4.addresses "${SEPTENTRIO_HOST}"  ipv4.gateway ""   ipv4.dns ""   ipv4.method "manual"
      nmcli connection down uuid "${UUID}"
      nmcli --wait 3 connection up uuid "${UUID}"
   fi
fi

HAS_NAT=`/sbin/iptables -n -L -t nat | grep -c ${SEPTENTRIO_IP}`
#echo HAS_NAT=${HAS_NAT}
if [[ ${HAS_NAT} > 0 ]]; then
   echo NAT for ${SEPTENTRIO_IP} already setuped
   exit
fi

echo -- Setting up redirections --
echo 1 >/proc/sys/net/ipv4/ip_forward

#echo /sbin/iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
/sbin/iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
#echo /sbin/iptables -t nat -A POSTROUTING -s ${SEPTENTRIO_NET} -j MASQUERADE
/sbin/iptables -t nat -A POSTROUTING -s ${SEPTENTRIO_NET} -j MASQUERADE
#echo /sbin/iptables -A FORWARD -s ${SEPTENTRIO_NET} -j ACCEPT
/sbin/iptables -A FORWARD -s ${SEPTENTRIO_NET} -j ACCEPT


while read PROTO ORIGPORT NATTOADDR NATTOPORT COMMENT
do
  if ! ( echo "${PROTO}" | grep -Eq '(#.*)|(^$)' )
  then
    echo "    PROTO=${PROTO} ORIGPORT=${ORIGPORT} TOADDR=${NATTOADDR} TOPORT=${NATTOPORT}"
    /sbin/iptables -t nat -A PREROUTING -p ${PROTO} --destination-port ${ORIGPORT} ! -s ${SEPTENTRIO_NET} -j DNAT --to-destination ${NATTOADDR}:${NATTOPORT}
    /sbin/iptables -t nat -A POSTROUTING -d ${NATTOADDR} -p ${PROTO} --destination-port ${NATTOPORT} -j MASQUERADE
    /sbin/iptables -A FORWARD -d ${NATTOADDR} -p ${PROTO} --destination-port ${NATTOPORT} -j ACCEPT
  fi
done <<EOF

# Web server
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
tcp 21 ${SEPTENTRIO_IP} 21

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

EOF

echo -- FINISHED --
exit 0
