#!/bin/bash

### RTKBASE INSTALLATION SCRIPT ###
declare -a detected_gnss
declare RTKBASE_USER
BASEDIR=`realpath $(dirname $(readlink -f "$0"))`
NMEACONF=NmeaConf


_check_user() {
  # RTKBASE_USER is a global variable
  if [ "${1}" != 0 ] ; then
    RTKBASE_USER="${1}"
      #TODO check if user exists and/or path exists ?
      # warning for image creation, do the path exist ?
  elif [[ -z $(logname) ]] ; then
    echo 'The logname command return an empty value. Please reboot and retry.'
    exit 1
  elif [[ $(logname) == 'root' ]]; then
    echo 'The logname command return "root". Please reboot or use --user argument to choose the correct user which should run rtkbase services'
    exit 1
  else
    RTKBASE_USER=$(logname)
  fi
}

detect_speed_Unicore() {
    for port_speed in 115200 921600 230400 460800; do
        echo 'DETECTION Unicore ON ' ${1} ' at ' ${port_speed}
        RECVPORT=/dev/${1}:${port_speed}
        RECVVER=`${rtkbase_path}/${NMEACONF} ${RECVPORT} VERSION SILENT`
        if [[ "${RECVVER}" != "" ]]
        then
           #echo RECVVER=${RECVVER}
           RECVNAME=`echo ${RECVVER}  | awk -F ';' '{print $2}'| awk -F ',' '{print $1}'`
           #echo RECVNAME=${RECVNAME}
           if [[ ${RECVNAME} != "" ]]
           then
              #FIRMWARE=`echo ${RECVVER}  | awk -F ';' '{print $2}'| awk -F ',' '{print $2}'`
              #echo FIRMWARE=${FIRMWARE}
              #echo Receiver ${RECVNAME}\(${FIRMWARE}\) found on ${1} ${port_speed}
              detected_gnss[0]=${1}
              detected_gnss[1]=Unicore_${RECVNAME}
              detected_gnss[2]=${port_speed}
              break
           fi
        fi
    done
}

detect_Bynav() {
    echo 'DETECTION Bynav ON ' ${1} ' at ' ${2}
    RECVPORT=/dev/${1}:${2}
    RECVINFO=`${rtkbase_path}/${NMEACONF} ${RECVPORT} "LOG AUTHORIZATION" QUIET`
    if [[ "${RECVINFO}" != "" ]]
    then
       #echo RECVINFO=${RECVINFO}
       RECVNAME=`echo ${RECVINFO} | awk -F ';' '{print $2}'| awk -F ' ' '{print $2}'`
       if [[ ${RECVNAME} != "" ]]
       then
          #echo Receiver ${RECVNAME} found on ${1} ${port_speed}
          detected_gnss[0]=${1}
          detected_gnss[1]=Bynav_${RECVNAME}
          detected_gnss[2]=${2}
       fi
    fi
}

detect_speed_Bynav() {
    for port_speed in 115200 921600 230400 460800; do
        detect_Bynav ${1} ${port_speed}
        [[ ${#detected_gnss[*]} -eq 3 ]] && break
    done
}

detect_Ublox() {
    echo 'DETECTION Ublox ON ' ${1} ' at ' ${2}
    ubxVer=$(python3 "${rtkbase_path}"/tools/ubxtool -f /dev/$1 -s $2 -p MON-VER -w 5 2>/dev/null)
    if [[ "${ubxVer}" =~ 'ZED-F9P' ]]; then
       #echo Receiver ${ubxVer} found on ${1} ${port_speed}
       detected_gnss[0]=${1}
       detected_gnss[1]=u-blox_ZED-F9P
       detected_gnss[2]=${2}
    fi
}

detect_speed_Ublox() {
    for port_speed in 38400 115200 921600 230400 460800; do
        detect_Ublox ${1} ${port_speed}
        [[ ${#detected_gnss[*]} -eq 3 ]] && break
    done
}

detect_usb() {
    echo '################################'
    echo 'USB GNSS RECEIVER DETECTION'
    echo '################################'
      if [[ ${#detected_gnss[*]} < 2 ]]; then
         #This function try to detect a gnss receiver and write the port/format inside settings.conf
         #If the receiver is a U-Blox, it will add the TADJ=1 option on all ntrip/rtcm outputs.
         #If there are several receiver, the last one detected will be add to settings.conf.
         BynavDevices="${rtkbase_path}"/BynavDevlist.txt
         rm -rf "${BynavDevices}"
         for sysdevpath in $(find /sys/bus/usb/devices/usb*/ -name dev); do
             ID_SERIAL=''
             syspath="${sysdevpath%/dev}"
             devname="$(udevadm info -q name -p "${syspath}")"
             if [[ "$devname" == "bus/"* ]]; then continue; fi
             #echo sysdevpath=${sysdevpath} syspath=${syspath} devname=${devname}
             eval "$(udevadm info -q property --export -p "${syspath}")"
             #echo devname=${devname} ID_SERIAL=${ID_SERIAL}
             if [[ -z "$ID_SERIAL" ]]; then continue; fi
             if [[ "$ID_SERIAL" =~ (u-blox|skytraq) ]]; then
                detected_gnss[0]=$devname
                detected_gnss[1]=$ID_SERIAL
                #echo '/dev/'"${detected_gnss[0]}" ' - ' "${detected_gnss[1]}"
                # If /dev/ttyGNSS is a symlink of the detected serial port, we've found the gnss receiver, break the loop.
                # This test is useful with gnss receiver offering several serial ports (like mosaic X5). The Udev rule should symlink the right one with ttyGNSS
                [[ '/dev/ttyGNSS' -ef '/dev/'"${detected_gnss[0]}" ]] && break
             elif [[ "$ID_SERIAL" =~ Septentrio ]]; then
                detected_gnss[0]=$devname
                detected_gnss[1]=`echo  $ID_SERIAL | sed s/^Septentrio_Septentrio_/Septentrio_/`
                [[ '/dev/ttyGNSS' -ef '/dev/'"${detected_gnss[0]}" ]] && break
             elif [[ "$ID_SERIAL" =~ FTDI_FT230X_Basic_UART ]]; then
                #echo detect_speed_Unicore ${devname}
                detect_speed_Unicore ${devname}
                #echo detect_speed_Bynav ${devname}
                detect_speed_Bynav ${devname}
                #echo '/dev/'"${detected_gnss[0]}" ' - ' "${detected_gnss[1]}"' - ' "${detected_gnss[2]}"
             elif [[ "$ID_SERIAL" =~ 1a86_USB_Dual_Serial ]]; then
                echo ${devname} >> "${BynavDevices}"
             fi
             [[ ${#detected_gnss[*]} -eq 3 ]] && break
         done
         if [[ -f  "${BynavDevices}" ]]
         then
            #cat ${BynavDevices}
            for devname in `cat "${BynavDevices}" | sort`; do
               #echo detect_speed_Bynav ${devname}
               detect_speed_Bynav ${devname}
               #echo '/dev/'"${detected_gnss[0]}" ' - ' "${detected_gnss[1]}"' - ' "${detected_gnss[2]}"
               [[ ${#detected_gnss[*]} -eq 3 ]] && break
            done
            rm -rf "${BynavDevices}"
         fi
      fi
}

detect_uart() {
    # detection on uart port
    echo '################################'
    echo 'UART GNSS RECEIVER DETECTION'
    echo '################################'
      if [[ ${#detected_gnss[*]} < 2 ]]; then
        for port in ttyAMA5 ttyAMA4 ttyAMA3 ttyAMA2 ttyAMA1 ttyAMA0 ttyS0 ttyS5 serial0; do
            if [[ -c /dev/${port} ]]
            then
               detect_speed_Unicore ${port}
               #exit loop if a receiver is detected
               [[ ${#detected_gnss[*]} -eq 3 ]] && break

               detect_speed_Bynav ${port}
               [[ ${#detected_gnss[*]} -eq 3 ]] && break

               detect_speed_Ublox ${port}
               [[ ${#detected_gnss[*]} -eq 3 ]] && break
            fi
        done
      fi
}

detect_configure() {
      # Test if speed is in detected_gnss array. If not, add the default value.
      [[ ${#detected_gnss[*]} -eq 2 ]] && detected_gnss[2]='115200'
      # If /dev/ttyGNSS is a symlink of the detected serial port, switch to ttyGNSS
      [[ '/dev/ttyGNSS' -ef '/dev/'"${detected_gnss[0]}" ]] && detected_gnss[0]='ttyGNSS'
      # "send" result
      echo '/dev/'"${detected_gnss[0]}" ' - ' "${detected_gnss[1]}"' - ' "${detected_gnss[2]}"

      #Write Gnss receiver settings inside settings.conf
      #Optional argument --no-write-port (here as variable $1) will prevent settings.conf modifications. It will be just a detection without any modification. 
      if [[ ${#detected_gnss[*]} -eq 3 ]] && [[ "${1}" -eq 0 ]]
        then
          echo 'GNSS RECEIVER DETECTED: /dev/'"${detected_gnss[0]}" ' - ' "${detected_gnss[1]}" ' - ' "${detected_gnss[2]}"

          if [[ -f "${rtkbase_path}/settings.conf" ]]  && grep -qE "^com_port=.*" "${rtkbase_path}"/settings.conf #check if settings.conf exists
          then
            if [[ "${detected_gnss[1]}" =~ u-blox ]]; then
               recvformat=ubx
            elif [[ "${detected_gnss[1]}" =~ Septentrio ]]; then
               recvformat=sbf
            else
               recvformat=rtcm3
            fi
            #echo detected_gnss[1]=${detected_gnss[1]} recvformat=${recvformat}

            #change the com port value/settings inside settings.conf
            sudo -u "${RTKBASE_USER}" sed -i s/^com_port=.*/com_port=\'${detected_gnss[0]}\'/ "${rtkbase_path}"/settings.conf
            sudo -u "${RTKBASE_USER}" sed -i s/^receiver=.*/receiver=\'${detected_gnss[1]}\'/ "${rtkbase_path}"/settings.conf
            sudo -u "${RTKBASE_USER}" sed -i s/^com_port_settings=.*/com_port_settings=\'${detected_gnss[2]}:8:n:1\'/ "${rtkbase_path}"/settings.conf
            sudo -u "${RTKBASE_USER}" sed -i s/^receiver_format=.*/receiver_format=\'${recvformat}\'/ "${rtkbase_path}"/settings.conf

            RECEIVER_CONF=${rtkbase_path}/receiver.conf
            echo recv_port=${detected_gnss[0]}>${RECEIVER_CONF}
            echo recv_speed=${detected_gnss[2]}>>${RECEIVER_CONF}
            echo recv_position=>>${RECEIVER_CONF}
            chown ${RTKBASE_USER}:${RTKBASE_USER} ${RECEIVER_CONF}
          else
            echo 'settings.conf is missing'
            return 1
          fi
      elif [[ ${#detected_gnss[*]} -ne 3 ]]
        then
          return 1
      fi
      return 0
}

stoping_main() {
   str2str_active=$(systemctl is-active str2str_tcp)
   #echo str2str_active=${str2str_active}

   if [ "${str2str_active}" = "active" ] || [ "${str2str_active}" = "activating" ]
   then
      #echo systemctl stop str2str_tcp \&\& sleep 2
      systemctl stop str2str_tcp && sleep 2
   fi
   #systemctl status str2str_tcp.service
   #ps -Af | grep rtkrcv
}

detect_gnss() {
    stoping_main
    detect_usb
    if [[ ${#detected_gnss[*]} < 2 ]]; then
       detect_uart
    fi
    detect_configure ${1}
}

add_TADJ() {
    #add option -TADJ=1 on rtcm/ntrip_a/ntrip_b/serial outputs
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_a_receiver_options=.*/ntrip_a_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_b_receiver_options=.*/ntrip_b_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^local_ntripc_receiver_options=.*/local_ntripc_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_receiver_options=.*/rtcm_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_client_receiver_options=.*/rtcm_client_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_udp_svr_receiver_options=.*/rtcm_udp_svr_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_udp_client_receiver_options=.*/rtcm_udp_client_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_serial_receiver_options=.*/rtcm_serial_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
}

clear_TADJ() {
    #add option -TADJ=1 on rtcm/ntrip_a/ntrip_b/serial outputs
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_a_receiver_options=.*/ntrip_a_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_b_receiver_options=.*/ntrip_b_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^local_ntripc_receiver_options=.*/local_ntripc_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_receiver_options=.*/rtcm_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_client_receiver_options=.*/rtcm_client_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_udp_svr_receiver_options=.*/rtcm_udp_svr_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_udp_client_receiver_options=.*/rtcm_udp_client_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_serial_receiver_options=.*/rtcm_serial_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
}

configure_unicore(){
    RECVPORT=${1}
    RECVNAME=${2}
    FIRMWARE=${3}

    echo Receiver ${RECVNAME}\(${FIRMWARE}\) found on ${RECVPORT}
    RECVCONF=${rtkbase_path}/receiver_cfg/${RECVNAME}_RTCM3_OUT.txt
    #echo RECVCONF=${RECVCONF}

    if [[ -f "${RECVCONF}" ]]
    then
       #echo ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVCONF} QUIET
       ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVCONF} QUIET
       exitcode=$?
       #echo exitcode=${exitcode}
       SPEED=115200
       if [[ ${exitcode} == 0 ]]
       then
          #now that the receiver is configured, we can set the right values inside settings.conf
          sudo -u "${RTKBASE_USER}" sed -i s/^receiver_firmware=.*/receiver_firmware=\'${FIRMWARE}\'/ "${rtkbase_path}"/settings.conf
          sudo -u "${RTKBASE_USER}" sed -i s/^com_port_settings=.*/com_port_settings=\'${SPEED}:8:n:1\'/ "${rtkbase_path}"/settings.conf
          sudo -u "${RTKBASE_USER}" sed -i s/^receiver=.*/receiver=\'Unicore_${RECVNAME}\'/ "${rtkbase_path}"/settings.conf
          sudo -u "${RTKBASE_USER}" sed -i s/^receiver_format=.*/receiver_format=\'rtcm3\'/ "${rtkbase_path}"/settings.conf
          clear_TADJ
       else
          echo Confiuration FAILED for ${RECVNAME} on ${RECVPORT}
       fi
       RECEIVER_CONF=${rtkbase_path}/receiver.conf
       echo recv_port=${com_port}>${RECEIVER_CONF}
       echo recv_speed=${SPEED}>>${RECEIVER_CONF}
       echo recv_position=>>${RECEIVER_CONF}
       chown ${RTKBASE_USER}:${RTKBASE_USER} ${RECEIVER_CONF}
       return ${exitcode}
    else
       echo Confiuration file for ${RECVNAME} \(${RECVCONF}\) NOT FOUND.
       return 1
    fi
}

configure_bynav(){
    RECVPORT=${1}
    RECVNAME=${2}
    FIRMWARE=${3}
    RECVDEV=${4}
    RECVSPEED=${5}

    echo Receiver ${RECVNAME}\(${FIRMWARE}\) found on ${RECVPORT}
    RECVCONF=${rtkbase_path}/receiver_cfg/Bynav_RTCM3_OUT.txt
    #echo RECVCONF=${RECVCONF} RECVPORT=${RECVPORT} RECVSPEED=${RECVSPEED}

    if [[ -f "${RECVCONF}" ]]
    then
       if [[ "${RECVSPEED}" != "115200" ]]
       then
          RECVCOM=`${rtkbase_path}/NmeaConf ${RECVPORT} TEST COM | grep COM`
          #echo RECVCOM=${RECVCOM}
          #echo ${rtkbase_path}/${NMEACONF} ${RECVPORT} \"SERIALCONFIG ${RECVCOM} 115200\" QUIET
          ${rtkbase_path}/${NMEACONF} ${RECVPORT} "SERIALCONFIG ${RECVCOM} 115200" QUIET
          RECVPORT=${RECVDEV}:115200
          #echo NEW RECVPORT=${RECVPORT}
       fi

       #echo ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVCONF} QUIET
       ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVCONF} QUIET
       exitcode=$?
       #echo exitcode=${exitcode}
       SPEED=115200
       if [[ ${exitcode} == 0 ]]
       then
          #now that the receiver is configured, we can set the right values inside settings.conf
          sudo -u "${RTKBASE_USER}" sed -i s/^receiver_firmware=.*/receiver_firmware=\'${FIRMWARE}\'/ "${rtkbase_path}"/settings.conf
          sudo -u "${RTKBASE_USER}" sed -i s/^com_port_settings=.*/com_port_settings=\'${SPEED}:8:n:1\'/ "${rtkbase_path}"/settings.conf
          sudo -u "${RTKBASE_USER}" sed -i s/^receiver=.*/receiver=\'Bynav_${RECVNAME}\'/ "${rtkbase_path}"/settings.conf
          sudo -u "${RTKBASE_USER}" sed -i s/^receiver_format=.*/receiver_format=\'rtcm3\'/ "${rtkbase_path}"/settings.conf
          clear_TADJ
       else
          echo Confiuration FAILED for ${RECVNAME} on ${RECVPORT}
       fi
       RECEIVER_CONF=${rtkbase_path}/receiver.conf
       echo recv_port=${com_port}>${RECEIVER_CONF}
       echo recv_speed=${SPEED}>>${RECEIVER_CONF}
       echo recv_position=>>${RECEIVER_CONF}
       chown ${RTKBASE_USER}:${RTKBASE_USER} ${RECEIVER_CONF}
       return ${exitcode}
    else
       echo Confiuration file for ${RECVNAME} \(${RECVCONF}\) NOT FOUND.
       return 1
    fi
}


configure_gnss(){
    echo '################################'
    echo 'CONFIGURE GNSS RECEIVER'
    echo '################################'
      if [ -d "${rtkbase_path}" ]
      then
        source <( grep -v '^#' "${rtkbase_path}"/settings.conf | grep '=' )
        stoping_main
        if [[ "${com_port}" == "" ]]
        then
           echo 'GNSS receiver is not specified. We can'\''t configure.'
           return 1
        fi

        RECVSPEED=${com_port_settings%%:*}
        RECVDEV=/dev/${com_port}
        RECVPORT=${RECVDEV}:${RECVSPEED}
        RECVVER=`${rtkbase_path}/${NMEACONF} ${RECVPORT} VERSION SILENT`
        #echo RECVVER=${RECVVER}
        RECVERROR=`echo ${RECVVER} | grep ERROR`
        #echo RECVERROR=${RECVERROR}

        RECVNAME=
        FIRMWARE=
        if [[ ${RECVERROR} == "" ]] && [[ "${RECVVER}" != "" ]]
        then
           RECVNAME=`echo ${RECVVER} | awk -F ';' '{print $2}'| awk -F ',' '{print $1}'`
           #echo RECVNAME=${RECVNAME}
           FIRMWARE=`echo ${RECVVER} | awk -F ';' '{print $2}'| awk -F ',' '{print $2}'`
           #echo FIRMWARE=${FIRMWARE}
        fi
        if [[ ${RECVNAME} != "" ]] && [[ ${FIRMWARE} != "" ]]
        then
           configure_unicore ${RECVPORT} ${RECVNAME} ${FIRMWARE}
        else
           RECVINFO=`${rtkbase_path}/${NMEACONF} ${RECVPORT} "LOG AUTHORIZATION" QUIET`
           RECVNAME=
           if [[ "${RECVINFO}" != "" ]]
           then
              #echo RECVINFO=${RECVINFO}
              RECVNAME=`echo ${RECVINFO} | awk -F ';' '{print $2}'| awk -F ' ' '{print $2}'`
           fi
           RECVVER=`${rtkbase_path}/${NMEACONF} ${RECVPORT} "LOG VERSION" QUIET`
           #echo RECVVER=${RECVVER}
           FIRMWARE=`echo ${RECVVER} | awk -F ',' '{print $2}'`
           #echo FIRMWARE=${FIRMWARE}
           if [[ "${RECVNAME}" != "" ]] && [[ "${FIRMWARE}" != "" ]]
           then
              configure_bynav ${RECVPORT} ${RECVNAME} ${FIRMWARE} ${RECVDEV} ${RECVSPEED}
           elif [[ $(python3 "${rtkbase_path}"/tools/sept_tool.py --port /dev/ttyGNSS_CTRL --baudrate ${com_port_settings%%:*} --command get_model --retry 5) =~ 'mosaic-X5' ]]
           then
             echo get mosaic-X5 firmware release
             firmware="$(python3 "${rtkbase_path}"/tools/sept_tool.py --port /dev/ttyGNSS_CTRL --baudrate ${com_port_settings%%:*} --command get_firmware --retry 5)" || firmware='?'
             echo 'Mosaic-X5 Firmware: ' "${firmware}"
             sudo -u "${RTKBASE_USER}" sed -i s/^receiver_firmware=.*/receiver_firmware=\'${firmware}\'/ "${rtkbase_path}"/settings.conf
             #configure the mosaic-X5 for RTKBase
             echo 'Resetting the mosaic-X5 settings....'
             python3 "${rtkbase_path}"/tools/sept_tool.py --port /dev/ttyGNSS_CTRL --baudrate ${com_port_settings%%:*} --command reset --retry 5
             sleep_time=30 ; echo 'Waiting '$sleep_time's for mosaic-X5 reboot' ; sleep $sleep_time
             echo 'Sending settings....'
             python3 "${rtkbase_path}"/tools/sept_tool.py --port /dev/ttyGNSS_CTRL --baudrate ${com_port_settings%%:*} --command send_config_file "${rtkbase_path}"/receiver_cfg/Septentrio_Mosaic-X5.cfg --store --retry 5
             if [[ $? -eq  0 ]]
             then
               echo 'Septentrio Mosaic-X5 successfuly configured'
               systemctl list-unit-files rtkbase_gnss_web_proxy.service &>/dev/null                                                          && \
               systemctl enable --now rtkbase_gnss_web_proxy.service                                                                         && \
               clear_TADJ                                                                                                                    && \
               sudo -u "${RTKBASE_USER}" sed -i s/^com_port_settings=.*/com_port_settings=\'115200:8:n:1\'/ "${rtkbase_path}"/settings.conf  && \
               sudo -u "${RTKBASE_USER}" sed -i s/^receiver=.*/receiver=\'Septentrio_Mosaic-X5\'/ "${rtkbase_path}"/settings.conf            && \
               sudo -u "${RTKBASE_USER}" sed -i s/^receiver_format=.*/receiver_format=\'sbf\'/ "${rtkbase_path}"/settings.conf
               return $?
             else
               echo 'Failed to configure the Septentrio receiver'
               return 1
             fi
           elif [[ $(python3 "${rtkbase_path}"/tools/ubxtool -f /dev/"${com_port}" -s ${com_port_settings%%:*} -p MON-VER) =~ 'ZED-F9P' ]]
           then
              echo get F9P firmware release
              firmware=$(python3 "${rtkbase_path}"/tools/ubxtool -f /dev/"${com_port}" -s ${com_port_settings%%:*} -p MON-VER | grep 'FWVER' | awk '{print $NF}')
              echo 'F9P Firmware: ' "${firmware}"
              sudo -u "${RTKBASE_USER}" sed -i s/^receiver_firmware=.*/receiver_firmware=\'${firmware}\'/ "${rtkbase_path}"/settings.conf
              #configure the F9P for RTKBase
              "${rtkbase_path}"/tools/set_zed-f9p.sh /dev/${com_port} ${com_port_settings%%:*} "${rtkbase_path}"/receiver_cfg/U-Blox_ZED-F9P_rtkbase.cfg && \
              echo 'U-Blox F9P Successfuly configured'                                                                                                   && \
              #now that the receiver is configured, we can set the right values inside settings.conf
              sudo -u "${RTKBASE_USER}" sed -i s/^com_port_settings=.*/com_port_settings=\'115200:8:n:1\'/ "${rtkbase_path}"/settings.conf               && \
              sudo -u "${RTKBASE_USER}" sed -i s/^receiver=.*/receiver=\'U-blox_ZED-F9P\'/ "${rtkbase_path}"/settings.conf                               && \
              sudo -u "${RTKBASE_USER}" sed -i s/^receiver_format=.*/receiver_format=\'ubx\'/ "${rtkbase_path}"/settings.conf                            && \
              add_TADJ                                                                                                                                   && \
              #remove SBAS Rtcm message (1107) as it is disabled in the F9P configuration.
              sudo -u "${RTKBASE_USER}" sed -i -r '/^rtcm_/s/1107(\([0-9]+\))?,//' "${rtkbase_path}"/settings.conf                                       && \
              return $?
           else
              echo 'No Gnss receiver has been set. We can'\''t configure '${RECVPORT}
              return 1
           fi
        fi
      else #if [ -d "${rtkbase_path}" ]
        echo 'RtkBase not installed, use option --rtkbase-release'
        return 1
      fi
}


main() {
  # If rtkbase is installed but the OS wasn't restarted, then the system wide
  # rtkbase_path variable is not set in the current shell. We must source it
  # from /etc/environment or set it to the default value "rtkbase":
  
  if [[ -z ${rtkbase_path} ]]
  then
    if grep -q '^rtkbase_path=' /etc/environment
    then
      source /etc/environment
    else 
      export rtkbase_path='rtkbase'
    fi
  fi
  
  #display parameters
  #parsing with getopt: https://www.shellscript.sh/tips/getopt/index.html
  ARG_USER=0
  ARG_DETECT_GNSS=0
  ARG_NO_WRITE_PORT=0
  ARG_CONFIGURE_GNSS=0

  PARSED_ARGUMENTS=$(getopt --name install --options u:enc --longoptions user:,detect-gnss,no-write-port,configure-gnss -- "$@")
  VALID_ARGUMENTS=$?
  if [ "$VALID_ARGUMENTS" != "0" ]; then
    #man_help
    echo 'Try '\''install.sh --help'\'' for more information'
    exit 1
  fi

  #echo "PARSED_ARGUMENTS is $PARSED_ARGUMENTS"
  eval set -- "$PARSED_ARGUMENTS"
  while :
    do
      case "$1" in
        -u | --user)   ARG_USER="${2}"                 ; shift 2 ;;
        -e | --detect-gnss) ARG_DETECT_GNSS=1  ; shift   ;;
        -n | --no-write-port) ARG_NO_WRITE_PORT=1      ; shift   ;;
        -c | --configure-gnss) ARG_CONFIGURE_GNSS=1    ; shift   ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        # If invalid options were passed, then getopt should have reported an error,
        # which we checked as VALID_ARGUMENTS when getopt was called...
        *) echo "Unexpected option: $1"
          usage ;;
      esac
    done
  cumulative_exit=0
  _check_user "${ARG_USER}" #; echo 'user for RTKBase is: ' "${RTKBASE_USER}"
  #if [ $ARG_USER != 0 ] ;then echo 'user:' "${ARG_USER}"; check_user "${ARG_USER}"; else ;fi

  [ $ARG_DETECT_GNSS -eq 1 ] &&  { detect_gnss "${ARG_NO_WRITE_PORT}" ; ((cumulative_exit+=$?)) ;}
  [ $ARG_CONFIGURE_GNSS -eq 1 ] && { configure_gnss ; ((cumulative_exit+=$?)) ;}
}

main "$@"
#echo 'cumulative_exit: ' $cumulative_exit
exit $cumulative_exit
