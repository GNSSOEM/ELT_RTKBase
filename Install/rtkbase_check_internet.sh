#!/bin/bash

#We work only on Pi4 with USB devices in Type C.
HAVE_PI4=`cat /proc/cpuinfo | grep Model | grep "Pi 4"`
HAVE_TYPEC=`lsusb | grep "Bus 003" | grep -v "root hub"`
HAVE_DEB12=`lsb_release -c | grep bookworm`
if [[ "${HAVE_PI4}" == "" ]] || [[ "${HAVE_TYPEC}" == "" ]] || [[ "${HAVE_DEB12}" == "" ]]; then
   echo No PI4 or no Debian 12 or haven\'t USB device in type-C
   echo HAVE_PI4=${HAVE_PI4} HAVE_TYPEC=${HAVE_TYPEC} HAVE_DEB12=${HAVE_DEB12}
   systemctl stop rtkbase_check_internet.service
   exit 0
fi

FLAG=/usr/local/rtkbase/NetworkChange.flg
GPIO=16
pinctrl set ${GPIO} op dl
state=DOWN

while : ; do
   #echo ping -4 -c 1 -W 1 -q 8.8.8.8 \>/dev/null
   ping -4 -c 1 -W 1 -q 8.8.8.8 >/dev/null
   lastcode=$?
   if [[ ${lastcode} == 0 ]]; then
      newstate=UP
   else
      newstate=DOWN
   fi

   if [[ "${newstate}" != "${state}" ]]; then
      if [ "${newstate}" == "UP" ]; then
         echo Internet UP
         pinctrl set ${GPIO} dh
      else
         echo Internet DOWN
         pinctrl set ${GPIO} dl
      fi
      state=${newstate}
   fi

   for i in `seq 1 5`; do
      if [[ -f ${FLAG} ]]; then
         cat ${FLAG}
         rm -f ${FLAG}
         break
      fi
      sleep 1
   done
done
exit 1
