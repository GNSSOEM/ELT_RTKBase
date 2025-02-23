#!/bin/bash

#echo Start ${0} ${1} ${2}
if [[ "${1}" == "" ]]; then
   echo Need device name as parameter. For example \"${0} ttyUSB0 ON\"
   exit
fi

HAVE_ELT0x33=`find -P /dev/serial/by-id -name "*ELT0x33*"`
#echo HAVE_ELT0x33=${HAVE_ELT0x33}
if [[ "${HAVE_ELT0x33}" == "" ]]; then
   exit
fi

if [[ "${1}" == "SETTINGS" ]]; then
   BASEDIR="$(dirname $(dirname "$0"))"
   source <( grep '^com_port=' "${BASEDIR}"/settings.conf ) #import settings
   #echo BASEDIR=${BASEDIR} com_port=${com_port}
   if [[ "${com_port}" == "" ]]; then
      echo com_port NOT read from "${BASEDIR}"/settings.conf
      exit
   fi
else
   com_port="${1}"
fi

if [ ! -c /dev/"${com_port}" ]; then
   echo /dev/"${com_port}" NOT exists
   exit
fi

for sysdevpath in $(find /sys/bus/usb/devices/usb*/ -name ${com_port}); do
    syspath="${sysdevpath%/${com_port}}"
    dirpath=$(dirname ${syspath})
    #echo sysdevpath=${sysdevpath} syspath=${syspath} dirpath=${dirpath}
    for productpath in $(find ${dirpath} -name product); do
       product=`cat ${productpath}`
       #echo productpath=${productpath} product=${product}
       if [[ "${product}" == "ELT0x33" ]]; then
          gpiochip=`find ${dirpath}/*/gpiochip* -name  "gpiochip*"`
          #echo gpiochip=${gpiochip}
          if [[ "${gpiochip}" != "" ]]; then
             CHIP=`echo ${gpiochip} | sed s/^.*gpiochip//`
             #echo CHIP=${CHIP}
             value=0
             if [[ "${2}" == "ON" ]]; then
                value=1
             fi
             echo gpioset gpiochip${CHIP} 3=${value} \# for ${com_port}
             gpioset gpiochip${CHIP} 3=${value}
             exit
          fi
       fi
    done
done
