#!/bin/bash

HAVE_ELT0x33=`find -P /dev/serial/by-id -name "*ELT0x33*" 2>/dev/null`
if [[ "${HAVE_ELT0x33}" != "" ]]; then
   for sysdevpath in $(find /sys/bus/usb/devices/usb*/ -name product); do
       product=`cat ${sysdevpath}`
       if [[ "${product}" == "ELT0x33" ]]; then
          syspath="${sysdevpath%/product}"
          #echo find ${syspath}/*/gpiochip* -name  "gpiochip*"
          gpiochip=`find ${syspath}/*/gpiochip* -name  "gpiochip*"`
          #echo gpiochip=${gpiochip}
          if [[ "${gpiochip}" != "" ]]; then
             CHIP=`echo ${gpiochip} | sed s/^.*gpiochip/gpiochip/`
             BASEDIR="$(dirname "$0")"
             tcp_port=5015
             source <( grep -v '^#' "${BASEDIR}"/rtkbase/settings.conf | grep 'tcp_port=' ) #import settings
             GPIO=2
             #echo CHIP=${CHIP} BASEDIR=${BASEDIR} tcp_port=${tcp_port} GPIO=${GPIO}
             echo "${BASEDIR}"/Rtcm3Led +localhost:${tcp_port} ${CHIP} ${GPIO} \&
             "${BASEDIR}"/Rtcm3Led +localhost:${tcp_port} ${CHIP} ${GPIO} &
             USE_FTDI=Y
         fi
       fi
   done
fi

if [[ "${USE_FTDI}" == "" ]]; then
   echo No ELT0x33 and no gpiochip found HAVE_ELT0x33=${HAVE_ELT0x33}
   systemctl stop rtkbase_check_satelites.service
   exit 0
fi

