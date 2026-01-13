#!/bin/bash

#echo Start ${0} ${1} ${2} ${3}
if [[ "${1}" == "" ]]; then
   echo Need device name or SETTINGS as parameter. For example \"${0} ttyUSB0 ON 0\", \"${0} SETTINGS OFF 1\"
   exit 0
fi

HAVE_ELT0x33=`find -P /dev/serial/by-id -name "*ELT0x33*" 2>/dev/null`
HAVE_MOSAIC=`find -P /dev/serial/by-id -name "*Septentrio*" 2>/dev/null`
#echo HAVE_ELT0x33=${HAVE_ELT0x33} HAVE_MOSAIC=${HAVE_MOSAIC}
if [[ "${HAVE_ELT0x33}" == "" ]]; then
   if [[ "${HAVE_MOSAIC}" == "" ]]; then
      #echo no ELT0x33 and no Mosaic
      exit 0
   fi
   HAVE_ZERO=`cat /proc/cpuinfo | grep Model | grep "Pi Zero 2 W"`
   HAVE_DEB12=`lsb_release -c | grep "bookworm\|trixie"`
   #echo HAVE_ZERO=${HAVE_ZERO} HAVE_DEB12=${HAVE_DEB12}
   if [[ "${HAVE_ZERO}" == "" ]] || [[ "${HAVE_DEB12}" == "" ]]; then
      #echo Mosaic and no Pi Zero 2 W or no Debian 12
      exit 0
   fi
fi

BASEDIR="$(dirname $(dirname "$0"))"
if [[ "${1}" == "SETTINGS" ]]; then
   source <( grep '^com_port=' "${BASEDIR}"/settings.conf ) #import settings
   #echo BASEDIR=${BASEDIR} com_port=${com_port}
   if [[ "${com_port}" == "" ]]; then
      echo com_port NOT read from "${BASEDIR}"/settings.conf or not setup in the settings
      exit 0
   fi
else
   com_port="${1}"
fi

if [ ! -c /dev/"${com_port}" ]; then
   echo /dev/"${com_port}" NOT exists
   exit 0
fi

if [[ "${HAVE_ELT0x33}" == "" ]] && [[ "${HAVE_MOSAIC}" != "" ]]; then
   if [[ "${3}" == "0" ]]; then
      pin=GP2 # RED - NTRIP
   elif [[ "${3}" == "1" ]]; then
      pin=GP1 # YELLOW - Internet
   else
      #echo no pin <${3}> in Mosaic
      exit 0
   fi
   if [[ "${2}" == "ON" ]]; then
      value=LevelHigh
   else
      value=LevelLow
   fi
   if [[ "${com_port}" == "ttyGNSS" ]] && [[ -c /dev/ttyGNSS_CTRL ]]; then
      device=`readlink -f /dev/ttyGNSS_CTRL`
   else
      origdevice=`readlink -f /dev/${com_port}`
      if [[ "${origdevice}" == "/dev/ttyACM0" ]]; then
         device="/dev/ttyACM1"
      elif [[ "${origdevice}" == "/dev/ttyACM1" ]]; then
         device="/dev/ttyACM0"
      else
         device="${origdevice}"
      fi
   fi
   #echo com_port=${com_port} origdevice=${origdevice} device=${device}
   for i in `seq 1 5`; do
       #echo RESULT=\`"${BASEDIR}"/NmeaConf "${device}" \"setGPIOFunctionality,${pin},Output,none,${value}\" QUIET\`
       RESULT=`"${BASEDIR}"/NmeaConf "${device}" "setGPIOFunctionality,${pin},Output,none,${value}" QUIET`
       exitcode=$?
       if [[ "${exitcode}" == "0" ]] || [[ ${exitcode} > 4 ]]; then
          break
       else
          echo ${exitcode}:${RESULT}
          #sudo lsof ${device}
       fi
   done
else
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
               if [[ "${2}" == "ON" ]]; then
                  value=1
               else
                  value=0
               fi
               if [[ "${3}" == "" ]]; then
                  pin=3
               else
                  pin=${3}
               fi

               if ! (gpioget -v | grep gpioget | grep -q v1); then
                  GPIOKEY="-t0 -c"
               fi
               #echo gpioset ${GPIOKEY} gpiochip${CHIP} ${pin}=${value} \# for ${com_port}
               gpioset ${GPIOKEY} gpiochip${CHIP} ${pin}=${value}
               if [[ "${pin}=${value}" == "3=1" ]]; then
                  #echo sleep 0.1
                  sleep 0.1
               fi
               exit 0
            fi
         fi
      done
  done
fi