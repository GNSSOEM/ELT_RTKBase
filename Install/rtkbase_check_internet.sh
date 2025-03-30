#!/bin/bash

#We work only on Pi4 with USB devices in Type C.
HAVE_PI4=`cat /proc/cpuinfo | grep Model | grep "Pi 4"`
HAVE_ZERO=`cat /proc/cpuinfo | grep Model | grep "Pi Zero 2 W"`
HAVE_TYPEC=`lsusb | grep "Bus 003" | grep -v "root hub"`
HAVE_DEB12=`lsb_release -c | grep bookworm`
HAVE_ELT0x33=`find -P /dev/serial/by-id -name "*ELT0x33*" 2>/dev/null`
HAVE_MOSAIC=`find -P /dev/serial/by-id -name "*Septentrio*" 2>/dev/null`
#echo HAVE_ELT0x33=${HAVE_ELT0x33} HAVE_MOSAIC=${HAVE_MOSAIC}
if [[ "${HAVE_ELT0x33}" == "" ]] && [[ "${HAVE_PI4}" != "" ]] && [[ "${HAVE_TYPEC}" != "" ]] && [[ "${HAVE_DEB12}" != "" ]]; then
   USE_FTDI=N
   GPIO=16
elif [[ "${HAVE_ELT0x33}" != "" ]] && [[ "${HAVE_MOSAIC}" == "" ]]; then
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
             GPIO=1
         fi
       fi
   done
elif [[ "${HAVE_ELT0x33}" == "" ]] && [[ "${HAVE_MOSAIC}" != "" ]] && [[ "${HAVE_ZERO}" != "" ]]; then
   USE_FTDI=M
   GPIO=1
   MOSAIC=`readlink -f /dev/ttyGNSS_CTRL`
   stty -F ${MOSAIC} 115200
fi

if [[ "${USE_FTDI}" == "" ]]; then
   echo No PI4 or no Debian 12 or haven\'t USB device in type-C or no ELT0x33 or no ELT0733
   #echo HAVE_PI4=${HAVE_PI4} HAVE_ZERO=${HAVE_ZERO} HAVE_TYPEC=${HAVE_TYPEC} HAVE_DEB12=${HAVE_DEB12} HAVE_ELT0x33=${HAVE_ELT0x33} HAVE_MOSAIC=${HAVE_MOSAIC}
   systemctl stop rtkbase_check_internet.service
   exit 0
fi

#echo USE_FTDI="${USE_FTDI}" GPIO="${GPIO}" CHIP="${CHIP}"

set_gpio(){
if [[ "${USE_FTDI}" = "Y" ]]; then
   gpioset gpiochip${CHIP} ${GPIO}=${1}
elif [[ "${USE_FTDI}" = "M" ]]; then
   if [[ "${1}" == "1" ]]; then
      value=LevelHigh
   else
      value=LevelLow
   fi
   for i in `seq 1 5`; do
      #echo RESULT=\`/usr/local/rtkbase/rtkbase/NmeaConf ${MOSAIC} \"setGPIOFunctionality,GP${CHIP},Output,none,${value}\" QUIET\`
      RESULT=`/usr/local/rtkbase/rtkbase/NmeaConf ${MOSAIC} "setGPIOFunctionality,GP${GPIO},Output,none,${value}" QUIET`
      lastcode=$?
      if [[ "${lastcode}" != "0" ]]; then
         echo ${lastcode}:${RESULT}
         #sudo lsof ${MOSAIC}
         if [[ "${lastcode}" != "4" ]]; then
            break
         fi
      else
         #echo set $1 to GP${GPIO}
         break
      fi
   done
   return ${lastcode}
else
   if [[ "${1}" == "1" ]]; then
      pinctrl set ${GPIO} op dh
   else
      pinctrl set ${GPIO} op dl
   fi
fi
}

FLAG=/usr/local/rtkbase/NetworkChange.flg
WPS_FLAG=/usr/local/rtkbase/WPS.flg
wasWPS=

while : ; do

   if [[ -f ${FLAG} ]]; then
      cat ${FLAG}
      rm -f ${FLAG}
   fi

   if [[ -f ${WPS_FLAG} ]]; then
      if [[ "${wasWPS}" == "" ]]; then
         echo WPS started
         wasWPS=YES
      fi
      set_gpio 0
      sleep 0.5
      set_gpio 1
      sleep 0.5
   elif [[ "${wasWPS}" != "" ]]; then
      echo WPS finished
      wasWPS=
   else

      #echo ping -4 -c 1 -W 1 -q 8.8.8.8 \>/dev/null 2\>\&1
      ping -4 -c 1 -W 1 -q 8.8.8.8 >/dev/null 2>&1
      lastcode=$?
      if [[ "${lastcode}" == "0" ]]; then
         newstate=UP
         CNT=5
      else
         newstate=DOWN
         CNT=1
      fi

      if [[ "${newstate}" != "${showstate}" ]]; then
         echo Internet ${newstate}
         showstate=${newstate}
      fi

      if [[ "${newstate}" != "${state}" ]]; then
         if [ "${newstate}" == "UP" ]; then
            set_gpio 1
         else
            set_gpio 0
         fi
         if [[ "$?" == "0" ]]; then
            state=${newstate}
         else
            #echo \$\?=$?
            sleep 1
            continue
         fi
      fi

      for i in `seq 1 ${CNT}`; do
         if [[ -f ${FLAG} ]]; then
            cat ${FLAG}
            rm -f ${FLAG}
            break
         fi
         if [[ -f ${WPS_FLAG} ]]; then
            break
         fi
         sleep 1
      done
   fi
done
exit 1
