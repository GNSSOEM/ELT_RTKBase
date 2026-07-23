#!/bin/bash

#echo timedatectl status
timedatectl status
#echo chronyc sources
chronyc sources

if [[ ${1} == "-s" ]]; then
   exit 254
fi
