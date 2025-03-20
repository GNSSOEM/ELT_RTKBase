#!/bin/bash
#

#NEWCONF=system.txt
NEWCONF=/boot/firmware/system.txt
BASEDIR="$(dirname "$0")"
exitcode=0

ExitCodeCheck(){
  lastcode=$1
  if [[ $lastcode > $exitcode ]]
  then
     exitcode=${lastcode}
     #echo exitcode=${exitcode}
  fi
}

WPS_FLAG=/usr/local/rtkbase/WPS.flg

Ciao(){
  #echo Trap now
  rm -f ${WPS_FLAG}
}

WPS() {
  nm-online -s >/dev/null
  HAVE_INTERNET=`nmcli networking connectivity check`
  #echo HAVE_INTERNET=${HAVE_INTERNET}
  if [[ "${HAVE_INTERNET}" != "full" ]]; then
     echo Start WPS PBC
     trap Ciao EXIT HUP INT QUIT ABRT KILL TERM
     echo Start WPS PBC >${WPS_FLAG}
     ${BASEDIR}/PBC.sh 2>&1 1>/dev/null
     rm -f ${WPS_FLAG}
  fi
  ExitCodeCheck 0
}

WHOAMI=`whoami`
if [[ ${WHOAMI} != "root" ]]
then
   #echo use sudo
   sudo ${0} ${1}
   ExitCodeCheck $?
   if [[ "${exitcode}" != 0 ]]
   then
      echo exit with code ${exitcode}
   fi
   exit ${exitcode}
fi

if [[ -f ${NEWCONF} ]]
then
   DATE=`date`
   echo start at ${DATE}
   #echo sed -i s/"\r"// "${NEWCONF}"
   sed -i s/"\r"// "${NEWCONF}"
   ExitCodeCheck $?
   #echo "source <( grep '=' ${NEWCONF} )"
   source <( grep '=' ${NEWCONF} )
   ExitCodeCheck $?
else
   WPS
   exit 0
fi

if [[ -n "${COMMAND}" ]]
then
   echo Executing \""${COMMAND}"\"
   eval ${COMMAND}
   ExitCodeCheck $?
   WORK=Y
fi

if [[ -n "${COUNTRY}" ]]
then
   nm-online -s >/dev/null
   #echo raspi-config nonint do_wifi_country "${COUNTRY}"
   raspi-config nonint do_wifi_country "${COUNTRY}"
   ExitCodeCheck $?
   echo Wifi country set to ${COUNTRY} -- code ${exitcode}
   WORK=Y
fi

if [[ -n "${SSID}" ]]
then
   if [[ -z "${HIDDEN}" ]]
   then
      HIDnum=0
      HIDkey=
   else
      HIDnum=1
      HIDkey=-h
   fi
   #echo SSID=${SSID} KEY=${KEY} HIDDEN=${HIDDEN} HIDnum=${HIDnum} HIDkey=${HIDkey}
   nm-online -s >/dev/null

   if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
      if [ -f /etc/NetworkManager/system-connections/preconfigured.nmconnection ]; then
         UUID=`nmcli --fields UUID,DEVICE con show | grep wlan0 | awk -F ' ' '{print $1}'`
         if [[ "${UUID}" = "" ]]; then
            UUID=`nmcli --fields UUID,NAME con show | grep "preconfigured" | awk -F ' ' '{print $1}'`
            #UUID=${UUID}
         fi
         if [[ "${UUID}" != "" ]]; then
            #echo nmcli connection delete uuid "${UUID}"
            nmcli connection delete uuid "${UUID}"
            ExitCodeCheck $?
         fi
      fi
      #echo /usr/lib/raspberrypi-sys-mods/imager_custom set_wlan ${HIDkey} "${SSID}" "${KEY}"
      /usr/lib/raspberrypi-sys-mods/imager_custom set_wlan ${HIDkey} "${SSID}" "${KEY}"
      ExitCodeCheck $?
      #cat /etc/NetworkManager/system-connections/preconfigured.nmconnection | grep "ssid="
      #cat /etc/NetworkManager/system-connections/preconfigured.nmconnection | grep "psk="
      #echo nmcli connection reload
      nmcli connection reload
      ExitCodeCheck $?
   else
      #https://www.raspberrypi.com/documentation/computers/configuration.html
      #echo raspi-config nonint do_wifi_ssid_passphrase "${SSID}" "${KEY}" ${HIDnum}
      raspi-config nonint do_wifi_ssid_passphrase "${SSID}" "${KEY}" ${HIDnum}
      ExitCodeCheck $?
   fi
   echo Wifi SSID set to ${SSID} -- code ${exitcode}
   WORK=Y
fi

if [[ -n "${LOGIN}" ]]
then
   USER_HOME=/home/"${LOGIN}"
   #echo sed 's/:.*//' /etc/passwd \| grep ${LOGIN}
   FOUND=`sed 's/:.*//' /etc/passwd | grep "${LOGIN}"`
   #echo LOGIN=${LOGIN} PWD=${PWD} USER_HOME=${USER_HOME} FOUND=${FOUND}
   #echo SSH=${SSH}
   if [[ -z "${FOUND}" ]]
   then
      if [[ -n "${PWD}" ]]
      then
         # https://ru.stackoverflow.com/questions/1022068/ћожно-ли-создавать-пользовател€-одновременно-с-вводом-парол€-из-переменной
         #echo CRYPTO=\`openssl passwd -1 -salt xyz "${PWD}"\`
         CRYPTO=`openssl passwd -1 -salt xyz "${PWD}"`
         #echo CRYPTO=${CRYPTO}
         ExitCodeCheck $?
         #echo useradd --comment "Added by system" --create-home --password "${CRYPTO}" "${LOGIN}"
         useradd --comment "Added by RtkBaseSystemConfigure" --create-home --password "${CRYPTO}" "${LOGIN}"
         ExitCodeCheck $?
         usermod -a -G plugdev,dialout,gpio "${LOGIN}"
         ExitCodeCheck $?
         echo Added user ${LOGIN} with password -- code ${exitcode}
      else
         #echo useradd --comment "Added by system" --create-home --disabled-password "${LOGIN}"
         useradd --comment "Added by RtkBaseSystemConfigure" --create-home "${LOGIN}"
         ExitCodeCheck $?
         echo Added user ${LOGIN} without password -- code ${exitcode}
      fi
      #echo ""${LOGIN}" ALL=NOPASSWD: ALL" \> /etc/sudoers.d/"${LOGIN}"
      echo ""${LOGIN}" ALL=NOPASSWD: ALL" > /etc/sudoers.d/"${LOGIN}"
   else
      if [[ -n "${PWD}" ]]
      then
         echo User ${LOGIN} already present
      fi
   fi
   if [[ -n "${SSH}" ]]
   then
      SSH_HOME="${USER_HOME}"/.ssh
      if [[ ! -d "${SSH_HOME}" ]]
      then
          #echo install -o "${LOGIN}" -g "${LOGIN}" -m 700 -d "${SSH_HOME}"
          install -o "${LOGIN}" -g "${LOGIN}" -m 700 -d "${SSH_HOME}"
          ExitCodeCheck $?
      fi
      AUTHORISED_KEYS_FILE="${SSH_HOME}"/authorized_keys
      if [[ -f "${AUTHORISED_KEYS_FILE}" ]]
      then
         #echo grep "${SSH}" "${AUTHORISED_KEYS_FILE}"
         DOUBLE=`grep "${SSH}" "${AUTHORISED_KEYS_FILE}"`
         ExitCodeCheck $?
      fi
      if [[ -z "${DOUBLE}" ]]
      then
         #echo echo "${SSH}" '>>' "${AUTHORISED_KEYS_FILE}"
         echo "${SSH}" >> "${AUTHORISED_KEYS_FILE}"
         ExitCodeCheck $?
         if [[ -f "${AUTHORISED_KEYS_FILE}" ]]
         then
           #echo chmod 600 "${AUTHORISED_KEYS_FILE}"
           chmod 600 "${AUTHORISED_KEYS_FILE}"
           ExitCodeCheck $?
           #echo chown "${LOGIN}:${LOGIN}" "${AUTHORISED_KEYS_FILE}"
           chown "${LOGIN}:${LOGIN}" "${AUTHORISED_KEYS_FILE}"
           ExitCodeCheck $?
         fi
         echo Added ssh public key for ${LOGIN} -- code ${exitcode}
      else
         echo This ssh public key for ${LOGIN} already present
      fi
   fi
   #echo raspi-config nonint do_ssh 0
   raspi-config nonint do_ssh 0
   ExitCodeCheck $?
   WORK=Y
fi

ChangeConnection(){
   device=$1
   ip="$2"
   gate="$3"
   dns="$4"
   conname="$5"
   nm-online -s >/dev/null
   #echo device=${device} ip=${ip} gate=${gate} dns=${dns} conname=${conname}
   #https://askubuntu.com/questions/246077/how-to-setup-a-static-ip-for-network-manager-in-virtual-box-on-ubuntu-server
   UUID=`nmcli --fields UUID,DEVICE con show | grep ${device} | awk -F ' ' '{print $1}'`
   if [[ "${UUID}" = "" ]]; then
      UUID=`nmcli --fields UUID,NAME con show | grep "${conname}" | awk -F ' ' '{print $1}'`
      #UUID=${UUID}
   fi
   if [[ "${UUID}" != "" ]]; then
      CMD="nmcli connection modify uuid \"${UUID}\""
      if [[ "${ip}" =~ DHCP ]]; then
         method=auto
         ip=
         gate=
         dns=
         kind=DHCP
      else
         method=manual
         kind=Static
      fi

      old_method=`nmcli connection show uuid "${UUID}" | grep "ipv4.method:" | awk -F ' ' '{print $2}'`
      if [[ "${old_method}" != "${method}" ]]; then
         #echo old_method=${old_method} method=${method}
         CMD="${CMD} ipv4.method \"${method}\""
         change=Y
      fi

      old_ip=`nmcli connection show uuid "${UUID}" | grep "ipv4.addresses:" | awk -F ' ' '{print $2}'`
      if [[ "${old_ip}" == "--" ]]; then
         old_ip=
      fi
      if [[ "${old_ip}" != "${ip}" ]]; then
         #echo old_ip=${old_ip} ip=${ip}
         CMD="${CMD} ipv4.addresses \"${ip}\""
         change=Y
      fi

      old_gate=`nmcli connection show uuid "${UUID}" | grep "ipv4.gateway:" | awk -F ' ' '{print $2}'`
      if [[ "${old_gate}" == "--" ]]; then
         old_gate=
      fi
      if [[ "${old_gate}" != "${gate}" ]]; then
         #echo old_gate=${old_gate} gate=${gate}
         CMD="${CMD} ipv4.gateway \"${gate}\""
         change=Y
      fi

      old_dns=`nmcli connection show uuid "${UUID}" | grep "ipv4.dns:" | awk -F ' ' '{print $2}'`
      if [[ "${old_dns}" == "--" ]]; then
         old_dns=
      fi
      if [[ "${old_dns}" != "${dns}" ]]; then
         #echo old_dns=${old_dns} dns=${dns}
         CMD="${CMD} ipv4.dns \"${dns}\""
         change=Y
      fi

      if [[ "${change}" == "Y" ]]; then
         #echo ${CMD}
         eval ${CMD}
         ExitCodeCheck $?
         is_active=`nmcli connection show --active uuid "${UUID}" | grep "connection.id:"`
         #echo is_active=${is_active}
         if [[ -n "${is_active}" ]]; then
            #echo nmcli connection down uuid \"${UUID}\"
            nmcli connection down uuid "${UUID}"
            ExitCodeCheck $?
         fi
         #echo nmcli --wait 120 connection up uuid \"${UUID}\"
         nmcli --wait 120 connection up uuid "${UUID}"
         ExitCodeCheck $?

         #echo DEBUG=${DEBUG}
         if [[ -n "${DEBUG}" ]]; then
            if [[ -n "${dns}" ]]; then
               ping_target="google.com"
            elif [[ "${gate}" != "" ]]; then
               ping_target="${gate}"
            else
               ping_target=
            fi

            if [[ -n "${ping_target}" ]]; then
               #echo ping -4 -c 1 -W 1 -q -I ${device} ${ping_target} \>/dev/null
               ping -4 -c 1 -W 1 -q -I ${device} ${ping_target} >/dev/null
               if [[ $? == 0 ]]; then
                  echo Ping OK. ${kind} ${device} configured.
               else
                  echo Ping failed. Restore DHCP for ${device}
                  CMD="nmcli connection modify uuid \"${UUID}\" ipv4.method \"auto\" ipv4.addresses \"\" ipv4.gateway \"\" ipv4.dns \"\""
                  #echo ${CMD}
                  eval ${CMD}
                  ExitCodeCheck $?
                  is_active=`nmcli connection show --active uuid "${UUID}" | grep "connection.id:"`
                  #echo is_active=${is_active}
                  if [[ -n "${is_active}" ]]; then
                     #echo nmcli connection down uuid \"${UUID}\"
                     nmcli connection down uuid "${UUID}"
                     ExitCodeCheck $?
                  fi
                  #echo nmcli connection up uuid \"${UUID}\"
                  nmcli connection up uuid "${UUID}"
                  ExitCodeCheck $?
               fi
            fi
         fi
      else
         echo ${kind} ${device} already configured as the same
      fi
   else
      echo conection for ${device} not found
   fi
   WORK=Y
}

if [[ -n "${ETH_IP}" ]] || [[ -n "${ETH_GATE}" ]] || [[ -n "${ETH_DNS}" ]]; then
   ChangeConnection eth0 "${ETH_IP}" "${ETH_GATE}" "${ETH_DNS}" "Wired connection 1"
fi
if [[ -n "${WIFI_IP}" ]] || [[ -n "${WIFI_GATE}" ]] || [[ -n "${WIFI_DNS}" ]]; then
   ChangeConnection wlan0 "${WIFI_IP}" "${WIFI_GATE}" "${WIFI_DNS}" "preconfigured"
fi

WPS

if [[ -z "${WORK}" ]]
then
  echo No any work
  ExitCodeCheck 1
fi

rm -f ${NEWCONF}
ExitCodeCheck $?

#echo exit ${exitcode}
exit ${exitcode}

