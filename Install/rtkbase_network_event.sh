#!/bin/sh -e
# Script to dispatch NetworkManager events
#
FLAG=/usr/local/rtkbase/NetworkChange.flg

case "$2" in
    up|down)
        echo $1 $2 >${FLAG}
        if test \( "${1}" = "septentrio" \) -a \( "${2}" = "up" \); then
           #echo systemctl start rtkbase_DHCP.service
           systemctl start rtkbase_DHCP.service
        fi
        ;;
    *)
        ;;
esac
