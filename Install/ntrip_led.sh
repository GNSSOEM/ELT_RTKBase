#!/bin/bash

#LOG=${0}.log
#date=`date`
#echo ${date} -- ${0} ${1} ${2} >>${LOG}

if [[ "${1}" != "A" ]]; then
   exit
fi

case "$2" in
    CONNECTED)
        value=ON
        ;;
    DISCONNECT)
        value=OFF
        ;;
    *)
        exit
        ;;
esac

HAVE_ELT0x33=`find -P /dev/serial/by-id -name "*ELT0x33*"`
#echo HAVE_ELT0x33=${HAVE_ELT0x33}
if [[ "${HAVE_ELT0x33}" == "" ]]; then
   exit
fi

BASEDIR="$(dirname "$0")"
#echo ${BASEDIR}/onoffELT0x33.sh SETTINGS ${value} 0 >>${LOG}
${BASEDIR}/onoffELT0x33.sh SETTINGS ${value} 0
