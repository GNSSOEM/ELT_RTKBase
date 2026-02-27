#!/bin/bash


is_packet_not_installed(){
   instaled=`dpkg-query -l ${1} 2>/dev/null | grep ${1}|awk -F ' ' '{print $1}'`
   #echo 1=${1} instaled=${instaled}
   if [[ ${instaled} == "ii" ]]; then
      return 1
   fi
}

is_packet_not_installed dnsutils && apt-get install -q -y dnsutils >/dev/null 2>&1

nmcli dev show | grep -e "TYPE\|DNS"
echo =======================
RESOLV_CONF=/etc/resolv.conf
if [[ -f ${RESOLV_CONF} ]]; then
   cat ${RESOLV_CONF}
   echo =======================
fi
nslookup servers.onocoy.com

if [[ ${1} == "-s" ]]; then
   exit 254
fi
