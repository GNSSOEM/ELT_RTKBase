#!/bin/bash

### RTKBASE INSTALLATION SCRIPT ###
declare -a detected_gnss
declare RTKBASE_USER
BASEDIR=`realpath $(dirname $(readlink -f "$0"))`
NMEACONF=NmeaConf
DEFAULT_ANT=ELT0123
SPEED=115200

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

detect_Unicore() {
    echo 'DETECTION Unicore ON ' ${1} ' at ' ${2}
    RECVPORT=/dev/${1}:${2}
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
          #echo Receiver ${RECVNAME}\(${FIRMWARE}\) found on ${1} ${2}
          detected_gnss[0]=${1}
          detected_gnss[1]=Unicore_${RECVNAME}
          detected_gnss[2]=${port_speed}
       fi
    fi
}


detect_speed_Unicore() {
    for port_speed in 115200 921600 230400 460800; do
        detect_Unicore ${1} ${port_speed}
        [[ ${#detected_gnss[*]} -ge 3 ]] && break
    done
}

detect_Bynav() {
    echo 'DETECTION Bynav ON ' ${1} ' at ' ${2}
    RECVPORT=/dev/${1}:${2}
    RECVINFO=`${rtkbase_path}/${NMEACONF} ${RECVPORT} "LOG AUTHORIZATION" SILENT`
    if [[ "${RECVINFO}" != "" ]]
    then
       #echo RECVINFO=${RECVINFO}
       RECVNAME=`echo ${RECVINFO} | awk -F ';' '{print $2}'| awk -F ' ' '{print $2}'`
       if [[ ${RECVNAME} != "" ]]
       then
          #echo Receiver ${RECVNAME} found on ${1} ${2}
          detected_gnss[0]=${1}
          detected_gnss[1]=Bynav_${RECVNAME}
          detected_gnss[2]=${2}
       fi
    fi
}

detect_speed_Bynav() {
    for port_speed in 115200 921600 230400 460800; do
        detect_Bynav ${1} ${port_speed}
        [[ ${#detected_gnss[*]} -ge 3 ]] && break
    done
}

detect_Ublox() {
    echo 'DETECTION Ublox ON ' ${1} ' at ' ${2}
    RECVPORT=/dev/${1}:${2}
    ubxVer=$(${rtkbase_path}/${NMEACONF} ${RECVPORT} "UBX-MON-VER" SILENT)
    lastcode=$?
    #echo lastcode=${lastcode} ubxVer=${ubxVer}
    if [[ "${lastcode}" == 0 ]]; then
       ubxName=$(echo ${ubxVer} | awk -F ',' '{print $1}')
       #echo Receiver ${ubxName} found on ${1} ${port_speed}
       detected_gnss[0]=${1}
       detected_gnss[1]=u-blox_${ubxName}
       detected_gnss[2]=${2}
    fi
}

detect_speed_Ublox() {
    for port_speed in 38400 115200 921600 230400 460800 9600; do
        detect_Ublox ${1} ${port_speed}
        [[ ${#detected_gnss[*]} -ge 3 ]] && break
    done
}

set_septetrio_format() {
    detected_gnss[3]=rtcm3
    if [[ -c /dev/gpiochip0 ]]; then
       CHIP=0
    elif [[ -c /dev/gpiochip512 ]]; then
       CHIP=512
    else
       echo Raspberry gpiochip NOT found!
       return
    fi
    gpio4=$(gpioget gpiochip${CHIP} 4)
    if [[ "${gpio4}" == "0" ]]; then
       detected_gnss[3]=sbf
    fi
    #echo gpio4=${gpio4} detected_gnss[3]=${detected_gnss[3]}
}

detect_Septentrio() {
    echo 'DETECTION Septentrio ON ' ${1} ' at ' ${2}
    RECVPORT=/dev/${1}:${2}
    RECVTEST=${rtkbase_path}/receiver_cfg/Septentrio_TEST.txt
    #echo RECVINFO=\`${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVTEST} SILENT | grep "hwplatform product"\`
    RECVINFO=`${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVTEST} SILENT | grep "hwplatform product"`
    if [[ "${RECVINFO}" != "" ]]
    then
       #echo RECVINFO=${RECVINFO}
       RECVNAME=`echo ${RECVINFO} | awk -F '"' '{print $2}'`
       if [[ ${RECVNAME} != "" ]]
       then
          echo Receiver ${RECVNAME} found on ${1} ${2}
          detected_gnss[0]=${1}
          detected_gnss[1]=Septentrio_${RECVNAME}
          detected_gnss[2]=${2}
          set_septetrio_format
       fi
    fi
}

detect_speed_Septentrio() {
    for port_speed in 115200 921600 230400 460800; do
        detect_Septentrio ${1} ${port_speed}
        [[ ${#detected_gnss[*]} -eq 4 ]] && break
    done
}

detect_speed_Unicore_Ublox() {
    for port_speed in 115200 38400 921600 230400 460800 9600; do
        if [[ ${port_speed} -ge 115200 ]]; then
           detect_Unicore ${1} ${port_speed}
           [[ ${#detected_gnss[*]} -ge 3 ]] && break
        fi
        detect_Ublox ${1} ${port_speed}
        [[ ${#detected_gnss[*]} -ge 3 ]] && break
    done
}

detect_speed_All() {
    for port_speed in 115200 38400 921600 230400 460800 9600; do
        if [[ ${port_speed} -ge 115200 ]]; then
           detect_Unicore ${1} ${port_speed}
           [[ ${#detected_gnss[*]} -ge 3 ]] && break
           detect_Bynav ${1} ${port_speed}
           [[ ${#detected_gnss[*]} -ge 3 ]] && break
           detect_Septentrio ${1} ${port_speed}
           [[ ${#detected_gnss[*]} -ge 3 ]] && break
        fi
        detect_Ublox ${1} ${port_speed}
        [[ ${#detected_gnss[*]} -ge 3 ]] && break
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
         BynavDevices=/run/BynavDevlist.txt
         CypressDevices=/run/CypressDevlist.txt
         rm -rf "${BynavDevices}" "${CypressDevices}"
         for sysdevpath in $(find /sys/bus/usb/devices/usb*/ -name dev); do
             ID_SERIAL=''
             syspath="${sysdevpath%/dev}"
             devname="$(udevadm info -q name -p "${syspath}")"
             if [[ "$devname" == "bus/"* ]]; then continue; fi
             #echo sysdevpath=${sysdevpath} syspath=${syspath} devname=${devname}
             eval "$(udevadm info -q property --export -p "${syspath}")"
             #udevadm info -q property -p "${syspath}")"
             #echo devname=${devname} ID_SERIAL=${ID_SERIAL}
             if [[ -z "$ID_SERIAL" ]]; then continue; fi
             IS_SERIAL=`echo ${DEVLINKS}|grep serial`
             #echo devname=${devname} ID_SERIAL=${ID_SERIAL} IS_SERIAL=${IS_SERIAL}
             if [[ -z "$IS_SERIAL" ]]; then continue; fi
             if [[ "$ID_SERIAL" =~ (u-blox|skytraq) ]]; then
                detect_Ublox ${devname} 115200
                #echo '/dev/'"${detected_gnss[0]}" ' - ' "${detected_gnss[1]}"
                # If /dev/ttyGNSS is a symlink of the detected serial port, we've found the gnss receiver, break the loop.
                # This test is useful with gnss receiver offering several serial ports (like mosaic X5). The Udev rule should symlink the right one with ttyGNSS
                [[ '/dev/ttyGNSS' -ef '/dev/'"${detected_gnss[0]}" ]] && break
             elif [[ "$ID_SERIAL" =~ Septentrio ]]; then
                if [[ '/dev/ttyGNSS' -ef '/dev/'"${devname}" ]]; then
                   detect_Septentrio ttyGNSS_CTRL 115200
                   detected_gnss[0]=ttyGNSS
                   [[ ${#detected_gnss[*]} -ge 3 ]] && break
                   detected_gnss[1]=`echo  $ID_SERIAL | sed s/^Septentrio_Septentrio_/Septentrio_/`
                   set_septetrio_format
                   break
                fi
             elif [[ "$ID_SERIAL" =~ ELT0x33 ]]; then
                #echo detect ELT0x33 ${devname}
                #echo sysdevpath=${sysdevpath} syspath=${syspath} devname=${devname}
                detected_ELT0x33=Y
                #echo ${rtkbase_path}/tools/onoffELT0x33.sh ${devname} ON
                ${rtkbase_path}/tools/onoffELT0x33.sh ${devname} ON
                #echo detect_speed_All ${devname}
                detect_speed_All ${devname}
             elif [[ "$ID_SERIAL" == "Cypress_Semiconductor_USB-Serial__Dual_Channel_" ]]; then
                echo ${devname} >> "${CypressDevices}"
             elif [[ "$ID_SERIAL" =~ FTDI_FT230X_Basic_UART ]]; then
                #echo detect_speed_Unicore ${devname}
                detect_speed_Unicore ${devname}
                [[ ${#detected_gnss[*]} -ge 3 ]] && break
                #echo detect_speed_Bynav ${devname}
                detect_speed_Bynav ${devname}
             elif [[ "$ID_SERIAL" =~ 1a86_USB_Dual_Serial ]]; then # 1a86 - QinHeng Electronics, CH340 or CH341
                echo ${devname} >> "${BynavDevices}"
             elif [[ "$ID_SERIAL" =~ FTDI_TTL232R-3V3 ]]; then
                #echo detect_speed_Ublox ${devname}
                detect_speed_Ublox ${devname}
             else                                                  # ordinary CH340 - "1a86_USB_Serial"
                #echo detect_speed_All ${devname}
                detect_speed_All ${devname}
             fi
             #echo '/dev/'"${detected_gnss[0]}" ' - ' "${detected_gnss[1]}"' - ' "${detected_gnss[2]}"
             [[ ${#detected_gnss[*]} -ge 3 ]] && break
         done
         if [[ "${detected_ELT0x33}" == "Y" ]]; then
            #echo ${rtkbase_path}/tools/onoffELT0x33.sh ${devname} OFF
            ${rtkbase_path}/tools/onoffELT0x33.sh ${devname} OFF
         fi
         if [[ -f  "${BynavDevices}" ]]; then
            #cat "${BynavDevices}"
            for devname in `cat "${BynavDevices}" | sort`; do
                #echo detect_speed_Bynav ${devname}
                detect_speed_Bynav ${devname}
                #echo '/dev/'"${detected_gnss[0]}" ' - ' "${detected_gnss[1]}"' - ' "${detected_gnss[2]}"
                [[ ${#detected_gnss[*]} -ge 3 ]] && break
            done
            rm -rf "${BynavDevices}"
         fi
         if [[ -f  "${CypressDevices}" ]]; then
            #cat "${CypressDevices}"
            for devname in `cat "${CypressDevices}" | sort`; do
                #echo detect_speed_Unicore_Ublox ${devname}
                detect_speed_Unicore_Ublox ${devname}
                [[ ${#detected_gnss[*]} -ge 3 ]] && break
            done
            rm -rf "${CypressDevices}"
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
            if [[ -c /dev/${port} ]]; then
               detect_speed_All ${port}
               [[ ${#detected_gnss[*]} -ge 3 ]] && break
            fi
        done
      fi
}

detect_configure() {
      # Test if speed is in detected_gnss array. If not, add the default value.
      [[ ${#detected_gnss[*]} -eq 2 ]] && detected_gnss[2]='115200'
      [[ ${detected_gnss[2]} == "" ]] && detected_gnss[2]='115200'
      # If /dev/ttyGNSS is a symlink of the detected serial port, switch to ttyGNSS
      [[ '/dev/ttyGNSS' -ef '/dev/'"${detected_gnss[0]}" ]] && detected_gnss[0]='ttyGNSS'
      [[ ${#detected_gnss[*]} -eq 3 ]] && detected_gnss[3]='rtcm3'
      # "send" result
      echo '/dev/'"${detected_gnss[0]}" ' - ' "${detected_gnss[1]}"' - ' "${detected_gnss[2]}"' - ' "${detected_gnss[3]}"

      #Write Gnss receiver settings inside settings.conf
      #Optional argument --no-write-port (here as variable $1) will prevent settings.conf modifications. It will be just a detection without any modification. 
      if [[ ${#detected_gnss[*]} -eq 4 ]] && [[ "${1}" -eq 0 ]]
        then
          echo 'GNSS RECEIVER DETECTED: /dev/'"${detected_gnss[0]}" ' - ' "${detected_gnss[1]}" ' - ' "${detected_gnss[2]}" ' - ' "${detected_gnss[3]}"

          if [[ -f "${rtkbase_path}/settings.conf" ]]  && grep -qE "^com_port=.*" "${rtkbase_path}"/settings.conf #check if settings.conf exists
          then
            #change the com port value/settings inside settings.conf
            sudo -u "${RTKBASE_USER}" sed -i "s/^com_port=.*/com_port=\'${detected_gnss[0]}\'/" "${rtkbase_path}"/settings.conf
            sudo -u "${RTKBASE_USER}" sed -i "s/^receiver=.*/receiver=\'${detected_gnss[1]}\'/" "${rtkbase_path}"/settings.conf
            sudo -u "${RTKBASE_USER}" sed -i "s/^com_port_settings=.*/com_port_settings=\'${detected_gnss[2]}:8:n:1\'/" "${rtkbase_path}"/settings.conf
            sudo -u "${RTKBASE_USER}" sed -i "s/^receiver_format=.*/receiver_format=\'${detected_gnss[3]}\'/" "${rtkbase_path}"/settings.conf

            RECEIVER_CONF=${rtkbase_path}/receiver.conf
            echo recv_port=${detected_gnss[0]}>${RECEIVER_CONF}
            echo recv_speed=${detected_gnss[2]}>>${RECEIVER_CONF}
            echo recv_position=>>${RECEIVER_CONF}
            echo recv_ant=>>${RECEIVER_CONF}
            chown ${RTKBASE_USER}:${RTKBASE_USER} ${RECEIVER_CONF}
          else
            echo 'settings.conf is missing'
            return 1
          fi
      elif [[ ${#detected_gnss[*]} -ne 4 ]]
        then
          return 1
      fi
      return 0
}

stoping_main() {
   for i in `seq 1 3`; do
       str2str_active=$(systemctl is-active str2str_tcp)
       #echo str2str_active=${str2str_active}

       if [[ "${str2str_active}" == "active" ]] || [[ "${str2str_active}" == "activating" ]] || [[ "${str2str_active}" == "reloading" ]] || [[ "${str2str_active}" == "refreshing" ]]; then
          #echo systemctl stop str2str_tcp
          systemctl stop str2str_tcp
       elif [[ "${str2str_active}" == "deactivating" ]]; then
          sleep 1
       else
          break
       fi
   done
}

detect_gnss() {
    stoping_main
    detect_usb
    if [[ ${#detected_gnss[*]} < 2 ]] && [[ "${detected_ELT0x33}" != "Y" ]]; then
       detect_uart
    fi
    detect_configure ${1}
}

change_mode_to_NTRIPv1() {
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_a=\'2\'/svr_mode_a=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_b=\'2\'/svr_mode_b=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_c=\'2\'/svr_mode_c=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_d=\'2\'/svr_mode_d=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_e=\'2\'/svr_mode_e=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_a=\'3\'/svr_mode_a=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_b=\'3\'/svr_mode_b=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_c=\'3\'/svr_mode_c=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_d=\'3\'/svr_mode_d=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_e=\'3\'/svr_mode_e=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_a=\'4\'/svr_mode_a=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_b=\'4\'/svr_mode_b=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_c=\'4\'/svr_mode_c=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_d=\'4\'/svr_mode_d=\'0\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^svr_mode_e=\'4\'/svr_mode_e=\'0\'/ "${rtkbase_path}"/settings.conf
}

add_TADJ() {
    #add option -TADJ=1 on rtcm/ntrip_a/ntrip_b/serial outputs
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_a_receiver_options=.*/ntrip_a_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_b_receiver_options=.*/ntrip_b_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_c_receiver_options=.*/ntrip_c_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_d_receiver_options=.*/ntrip_d_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_e_receiver_options=.*/ntrip_e_receiver_options=\'-TADJ=1\'/ "${rtkbase_path}"/settings.conf
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
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_c_receiver_options=.*/ntrip_c_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_d_receiver_options=.*/ntrip_d_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^ntrip_e_receiver_options=.*/ntrip_e_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^local_ntripc_receiver_options=.*/local_ntripc_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_receiver_options=.*/rtcm_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_client_receiver_options=.*/rtcm_client_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_udp_svr_receiver_options=.*/rtcm_udp_svr_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_udp_client_receiver_options=.*/rtcm_udp_client_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^rtcm_serial_receiver_options=.*/rtcm_serial_receiver_options=\'\'/ "${rtkbase_path}"/settings.conf
}

configure_unicore(){
    RECVPORT=${1}

    RECVVER=`${rtkbase_path}/${NMEACONF} ${RECVPORT} VERSION SILENT`
    #echo RECVVER=${RECVVER}
    RECVERROR=`echo ${RECVVER} | grep ERROR`
    #echo RECVERROR=${RECVERROR}
    RECVGOOD=`echo ${RECVVER} | grep "^>#VERSION"`
    #echo RECVERROR=${RECVERROR}

    RECVNAME=
    FIRMWARE=
    if [[ ${RECVERROR} == "" ]] && [[ "${RECVGOOD}" != "" ]] && [[ "${RECVVER}" != "" ]]
    then
       RECVNAME=`echo ${RECVVER} | awk -F ';' '{print $2}'| awk -F ',' '{print $1}'`
       #echo RECVNAME=${RECVNAME}
       FIRMWARE=`echo ${RECVVER} | awk -F ';' '{print $2}'| awk -F ',' '{print $2}'`
       #echo FIRMWARE=${FIRMWARE}
    fi
    if [[ ${RECVNAME} == "" ]] || [[ ${FIRMWARE} == "" ]]; then
       echo Receiver Unicore not found on ${RECVPORT}
       return 1
    fi

    echo Receiver ${RECVNAME}\(${FIRMWARE}\) found on ${RECVPORT}
    RECVCONF=${rtkbase_path}/receiver_cfg/${RECVNAME}_RTCM3_OUT.txt
    #echo RECVCONF=${RECVCONF}

    #now that the receiver is configured, we can set the right values inside settings.conf
    sudo -u "${RTKBASE_USER}" sed -i "s/^receiver_firmware=.*/receiver_firmware=\'${FIRMWARE}\'/" "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^com_port_settings=.*/com_port_settings=\'${SPEED}:8:n:1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^receiver=.*/receiver=\'Unicore_${RECVNAME}\'/ "${rtkbase_path}"/settings.conf
    clear_TADJ

    if [[ -f "${RECVCONF}" ]]
    then
       #echo ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVCONF} QUIET
       recv_com=`${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVCONF} COM | tee /dev/stderr | grep "^COM.$"`
       exitcode=$?
       #echo recv_com=${recv_com}
       #echo exitcode=${exitcode}
       if [[ ${exitcode} != 0 ]]
       then
          echo Confiuration FAILED for ${RECVNAME} on ${RECVPORT}
       fi
       RECEIVER_CONF=${rtkbase_path}/receiver.conf
       echo recv_port=${com_port}>${RECEIVER_CONF}
       echo recv_speed=${SPEED}>>${RECEIVER_CONF}
       echo recv_position=>>${RECEIVER_CONF}
       echo recv_ant=${DEFAULT_ANT}>>${RECEIVER_CONF}
       echo recv_com=${recv_com}>>${RECEIVER_CONF}
       chown ${RTKBASE_USER}:${RTKBASE_USER} ${RECEIVER_CONF}
       return ${exitcode}
    else
       echo Confiuration file for ${RECVNAME} \(${RECVCONF}\) NOT FOUND.
       return 1
    fi
}

configure_bynav(){
    RECVPORT=${1}
    RECVDEV=${2}
    RECVSPEED=${3}

    RECVNAME=
    for i in `seq 1 3`; do
       RECVINFO=`${rtkbase_path}/${NMEACONF} ${RECVPORT} "LOG AUTHORIZATION" QUIET`

       if [[ "${RECVINFO}" != "" ]]; then
          #echo RECVINFO=${RECVINFO}
          RECVNAME=`echo ${RECVINFO} | awk -F ';' '{print $2}'| awk -F ' ' '{print $2}'`
          #echo RECVNAME=${RECVNAME}
          if [[ "${RECVNAME}" =~ ^M ]]; then
             break
          else
             echo Invalid receiver name \<${RECVNAME}\>
             RECVNAME=
          fi
       fi
    done

    for i in `seq 1 3`; do
        RECVVER=`${rtkbase_path}/${NMEACONF} ${RECVPORT} "LOG VERSION" QUIET`
        #echo RECVVER=${RECVVER}
        if [[ "${RECVVER}" =~ ^"$BDVER" ]]; then
           break
        else
           RECVVER=
        fi
    done

    FIRMWARE=`echo ${RECVVER} | awk -F ',' '{print $2}'`
    #echo FIRMWARE=${FIRMWARE}
    if [[ "${RECVNAME}" == "" ]] || [[ "${FIRMWARE}" == "" ]]; then
       echo Receiver Bynav not found on ${RECVPORT}
       return 1
    fi

    echo Receiver ${RECVNAME}\(${FIRMWARE}\) found on ${RECVPORT}
    RECVCONF=${rtkbase_path}/receiver_cfg/Bynav_RTCM3_OUT.txt
    #echo RECVCONF=${RECVCONF} RECVPORT=${RECVPORT} RECVSPEED=${RECVSPEED}

    #now that the receiver is configured, we can set the right values inside settings.conf
    sudo -u "${RTKBASE_USER}" sed -i "s/^receiver_firmware=.*/receiver_firmware=\'${FIRMWARE}\'/" "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^com_port_settings=.*/com_port_settings=\'${SPEED}:8:n:1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^receiver=.*/receiver=\'Bynav_${RECVNAME}\'/ "${rtkbase_path}"/settings.conf
    clear_TADJ

    if [[ -f "${RECVCONF}" ]]
    then
       recv_com=`${rtkbase_path}/NmeaConf ${RECVPORT} TEST COM | grep "^COM.$"`
       #echo recv_com=${recv_com}
       if [[ "${RECVSPEED}" != "115200" ]]
       then
          #echo ${rtkbase_path}/${NMEACONF} ${RECVPORT} \"SERIALCONFIG ${recv_com} 115200\" QUIET
          ${rtkbase_path}/${NMEACONF} ${RECVPORT} "SERIALCONFIG ${recv_com} 115200" QUIET 2>&1
          RECVPORT=${RECVDEV}:115200
          #echo NEW RECVPORT=${RECVPORT}
       fi

       #echo ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVCONF} QUIET
       ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVCONF} QUIET 2>&1
       exitcode=$?
       #echo exitcode=${exitcode}
       if [[ ${exitcode} != 0 ]]
       then
          echo Confiuration FAILED for ${RECVNAME} on ${RECVPORT}
       fi
       RECEIVER_CONF=${rtkbase_path}/receiver.conf
       echo recv_port=${com_port}>${RECEIVER_CONF}
       echo recv_speed=${SPEED}>>${RECEIVER_CONF}
       echo recv_position=>>${RECEIVER_CONF}
       echo recv_ant=${DEFAULT_ANT}>>${RECEIVER_CONF}
       echo recv_com=${recv_com}>>${RECEIVER_CONF}
       chown ${RTKBASE_USER}:${RTKBASE_USER} ${RECEIVER_CONF}
       return ${exitcode}
    else
       echo Confiuration file for ${RECVNAME} \(${RECVCONF}\) NOT FOUND.
       return 1
    fi
}

configure_septentrio_SBF(){
    RECVPORT=${1}
    RECVSPEED=${2}
    #echo RECVPORT=${RECVPORT} RECVSPEED=${RECVSPEED}

    if [[ $(python3 "${rtkbase_path}"/tools/sept_tool.py --port ${RECVPORT} --baudrate ${RECVSPEED} --command get_model --retry 5) =~ 'mosaic-X5' ]]
    then
      echo get mosaic-X5 firmware release
      firmware="$(python3 "${rtkbase_path}"/tools/sept_tool.py --port ${RECVPORT} --baudrate ${RECVSPEED} --command get_firmware --retry 5)" || firmware='?'
      echo 'Mosaic-X5 Firmware: ' "${firmware}"
      sudo -u "${RTKBASE_USER}" sed -i "s/^receiver_firmware=.*/receiver_firmware=\'${firmware}\'/" "${rtkbase_path}"/settings.conf   && \
      sudo -u "${RTKBASE_USER}" sed -i s/^com_port_settings=.*/com_port_settings=\'${SPEED}:8:n:1\'/ "${rtkbase_path}"/settings.conf  && \
      sudo -u "${RTKBASE_USER}" sed -i s/^receiver=.*/receiver=\'Septentrio_Mosaic-X5\'/ "${rtkbase_path}"/settings.conf            && \
      clear_TADJ
      change_mode_to_NTRIPv1

      #configure the mosaic-X5 for RTKBase
      echo 'Resetting the mosaic-X5 settings....'
      python3 "${rtkbase_path}"/tools/sept_tool.py --port ${RECVPORT} --baudrate ${RECVSPEED} --command reset --retry 5
      sleep_time=30 ; echo 'Waiting '$sleep_time's for mosaic-X5 reboot' ; sleep $sleep_time
      echo 'Sending settings....'
      python3 "${rtkbase_path}"/tools/sept_tool.py --port ${RECVPORT} --baudrate ${RECVSPEED} --command send_config_file "${rtkbase_path}"/receiver_cfg/Septentrio_Mosaic-X5.cfg --store --retry 5
      exitcode=$?
      RESET_INTERNET_LED_FLAG=${rtkbase_path}/../reset_intenet_led.flg
      echo . >${RESET_INTERNET_LED_FLAG}
      if [[ ${exitcode} -eq  0 ]]
      then
        echo 'Septentrio Mosaic-X5 successfuly configured'
        systemctl list-unit-files rtkbase_gnss_web_proxy.service &>/dev/null                                                          && \
        systemctl enable --now rtkbase_gnss_web_proxy.service                                                                         && \
        systemctl enable --now rtkbase_septentrio_NAT.service                                                                         && \
        systemctl start rtkbase_DHCP.service                                                                                          && \
        return $?
      else
        echo 'Failed to configure the Septentrio receiver on '${RECVPORT}
        return 1
      fi
    else
       echo 'No SBF Gnss receiver has been set. We can'\''t configure '${RECVPORT}
       return 1
    fi
}

configure_septentrio_RTCM3() {
    RECVPORT=${1}
    #echo RECVPORT=${RECVPORT}

    RECVTEST=${rtkbase_path}/receiver_cfg/Septentrio_TEST.txt
    TEMPFILE=/run/Septentrio.tmp
    rm -rf ${TEMPFILE}
    #echo ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVTEST} QUIET \>${TEMPFILE} 2\>\&1
    ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVTEST} QUIET >${TEMPFILE} 2>&1
    RECVERROR=`cat ${TEMPFILE} | grep ERROR`
    #echo RECVERROR=${RECVERROR}

    RECVNAME=
    FIRMWARE=
    if [[ ${RECVERROR} == "" ]]; then
       RECVNAME=`cat ${TEMPFILE} | grep "hwplatform product" | awk -F '"' '{print $2}'`
       #echo RECVNAME=${RECVNAME}
       FIRMWARE=`cat ${TEMPFILE} | grep "firmware version" | awk -F '"' '{print $2}'`
       #echo FIRMWARE=${FIRMWARE}
    fi
    if [[ ${RECVNAME} == "" ]] || [[ ${FIRMWARE} == "" ]]; then
       echo Receiver Septentrio not found on ${RECVPORT}
       return 1
    fi

    echo Receiver ${RECVNAME}\(${FIRMWARE}\) found on ${RECVPORT}
    #now that the receiver is configured, we can set the right values inside settings.conf
    sudo -u "${RTKBASE_USER}" sed -i "s/^receiver_firmware=.*/receiver_firmware=\'${FIRMWARE}\'/" "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^com_port_settings=.*/com_port_settings=\'${SPEED}:8:n:1\'/ "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i s/^receiver=.*/receiver=\'Septentrio_${RECVNAME}\'/ "${rtkbase_path}"/settings.conf
    clear_TADJ

    RECVCONF=${rtkbase_path}/receiver_cfg/Septentrio_RTCM3_OUT.txt
    #echo RECVCONF=${RECVCONF}

    if [[ -f "${RECVCONF}" ]]
    then
       #echo ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVCONF} NOMSG
       ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVCONF} NOMSG 2>&1
       exitcode=$?
       RESET_INTERNET_LED_FLAG=${rtkbase_path}/../reset_intenet_led.flg
       echo . >${RESET_INTERNET_LED_FLAG}
       #echo exitcode=${exitcode}
       if [[ ${exitcode} == 0 ]]
       then
          systemctl list-unit-files rtkbase_gnss_web_proxy.service &>/dev/null
          systemctl enable --now rtkbase_gnss_web_proxy.service
          echo Septentrio ${RECVNAME}\(${FIRMWARE}\) successfuly configured
       else
          echo Confiuration FAILED for ${RECVNAME} on ${RECVPORT}
       fi
       RECEIVER_CONF=${rtkbase_path}/receiver.conf
       echo recv_port=${com_port}>${RECEIVER_CONF}
       echo recv_speed=${SPEED}>>${RECEIVER_CONF}
       echo recv_position=>>${RECEIVER_CONF}
       echo recv_ant=${DEFAULT_ANT}>>${RECEIVER_CONF}
       chown ${RTKBASE_USER}:${RTKBASE_USER} ${RECEIVER_CONF}
       return ${exitcode}
    else
       echo Confiuration file for ${RECVNAME} \(${RECVCONF}\) NOT FOUND.
       return 1
    fi
}

configure_ublox(){
    RECVPORT=${1}
    RECVDEV=${2}
    RECVSPEED=${3}
    FORMAT=${4}
    #echo RECVPORT=${RECVPORT} RECVDEV=${RECVDEV} RECVSPEED=${RECVSPEED} ${FORMAT}=${FORMAT}
    RECVINFO=`${rtkbase_path}/${NMEACONF} ${RECVPORT} "UBX-MON-VER" QUIET`
    FIRMWARE=$(echo ${RECVINFO} | awk -F ',' '{print $2}')
    RECVNAME=$(echo ${RECVINFO} | awk -F ',' '{print $1}')
    if [[ ${RECVNAME} == "" ]] || [[ ${FIRMWARE} == "" ]]; then
       echo Receiver ${receiver} not found on ${RECVPORT}
       return 1
    fi
    echo Receiver ${RECVNAME}\(${FIRMWARE}\) found on ${RECVPORT}
    #echo sudo -u "${RTKBASE_USER}" \"sed -i \"s/^receiver_firmware=.*/receiver_firmware=\'${FIRMWARE}\'/\" "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i "s/^receiver_firmware=.*/receiver_firmware=\'${FIRMWARE}\'/" "${rtkbase_path}"/settings.conf
    #echo sudo -u "${RTKBASE_USER}" sed -i \"s/^receiver=.*/receiver=\'u-blox_${RECVNAME}\'/\" "${rtkbase_path}"/settings.conf
    sudo -u "${RTKBASE_USER}" sed -i "s/^receiver=.*/receiver=\'u-blox_${RECVNAME}\'/" "${rtkbase_path}"/settings.conf

    SHORTNAME=$(echo ${RECVNAME} | sed s/^.*-//)
    if [[ ${FORMAT} == "rtcm3" ]]; then
       CONFNAME="${SHORTNAME}_RTCM3_OUT.txt"
       clear_TADJ
    elif [[ ${FORMAT} == "ubx" ]]; then
       CONFNAME="${SHORTNAME}_UBX_OUT.txt"
       add_TADJ
       change_mode_to_NTRIPv1
    fi

    RECVCONF="${rtkbase_path}"/receiver_cfg/${CONFNAME}
    if [[ -z ${CONFNAME} ]] || ! [[ -f "${RECVCONF}" ]]; then
       echo Confiuration file for ${RECVNAME} \(${CONFNAME}\) NOT FOUND.
       return 1
    fi

    ${rtkbase_path}/${NMEACONF} ${RECVPORT} ${RECVCONF} QUIET
    exitcode=$?
    #echo exitcode=${exitcode}
    if [[ ${exitcode} != 0 ]]; then
       echo Ublox confiuration FAILED for ${RECVNAME} on ${RECVPORT}
       return 1
    fi

    sudo -u "${RTKBASE_USER}" sed -i s/^com_port_settings=.*/com_port_settings=\'${SPEED}:8:n:1\'/ "${rtkbase_path}"/settings.conf
    echo Ublox ${RECVNAME}\(${FIRMWARE}\) successfuly configured as ${FORMAT}

    RECEIVER_CONF=${rtkbase_path}/receiver.conf
    echo recv_port=${com_port}>${RECEIVER_CONF}
    echo recv_speed=${SPEED}>>${RECEIVER_CONF}
    echo recv_position=>>${RECEIVER_CONF}
    echo recv_ant=${DEFAULT_ANT}>>${RECEIVER_CONF}
    chown ${RTKBASE_USER}:${RTKBASE_USER} ${RECEIVER_CONF}
    return 0
}

configure_gnss(){
    echo '################################'
    echo 'CONFIGURE GNSS RECEIVER'
    echo '################################'
      if [ -d "${rtkbase_path}" ]
      then
        source <( grep -v '^#' "${rtkbase_path}"/settings.conf | grep '=' )
        stoping_main
        if [[ "${com_port}" == "" ]]; then
           echo 'GNSS receiver is not specified. We can'\''t configure.'
           return 1
        fi

        RECVSPEED=${com_port_settings%%:*}
        if [[ ${receiver} =~ "Septentrio" ]] &&  [[ ${com_port} == "ttyGNSS" ]]; then
           RECVDEV=/dev/ttyGNSS_CTRL
        else
           RECVDEV=/dev/${com_port}
        fi
        RECVPORT=${RECVDEV}:${RECVSPEED}
        #echo RECVPORT=${RECVPORT} RECVDEV=${RECVDEV} RECVSPEED=${RECVSPEED}
        Result=0

        if [[ ${receiver_format} == "sbf" ]]; then
           configure_septentrio_SBF ${RECVPORT} ${RECVSPEED}
           Result=$?
        elif [[ ${receiver_format} == "ubx" ]]; then
           configure_ublox ${RECVPORT} ${RECVDEV} ${RECVSPEED} ${receiver_format}
           Result=$?
        elif [[ ${receiver_format} == "rtcm3" ]]; then
           #echo ${rtkbase_path}/tools/onoffELT0x33.sh ${com_port} ON
           ${rtkbase_path}/tools/onoffELT0x33.sh ${com_port} ON
           if [[ ${receiver} =~ "Unicore" ]]; then
              configure_unicore ${RECVPORT}
              Result=$?
           elif [[ ${receiver} =~ "Bynav" ]]; then
              configure_bynav ${RECVPORT} ${RECVDEV} ${RECVSPEED}
              Result=$?
           elif [[ ${receiver} =~ "Septentrio" ]]; then
              configure_septentrio_RTCM3 ${RECVPORT}
              Result=$?
           elif [[ ${receiver} =~ "u-blox" ]]; then
              configure_ublox ${RECVPORT} ${RECVDEV} ${RECVSPEED} ${receiver_format}
              Result=$?
           else
              echo 'Unknown RTCM3 Gnss receiver' ${receiver} 'has'\''t been set. We can'\''t configure '${RECVPORT}
              Result=1
           fi
           #echo ${rtkbase_path}/tools/onoffELT0x33.sh ${com_port} OFF
           ${rtkbase_path}/tools/onoffELT0x33.sh ${com_port} OFF
        else
           echo 'We can'\''t configure '${receiver_format}' receiver on'${RECVPORT}
           Result=1
        fi
      else #if [ -d "${rtkbase_path}" ]
        echo 'RtkBase not installed!!'
        Result=1
      fi
      return ${Result}
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
