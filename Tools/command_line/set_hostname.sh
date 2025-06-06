#!/bin/bash

RTKBASE_HOST=${1}

if [[ ${RTKBASE_HOST} == "" ]]
then
   echo Usage $0 NewHostName
   exit 1
fi

WHOAMI=`whoami`
if [[ ${WHOAMI} != "root" ]]
then
   #echo use sudo
   sudo ${0} ${1} 
   #echo exit after sudo
   exit
fi

HOSTNAME=/etc/hostname
HOSTS=/etc/hosts
hostname $RTKBASE_HOST
echo $RTKBASE_HOST >$HOSTNAME
sed -i s/127\.0\.1\.1.*/127\.0\.1\.1\ $RTKBASE_HOST/ "$HOSTS"
systemctl restart avahi-daemon
