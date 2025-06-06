#!/bin/bash

nmcli device wifi rescan
nmcli device wifi list

if [[ ${1} == "-s" ]]; then
   exit 254
fi
