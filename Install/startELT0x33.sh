#!/bin/bash

#date >>/usr/local/rtkbase/elt0x33.log
HAVE_ELT0x33=`find -P /dev/serial/by-id -name "*ELT0x33*"`
HAVE_MOSAIC=`find -P /dev/serial/by-id -name "*Septentrio*"`
#echo HAVE_ELT0x33=${HAVE_ELT0x33} HAVE_MOSAIC=${HAVE_MOSAIC}  >>/usr/local/rtkbase/elt0x33.log
if [[ "${HAVE_ELT0x33}" == "" ]] && [[ "${HAVE_MOSAIC}" == "" ]]; then
   exit
fi
#echo go >>/usr/local/rtkbase/elt0x33.log

if [[ "${HAVE_ELT0x33}" == "" ]] && [[ "${HAVE_MOSAIC}" != "" ]]; then
   #echo RESULT=\`/usr/local/rtkbase/rtkbase/NmeaConf /dev/ttyACM1 \"setGPIOFunctionality,all,Output,none,LevelLow\" QUIET\`
   RESULT=`/usr/local/rtkbase/rtkbase/NmeaConf /dev/ttyACM1 "setGPIOFunctionality,all,Output,none,LevelLow" QUIET`
   if [[ "$?" != "0" ]]; then
      echo ${RESULT}
   fi
else
  for sysdevpath in $(find /sys/bus/usb/devices/usb*/ -name product); do
      product=`cat ${sysdevpath}`
      #echo product=${product} >>/usr/local/rtkbase/elt0x33.log
      if [[ "${product}" == "ELT0x33" ]]; then
         syspath="${sysdevpath%/product}"
         #echo syspath=${syspath} >>/usr/local/rtkbase/elt0x33.log
         #echo find ${syspath}/*/gpiochip* -name  "gpiochip*"
         gpiochip=`find ${syspath}/*/gpiochip* -name  "gpiochip*"`
         #echo gpiochip=${gpiochip} >>/usr/local/rtkbase/elt0x33.log
         if [[ "${gpiochip}" != "" ]]; then
            CHIP=`echo ${gpiochip} | sed s/^.*gpiochip//`
            #echo CHIP=${CHIP} >>/usr/local/rtkbase/elt0x33.log
            gpioset gpiochip${CHIP} 0=0
            gpioset gpiochip${CHIP} 1=0
            gpioset gpiochip${CHIP} 2=0
        fi
      fi
  done
fi