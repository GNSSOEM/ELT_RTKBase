#!/bin/bash
HAVE_ELT0x33=`find -P /dev/serial/by-id -name "*ELT0x33*" 2>/dev/null`
HAVE_MOSAIC=`find -P /dev/serial/by-id -name "*Septentrio*" 2>/dev/null`
#echo HAVE_ELT0x33=${HAVE_ELT0x33} HAVE_MOSAIC=${HAVE_MOSAIC}
if [[ "${HAVE_ELT0x33}" == "" ]] && [[ "${HAVE_MOSAIC}" != "" ]]; then
   if [[ -c /dev/ttyGNSS_CTRL ]]; then
      device=`readlink -f /dev/ttyGNSS_CTRL`
      BASEDIR="$(dirname $(dirname "$0"))"
      #echo "${BASEDIR}"/NmeaConf "${device}" "setDataInOut,USB1,CMD,none" QUIET
      "${BASEDIR}"/NmeaConf "${device}" "setDataInOut,USB1,CMD,none" QUIET
   fi
fi
