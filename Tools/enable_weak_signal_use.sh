#!/bin/bash

PPPCONF=/usr/local/rtkbase/rtkbase/web_app/rtklib_configs/rtkbase_ppp-static_default.conf

SetConf() {
  #echo grep -q \"^${1}=\'$2\'\" "${PPPCONF}"
  if ! grep -q "^${1} *=${2}" "${PPPCONF}"; then
     echo sed -i \"s/^${1} *=.*/${1}=$2/\"
     sed -i "s/^${1} *=.*/${1}=$2/" "${PPPCONF}"
     CHANGED=Y
  fi
}

SetConf "pos1-snrmask_r"  "off        # (0:off,1:on)"
SetConf "pos1-snrmask_b"  "off        # (0:off,1:on)"
SetConf "pos1-snrmask_L1" "0,0,0,0,0,0,0,0,0"
SetConf "pos1-snrmask_L2" "0,0,0,0,0,0,0,0,0"
SetConf "pos1-snrmask_L5" "0,0,0,0,0,0,0,0,0"

if [[ -n ${CHANGED} ]]; then
   HAVERTK=`ps -A | grep rtkrcv`
   #echo HAVERTK=${HAVERTK}
   if [[ -n ${HAVERTK} ]]; then
      killall rtkrcv
      echo rtkrcv killed
   fi
fi

if [[ ${1} == "-s" ]]; then
   exit 254
fi
