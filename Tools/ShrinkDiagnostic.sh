#!/bin/bash

if [[ ${1} != "-s" ]]; then
   echo Started as: $0 $1 $2 $3
   echo Usage: $0 -s
   exit 1
fi

WHOAMI=`whoami`
if [[ ${WHOAMI} != "root" ]]; then
   echo You are ${WHOAMI}! Use only as root
   exit 1
fi

journalctl --disk-usage 1>&2
journalctl --vacuum-files=1 1>&2
journalctl --rotate 1>&2
journalctl --disk-usage 1>&2

exit 254