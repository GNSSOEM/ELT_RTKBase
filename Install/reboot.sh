#!/bin/bash
HAVE_ELT0x33=`find -P /dev/serial/by-id -name "*ELT0x33*" 2>/dev/null`
HAVE_MOSAIC=`find -P /dev/serial/by-id -name "*Septentrio*" 2>/dev/null`
#echo HAVE_ELT0x33=${HAVE_ELT0x33} HAVE_MOSAIC=${HAVE_MOSAIC}
if [[ "${HAVE_ELT0x33}" == "" ]] && [[ "${HAVE_MOSAIC}" != "" ]]; then
   if [[ -c /dev/ttyGNSS_CTRL ]]; then
      MOSAIC=`readlink -f /dev/ttyGNSS_CTRL`
      BASEDIR="$(dirname $(dirname "$0"))"
      for i in `seq 1 5`; do
          #echo "${BASEDIR}"/NmeaConf "${MOSAIC}" "setDataInOut,USB1,CMD,none" QUIET
          "${BASEDIR}"/NmeaConf "${MOSAIC}" "setDataInOut,USB1,CMD,none" QUIET
          if [[ "$?" == "0" ]]; then
             break
         fi
      done
      for i in `seq 1 5`; do
          #echo "${BASEDIR}"/NmeaConf "${MOSAIC}" "setGPIOFunctionality,all,Output,none,LevelLow" QUIET
          "${BASEDIR}"/NmeaConf "${MOSAIC}" "setGPIOFunctionality,all,Output,none,LevelLow" QUIET
          if [[ "$?" == "0" ]]; then
             break
         fi
      done
   fi
fi
