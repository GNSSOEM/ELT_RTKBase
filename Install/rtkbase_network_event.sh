#!/bin/sh -e
# Script to dispatch NetworkManager events
#
FLAG=/usr/local/rtkbase/NetworkChange.flg

case "$2" in
    up|down)
        echo $1 $2 >${FLAG}
        ;;
    *)
        ;;
esac
