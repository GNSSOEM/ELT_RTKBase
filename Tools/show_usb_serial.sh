#!/bin/bash

for path in /dev/serial/by-id/*; do
    real=$(basename $(readlink -f ${path}))
    base=$(basename ${path})
    base=`echo ${base} | sed s/^usb-//`
    base=`echo ${base} | sed s/^Septentrio_Septentrio_/Septentrio_/`
    base=`echo ${base} | sed s/^1a86_/CH340_/`
    echo ${real} - ${base}
done

if [[ ${1} == "-s" ]]; then
   exit 1
fi
