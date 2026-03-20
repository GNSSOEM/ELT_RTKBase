#!/bin/bash

is_packet_not_installed(){
   instaled=`dpkg-query -l ${1} 2>/dev/null | grep ${1}|awk -F ' ' '{print $1}'`
   #echo 1=${1} instaled=${instaled}
   if [[ ${instaled} == "ii" ]]; then
      return 1
   fi
}

SetConf() {
  #echo grep -q \"^${1}=$2\" "${3}"
  if ! grep -q "^${1}=${2}" "${3}"; then
     echo sed -i \"s/^${1}=.*/${1}=$2/\"  "${3}"
     sed -i "s/^${1}=.*/${1}=$2/" "${3}"
  fi
}

SER2NET_NAIN_CONF=/etc/default/ser2net
SER2NET_CONF=/etc/ser2net.conf

AddDevice() {
   echo 23${2}1:raw:0:/dev/${1}:9600 >>${SER2NET_CONF}
   echo 23${2}2:raw:0:/dev/${1}:38400 >>${SER2NET_CONF}
   echo 23${2}3:raw:0:/dev/${1}:115200 >>${SER2NET_CONF}
   echo 23${2}4:raw:0:/dev/${1}:230400 >>${SER2NET_CONF}
   echo 23${2}5:raw:0:/dev/${1}:460800 >>${SER2NET_CONF}
   echo 23${2}6:raw:0:/dev/${1}:921600 >>${SER2NET_CONF}
}


is_packet_not_installed ser2net && apt-get install -q -y ser2net >/dev/null 2>&1

rm ${SER2NET_CONF}
nn=10
for port in ttyACM0 ttyACM1 ttyUSB0 ttyUSB1 ttyUSB2; do
    if [[ -c /dev/${port} ]]; then
       AddDevice ${port} ${nn}
    fi
    let nn=nn+1
done

if ! grep -q "^CONFFILE=${SER2NET_CONF}" "${SER2NET_NAIN_CONF}"; then
   sed -i "s/^CONFFILE=.*/CONFFILE=\/etc\/ser2net\.conf/" "${SER2NET_NAIN_CONF}"
fi

systemctl restart ser2net.service

cat ${SER2NET_CONF}

if [[ ${1} == "-s" ]]; then
   exit 254
fi
