#!/bin/bash

BASEDIR=`dirname $(realpath $(dirname "$0"))`
if [[ -z ${rtkbase_path} ]]; then
   if grep -q '^rtkbase_path=' /etc/environment; then
      source /etc/environment
   else 
      rtkbase_path=${BASEDIR}
   fi
fi
#echo BASEDIR=${BASEDIR} rtkbase_path=${rtkbase_path}

source <( grep -v '^#' "${rtkbase_path}"/settings.conf | grep '=' ) #import settings

if [[ ! "${receiver}" =~ Unicore* ]] && [[ ! "${receiver}" =~ Septentrio ]]; then
   echo Receiver ${receiver} NOT reboted!
   exit 1
fi

#We work only on Pi4
HAVE_PI4=`cat /proc/cpuinfo | grep Model | grep "Pi 4"`
HAVE_DEB12=`lsb_release -c | grep bookworm`
HAVE_ELT0x33=`find -P /dev/serial/by-id -name "*ELT0x33*" 2>/dev/null`
if [[ "${HAVE_ELT0x33}" != "" ]] || [[ "${HAVE_PI4}" == "" ]] || [[ "${HAVE_DEB12}" == "" ]]; then
   echo Receiver ${receiver} NOT reboted! HAVE_ELT0x33=${HAVE_ELT0x33} HAVE_PI4=${HAVE_PI4} HAVE_DEB12=${HAVE_DEB12}
   exit 2
fi

GPIO=8
pinctrl set ${GPIO} op dl
sleep 0.2
pinctrl set ${GPIO} op dh
echo Receiver reboted
exit 0
