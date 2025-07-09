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

SERVICE=RtkbaseSystemConfigure.service
service_active=$(systemctl is-active ${SERVICE})
if [[ "${service_active}" == "active" ]]; then
   IS_EXITED=$(systemctl status ${SERVICE} | grep "active (exited)")
   if [[ "${IS_EXITED}" == "" ]]; then
      echo Service is ${service_active}. Please wait 30 seconds and reapeat.
      exit 1
   fi
fi

cat <<"EOF" >/boot/firmware/system.txt
# WiFi
#COUNTRY=LV
#SSID=$'ABC'
#KEY=$'1234567890'
#HIDDEN=Y
# SSH Login
#LOGIN=jef
#PWD=$'1234567890'
#SSH="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCueeOu8+EQX1aou9c/yq9wVp5e1aKH/i5T5tHQ3sk5tmk3FaAxAd/QBRIY4weTV5YpV3ebGGE8RLB9xUlNmZa9oc+f8uUOpYF/lKfwL1gVugTMd1gBomZe7+GouhMK49M4UaVvtoMe5nm6m8kKL6x6DkmlXu3fdXPZPh9Q/MR83+OzAIMZBdq7aI7PILPTmg7adl8ER7KXjpLV25Wf3LdjXK++V10kh9f2G7jq9gRqlxIn4Noi3pNHqMRkaYoJPR1KEiy0JyRiKjEZy/AfZLwHDnOO4pumDKU9jFfkRYTEwkTe2q7PYoedgYPGlfbEEyQplEmfqEfSY/Su/cybRfREDlhw2nR11q6cFNi1ZTNfNvCf11wTy2j476dfFv1jAibbPN9X3zFiC0M9yA3RByJbWMAW6FxENdw7FXo2psJB+QHonbWtST3hYhx96+RRyqmRscIF1gtZasvSEn0bsEGC7gny7L+Y64TO6JmYJkuAK0pmPXnItFTKvsi6Llt6c0k= user@DESKTOP-I3IN1G1"#ETH_IP="192.168.1.2/24"
# Static
#ETH_GATE="192.168.1.1"
#ETH_DNS="8.8.8.8"
#WIFI_IP="192.168.1.3/24"
#WIFI_GATE="192.168.1.1"
#WIFI_DNS="8.8.8.8"
EOF

/usr/local/rtkbase/RtkbaseSystemConfigure.sh
exit 254