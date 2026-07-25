#!/bin/bash
#

#NEWCONF=system.txt
NEWCONF=/boot/firmware/system.txt
BASEDIR="$(dirname "$0")"
HOTSPOT=Hotspot
exitcode=0

ExitCodeCheck(){
  lastcode=$1
  if [[ $lastcode -gt $exitcode ]]; then
     exitcode=${lastcode}
     #echo exitcode=${exitcode}
  fi
}

WPS_FLAG=/usr/local/rtkbase/WPS.flg
HOTSPOT_FLAG=/usr/local/rtkbase/HOTSPOT.flg

Ciao(){
  #echo Trap now
  rm -f ${WPS_FLAG}
}

DeleteHotSpots(){
   HOTSPOT_LIST=$(nmcli --get-values NAME connection show | grep ${HOTSPOT})
   #echo HOTSPOT_LIST=${HOTSPOT_LIST}
   for hotspot_name in ${HOTSPOT_LIST}; do
       nmcli connection delete id ${hotspot_name}
   done
}

WPS() {
  nm-online -s >/dev/null
  HAVE_INTERNET=`nmcli networking connectivity check`
  HAVE_HOTSPOT=`nmcli  --fields NAME connection show --active | grep ${HOTSPOT}`
  #echo before WPS  HAVE_INTERNET=${HAVE_INTERNET} HAVE_HOTSPOT=${HAVE_HOTSPOT}
  if [[ "${HAVE_INTERNET}" != "full" ]] && [[ "${HAVE_HOTSPOT}" == "" ]]; then
     DeleteHotSpots
     echo Start WPS PBC
     trap Ciao EXIT HUP INT QUIT ABRT KILL TERM
     echo Start WPS PBC >${WPS_FLAG}
     nmcli radio wifi on
     ExitCodeCheck $?
     ${BASEDIR}/PBC.sh 2>&1 1>/dev/null
     nmcli radio wifi on
     ExitCodeCheck $?
     rm -f ${WPS_FLAG}
     HAVE_INTERNET=`nmcli networking connectivity check`
     #echo after WPS HAVE_INTERNET=${HAVE_INTERNET}
     if [[ "${HAVE_INTERNET}" != "full" ]]; then
        HAVE_WIFI=`nmcli --get-values TYPE,AUTOCONNECT connection show  | grep -w "802-11-wireless:yes"`
        #echo HAVE_WIFI=${HAVE_WIFI}
        if [[ -z "${HAVE_WIFI}" ]]; then
           HOSTNAME=$(hostame)
           #echo HOSTNAME=${HOSTNAME}
           nmcli device wifi hotspot con-name ${HOTSPOT} ssid "${HOSTNAME}" password "12345678" ifname wlan0 | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g'
           ExitCodeCheck $?
           nmcli connection modify id ${HOTSPOT} ipv4.addresses "192.168.1.1/24" connection.autoconnect no
           ExitCodeCheck $?
           nmcli connection down id ${HOTSPOT}
           ExitCodeCheck $?
           nmcli connection up id ${HOTSPOT}
           ExitCodeCheck $?
        fi
     fi
  fi
  if [[ "${HAVE_INTERNET}" == "full" ]]; then
     REGDOMAIN="$(iw reg get | sed -n "0,/country/s/^country \(.\+\):.*$/\1/p")"
     #echo REGDOMAIN=${REGDOMAIN}
     if [[ "${REGDOMAIN}" == "00" ]]; then
        code2=$(curl -s "http://ip-api.com/json/?fields=countryCode"  | jq -r '.countryCode')
        #echo code2=${code2}
        if [[ "${#code2}" == "2" ]]; then
           #echo iw reg set "${code2}"
           iw reg set "${code2}"
           ExitCodeCheck $?
           echo Wifi country temporaly set to ${code2} -- code ${exitcode}
        fi
     fi
  fi
  HAVE_HOTSPOT=`nmcli --get-values NAME connection show --activ | grep ${HOTSPOT}`
  if [[ -n "${HAVE_HOTSPOT}" ]]; then
     echo Hotspot Started >${HOTSPOT_FLAG}
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

PRECONFIGURED=preconfigured
HAVE_PRECONFIGURED=`nmcli --fields NAME connection show | grep -w "${PRECONFIGURED}"`
if [[ -n "${HAVE_PRECONFIGURED}" ]]; then
   PRECONFIGURED_SSID=`nmcli --fields 802-11-wireless.ssid connection show id "${PRECONFIGURED}" | awk -F ' ' '{print $2}'`
   PRECONFIGURED_SSIDprinted=WiFi_$(printf '%s' "${PRECONFIGURED_SSID}" | tr '/' '_' | sed 's/[[:cntrl:]]//g')
   PRECONFIGURED_FILE=`nmcli --fields NAME,FILENAME connection show| grep "${PRECONFIGURED}" | awk -F ' ' '{print $2}'`
   PRECONFIGURED_NEW_FILE=`dirname "${PRECONFIGURED_FILE}"`/${PRECONFIGURED_SSIDprinted}.nmconnection
   #echo PRECONFIGURED_SSID=${PRECONFIGURED_SSID} PRECONFIGURED_SSIDprinted=${PRECONFIGURED_SSIDprinted} PRECONFIGURED_FILE=${PRECONFIGURED_FILE} PRECONFIGURED_NEW_FILE=${PRECONFIGURED_NEW_FILE}
   if [[ "${PRECONFIGURED}" != "${PRECONFIGURED_SSIDprinted}" ]]; then
      #echo nmcli connection modify id "${PRECONFIGURED}" connection.id "${PRECONFIGURED_SSIDprinted}"
      nmcli connection modify id "${PRECONFIGURED}" connection.id "${PRECONFIGURED_SSIDprinted}"
      ExitCodeCheck $?
   fi
   if [[ "${PRECONFIGURED_FILE}" != "${PRECONFIGURED_NEW_FILE}" ]]; then
      #echo mv "${PRECONFIGURED_FILE}" "${PRECONFIGURED_NEW_FILE}"
      mv "${PRECONFIGURED_FILE}" "${PRECONFIGURED_NEW_FILE}"
      ExitCodeCheck $?
      #echo nmcli connection reload
      nmcli connection reload
      ExitCodeCheck $?
   fi
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
   if [[ -z "${HIDDEN}" ]]; then
      HIDbool=no
   else
      HIDbool=yes
   fi
   SSIDprinted=Wifi_$(printf '%s' "${SSID}" | tr '/' '_' | sed 's/[[:cntrl:]]//g')
   #echo SSID=${SSID} SSIDprinted=${SSIDprinted} KEY=${KEY} HIDDEN=${HIDDEN} AP=${AP} HIDnum=${HIDnum} HIDkey=${HIDkey} HIDbool=${HIDbool}
   nm-online -s >/dev/null
   nmcli radio wifi on
   if [[ -z "${AP}" ]]; then
      DeleteHotSpots
      HAVE_OLD_SSID=`nmcli --fields NAME connection show | grep -w "${SSIDprinted}"`
      if [ -n "${HAVE_OLD_SSID}" ]; then
         #echo nmcli connection delete id "${SSIDprinted}"
         nmcli connection delete id "${SSIDprinted}"
         ExitCodeCheck $?
      fi
      #echo nmcli device wifi connect "${SSID}" password "${KEY}" name ${SSIDprinted} ifname wlan0 hidden ${HIDbool}
      nmcli device wifi connect "${SSID}" password "${KEY}" name ${SSIDprinted} ifname wlan0 hidden ${HIDbool} | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g'
      ExitCodeCheck $?
      HAVE_WIFI=`nmcli --get-values NAME connection show | grep -w "${SSID}"`
      if [[ -n "${HAVE_WIFI}" ]]; then
         echo Wifi SSID set to ${SSID} -- code ${exitcode}
      else
         echo Wifi ${SSID} not created
         WIFI_IP=""
         WIFI_GATE=""
         WIFI_DNS=""
         ERROR=Y
      fi
   else
      DeleteHotSpots
      nmcli device wifi hotspot con-name ${HOTSPOT} ssid "${SSID}" password "${KEY}" ifname wlan0 | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g'
      ExitCodeCheck $?
      nmcli connection modify id ${HOTSPOT} connection.autoconnect yes connection.autoconnect-priority 100 802-11-wireless.hidden ${HIDbool}
      ExitCodeCheck $?
      if [[ -n "${WIFI_IP}" ]]; then
         nmcli connection modify id ${HOTSPOT} ipv4.addresses "${WIFI_IP}"
         ExitCodeCheck $?
         WIFI_IP_SHOW="${WIFI_IP}"
         WIFI_IP=""
      else 
         WIFI_IP_SHOW=$(nmcli connection show id ${HOTSPOT} | grep "IP4.ADDRESS[1]" | awk -F ' ' '{print $2}')
      fi
      nmcli connection down id ${HOTSPOT}
      ExitCodeCheck $?
      nmcli connection up id ${HOTSPOT}
      ExitCodeCheck $?
      echo Wifi ${HOTSPOT} set to ${SSID} \(${WIFI_IP_SHOW}\)-- code ${exitcode}
   fi
   WORK=Y
fi

if [[ -n "${LOGIN}" ]]; then
   USER_HOME=/home/"${LOGIN}"
   #echo sed 's/:.*//' /etc/passwd \| grep ${LOGIN}
   FOUND=`sed 's/:.*//' /etc/passwd | grep "${LOGIN}"`
   #echo LOGIN=${LOGIN} PWD=${PWD} USER_HOME=${USER_HOME} FOUND=${FOUND} DATAUSER=${DATAUSER}
   #echo SSH=${SSH}
   if [[ -n "${DATAUSER}" ]]; then
      SFTP=/srv/sftp
      DATA=/data
      SFTP_DATA="${SFTP}${DATA}"
      if [[ ! -d "${SFTP_DATA}" ]]; then
         #echo mkdir -p "${SFTP_DATA}"
         mkdir -p "${SFTP_DATA}"
         ExitCodeCheck $?
         #echo chown root:root "${SFTP}"
         chown root:root "${SFTP}"
         ExitCodeCheck $?
         #echo chmod 755 "${SFTP}"
         chmod 755 "${SFTP}"
         ExitCodeCheck $?
      fi
      if [[ ! -d "${DATA}" ]]; then
         #echo mkdir -p "${DATA}"
         mkdir -p "${DATA}"
         ExitCodeCheck $?
      fi
      if ! getent group sftpusers >/dev/null; then
         #echo groupadd sftpusers
         groupadd sftpusers
         ExitCodeCheck $?
      fi
      SETTINGS_NOW=${BASEDIR}/rtkbase/settings.conf
      source <( grep '^datadir=' "${SETTINGS_NOW}" ) #import settings
      FSTAB_LINE="${datadir} ${SFTP_DATA}  none  bind  0 0"
      FSTAB=/etc/fstab
      if ! grep -q "^${FSTAB_LINE}" "${FSTAB}"; then
         #echo echo "${FSTAB_LINE}" \>\>"${FSTAB}"
         echo "${FSTAB_LINE}" >>"${FSTAB}"
         ExitCodeCheck $?
         #echo systemctl daemon-reload
         systemctl daemon-reload
         ExitCodeCheck $?
         #echo mount ${SFTP_DATA}
         mount ${SFTP_DATA}
         ExitCodeCheck $?
      fi
      AUTHORISED_KEYS_DIR=/etc/ssh/authorized_keys
      if [[ ! -d "${AUTHORISED_KEYS_DIR}" ]]; then
         #echo mkdir -p "${AUTHORISED_KEYS_DIR}"
         mkdir -p "${AUTHORISED_KEYS_DIR}"
         ExitCodeCheck $?
         #echo chmod 755  "${AUTHORISED_KEYS_DIR}"
         chmod 755  "${AUTHORISED_KEYS_DIR}"
         ExitCodeCheck $?
      fi
      AUTHORISED_KEYS_FILE="${AUTHORISED_KEYS_DIR}/${LOGIN}"
      AUTHORISED_KEYS_USER="root:root"
      AUTHORISED_KEYS_MODE=644
      SSHD_CONFIG=/etc/ssh/sshd_config
      if ! grep -q "^Match Group sftpusers" "${SSHD_CONFIG}"; then
         cat <<"EOF" >>"${SSHD_CONFIG}"
Match Group sftpusers
    ChrootDirectory /srv/sftp
    ForceCommand internal-sftp
    AuthorizedKeysFile /etc/ssh/authorized_keys/%u
    AllowTcpForwarding no
    AllowAgentForwarding no
    DisableForwarding yes
    X11Forwarding no
    PermitTunnel no
    PasswordAuthentication yes
EOF
         #echo sshd -t
         sshd -t
         ExitCodeCheck $?
         #echo systemctl reload ssh
         systemctl reload ssh
         ExitCodeCheck $?
      fi
      USER_KEY="--home-dir ${DATA} --no-create-home --shell /usr/sbin/nologin --groups rtkbase,sftpusers"
   else
      AUTHORISED_KEYS_DIR="${USER_HOME}"/.ssh
      AUTHORISED_KEYS_FILE="${AUTHORISED_KEYS_DIR}"/authorized_keys
      AUTHORISED_KEYS_USER="${LOGIN}:${LOGIN}"
      AUTHORISED_KEYS_MODE=600
      USER_KEY="--create-home --groups plugdev,dialout,gpio"
   fi
   if [[ -z "${FOUND}" ]]; then
      if [[ -n "${PWD}" ]]; then
         # https://ru.stackoverflow.com/questions/1022068/ћожно-ли-создавать-пользовател€-одновременно-с-вводом-парол€-из-переменной
         #echo CRYPTO=\`openssl passwd -1 -salt xyz "${PWD}"\`
         CRYPTO=`openssl passwd -1 -salt xyz "${PWD}"`
         #echo CRYPTO=${CRYPTO}
         ExitCodeCheck $?
         #echo useradd --comment "Added by rtkbase_system_configure" ${USER_KEY} --user-group --password "${CRYPTO}" "${LOGIN}"
         useradd --comment "Added by rtkbase_system_configure" ${USER_KEY} --user-group --password "${CRYPTO}" "${LOGIN}"
         ExitCodeCheck $?
         echo Added user ${LOGIN} with password -- code ${exitcode}
      else
         #echo useradd --comment "Added by rtkbase_system_configure" ${USER_KEY} --user-group "${LOGIN}"
         useradd --comment "Added by rtkbase_system_configure" ${USER_KEY} --user-group "${LOGIN}"
         ExitCodeCheck $?
         echo Added user ${LOGIN} without password -- code ${exitcode}
      fi
      if [[ -z "${DATAUSER}" ]]; then
         #echo ""${LOGIN}" ALL=NOPASSWD: ALL" \> /etc/sudoers.d/"${LOGIN}"
         echo ""${LOGIN}" ALL=NOPASSWD: ALL" > /etc/sudoers.d/"${LOGIN}"
         ExitCodeCheck $?
      fi
   else
      if [[ -n "${PWD}" ]]; then
         echo User ${LOGIN} already present
      fi
   fi
   if [[ -n "${SSH}" ]]; then
      if [[ ! -d "${AUTHORISED_KEYS_DIR}" ]]; then
          #echo install -o "${LOGIN}" -g "${LOGIN}" -m 700 -d "${AUTHORISED_KEYS_DIR}"
          install -o "${LOGIN}" -g "${LOGIN}" -m 700 -d "${AUTHORISED_KEYS_DIR}"
          ExitCodeCheck $?
      fi
      if [[ -f "${AUTHORISED_KEYS_FILE}" ]]; then
         #echo grep "${SSH}" "${AUTHORISED_KEYS_FILE}"
         DOUBLE=`grep "${SSH}" "${AUTHORISED_KEYS_FILE}"`
         ExitCodeCheck $?
      fi
      if [[ -z "${DOUBLE}" ]]; then
         #echo echo "${SSH}" '>>' "${AUTHORISED_KEYS_FILE}"
         echo "${SSH}" >> "${AUTHORISED_KEYS_FILE}"
         ExitCodeCheck $?
         if [[ -f "${AUTHORISED_KEYS_FILE}" ]]; then
           #echo chmod ${AUTHORISED_KEYS_MODE} "${AUTHORISED_KEYS_FILE}"
           chmod ${AUTHORISED_KEYS_MODE} "${AUTHORISED_KEYS_FILE}"
           ExitCodeCheck $?
           #echo chown "${LOGIN}:${LOGIN}" "${AUTHORISED_KEYS_FILE}"
           chown "${AUTHORISED_KEYS_USER}" "${AUTHORISED_KEYS_FILE}"
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
   device="$1"
   type="$2"
   ip="$3"
   gate="$4"
   dns="$5"
   conname="$6"
   nm-online -s >/dev/null
   #https://askubuntu.com/questions/246077/how-to-setup-a-static-ip-for-network-manager-in-virtual-box-on-ubuntu-server
   if [[ -n "${conname}"  ]]; then
      echo UUID=\`nmcli --get-values UUID,NAME con show \| grep -w \"${conname}\" \| head -n 1 \| awk -F \':\' \'\{print $1\}\'\`
      UUID=`nmcli --get-values UUID,NAME con show | grep -w "${conname}" | head -n 1 | awk -F ':' '{print $1}'`
   else
      echo UUID=\`nmcli --get-values UUID,DEVICE con show --active \| grep -w ${device} \| head -n 1 \| awk -F \':\' \'\{print $1\}\'\`
      UUID=`nmcli --get-values UUID,DEVICE con show --active | grep -w ${device} | head -n 1 | awk -F ':' '{print $1}'`
   fi
   if [[ -z "${UUID}"  ]]; then
      echo UUID=\`nmcli --get-values UUID,TYPE con show --active \| grep -w ${type} \| head -n 1 \| awk -F \':\' \'\{print $1\}\'\`
      UUID=`nmcli --get-values UUID,TYPE con show | grep -w ${type} | head -n 1 | awk -F ':' '{print $1}'`
   fi
   echo device=${device} type=${type} ip=${ip} gate=${gate} dns=${dns} conname=${conname} UUID=${UUID}
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
      echo conection for ${device} \(${type}\) not found
   fi
   WORK=Y
}

if [[ -n "${ETH_IP}" ]] || [[ -n "${ETH_GATE}" ]] || [[ -n "${ETH_DNS}" ]]; then
   ChangeConnection eth0 "" "${ETH_IP}" "${ETH_GATE}" "${ETH_DNS}"
fi
if [[ -n "${WIFI_IP}" ]] || [[ -n "${WIFI_GATE}" ]] || [[ -n "${WIFI_DNS}" ]]; then
   nmcli radio wifi on
   ChangeConnection wlan0 802-11-wireless "${WIFI_IP}" "${WIFI_GATE}" "${WIFI_DNS}" "${SSID}"
fi

WPS

if [[ -z "${WORK}" ]]
then
  echo No any work
  ExitCodeCheck 1
fi

if [[ -z ${ERROR} ]]; then
   rm -f ${NEWCONF}
   ExitCodeCheck $?
else
   echo ${NEWCONF} is not deleted via error. Operation will repeated at next reboot.
fi

#echo exit ${exitcode}
exit ${exitcode}

