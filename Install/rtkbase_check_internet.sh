#!/bin/bash

#We work only on Pi4 with USB devices in Type C.
HAVE_PI4=`cat /proc/cpuinfo | grep Model | grep "Pi 4"`
HAVE_TYPEC=`lsusb | grep "Bus 003" | grep -v "root hub"`
HAVE_DEB12=`lsb_release -c | grep bookworm`
HAVE_ELT0x33=`find -P /dev/serial/by-id -name "*ELT0x33*"`
if [[ "${HAVE_ELT0x33}" == "" ]]; then
   if [[ "${HAVE_PI4}" != "" ]] && [[ "${HAVE_TYPEC}" != "" ]] && [[ "${HAVE_DEB12}" != "" ]]; then
      USE_FTDI=N
      GPIO=16
   fi
else
   for sysdevpath in $(find /sys/bus/usb/devices/usb*/ -name product); do
       product=`cat ${sysdevpath}`
       if [[ "${product}" == "ELT0x33" ]]; then
          syspath="${sysdevpath%/product}"
          #echo syspath=${syspath}
          #echo find ${syspath}/*/gpiochip* -name  "gpiochip*"
          gpiochip=`find ${syspath}/*/gpiochip* -name  "gpiochip*"`
          #echo gpiochip=${gpiochip}
          if [[ "${gpiochip}" != "" ]]; then
             CHIP=`echo ${gpiochip} | sed s/^.*gpiochip//`
             #echo CHIP=${CHIP}
             USE_FTDI=Y
             GPIO=2
         fi
       fi
   done
fi

if [[ "${USE_FTDI}" == "" ]]; then
   echo No PI4 or no Debian 12 or haven\'t USB device in type-C or no ELT0x33
   echo HAVE_PI4=${HAVE_PI4} HAVE_TYPEC=${HAVE_TYPEC} HAVE_DEB12=${HAVE_DEB12} HAVE_ELT0x33=${HAVE_ELT0x33}
   systemctl stop rtkbase_check_internet.service
   exit 0
fi

#echo USE_FTDI="${USE_FTDI}" GPIO="${GPIO}" CHIP="${CHIP}"

set_gpio(){
if [[ "${USE_FTDI}" = "Y" ]]; then
   gpioset gpiochip${CHIP} ${GPIO}=${1}
else
   pinctrl set ${GPIO} ${2} ${3}
fi
}

FLAG=/usr/local/rtkbase/NetworkChange.flg
state=DOWN
set_gpio 0 op dl

while : ; do
   #echo ping -4 -c 1 -W 1 -q 8.8.8.8 \>/dev/null 2\>\&1
   ping -4 -c 1 -W 1 -q 8.8.8.8 >/dev/null 2>&1
   lastcode=$?
   if [[ ${lastcode} == 0 ]]; then
      newstate=UP
   else
      newstate=DOWN
   fi

   if [[ "${newstate}" != "${state}" ]]; then
      if [ "${newstate}" == "UP" ]; then
         echo Internet UP
         set_gpio 1 dh
      else
         echo Internet DOWN
         set_gpio 0 dl
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
