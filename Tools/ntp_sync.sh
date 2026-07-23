#!/bin/bash

echo chronyc makestep
chronyc makestep
echo ntpdate pool.ntp.org
ntpdate pool.ntp.org

if [[ ${1} == "-s" ]]; then
   exit 254
fi
