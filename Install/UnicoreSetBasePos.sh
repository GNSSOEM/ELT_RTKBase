#!/bin/bash
#

BASEDIR=`realpath $(dirname "$0")`
OLDCONF=${BASEDIR}/receiver.conf
BADPOSFILE=${BASEDIR}/main.flg
#DEBUGLOG="${BASEDIR}/debug.log"
ZEROPOS="0.00 0.00 0.00"
com_port="${1}"
com_speed="${2}"
position="${3}"
receiver="${4}"
antenna_info="${5}"
#echo com_port="${com_port}" com_speed=${com_speed} position="${position}" receiver=${receiver} antenna_info="${antenna_info}"

if [[ "${com_port}" == "" ]]; then
   echo com port is EMPTY!
   exit 1
fi

if [[ "${receiver}" == "" ]]; then
   echo Receiver type is EMPTY!
   exit 1
fi

if [[ "${receiver}" == "unknown" ]]; then
   echo Receiver type is UNKNOWN!
   exit 1
fi

if [[ ! "${receiver}" =~ Unicore ]] && [[ ! "${receiver}" =~ Bynav ]] && [[ ! "${receiver}" =~ Septentrio ]] && [[ ! "${receiver}" =~ u-blox ]]; then
   exit 0
fi

if [[ ${com_speed} -lt 115200 ]]; then
   if [[ ! "${receiver}" =~ u-blox ]] || [[ ${com_speed} != 38400 ]] ; then
      echo com_speed \(${com_speed}\) is low 115200
      exit 3
   fi
fi

if [[ ${receiver} =~ "Septentrio" ]] &&  [[ ${com_port} == "ttyGNSS" ]]; then
   HAVE_ZERO=`cat /proc/cpuinfo | grep Model | grep "Pi Zero 2 W"`
   FLAG_INITED=/usr/local/rtkbase/MosaicInited.flg
   if [[ "${HAVE_ZERO}" != "" ]]; then
      com_port=ttyGNSS_CTRL
      if [[ ${recv_port} == "ttyGNSS" ]]; then
         recv_port=ttyGNSS_CTRL
      fi
      echo com_port=${com_port} recv_port=${recv_port}
      for i in `seq 0 25`; do
          if [[ -f ${FLAG_INITED} ]]; then
             echo Inited after $i seconds
             break
          fi
          sleep 1
      done
   fi
fi

lastcode=N
exitcode=0

function ciao {
   if [[ ${exitcode} != 0 ]]; then
      #echo "${BASEDIR}"/tools/reset_receiver.sh
      "${BASEDIR}"/tools/reset_receiver.sh
   fi
   #echo "${BASEDIR}"/tools/onoffELT0x33.sh ${com_port} OFF
   "${BASEDIR}"/tools/onoffELT0x33.sh ${com_port} OFF
}

trap ciao EXIT


ExitCodeCheck(){
  lastcode=$1
  #echo lastcode=${lastcode}
  if [[ $lastcode > $exitcode ]]; then
     exitcode=${lastcode}
     #echo exitcode=${exitcode}
  fi
}

for i in `seq 1 5`; do
   if [[ -c /dev/${com_port} ]]; then
      break
   else
      #echo $i:/dev/${com_port} NOT EXISTS!
      WasNotExists=YES
      sleep 1
   fi
done

if [[ ! -c /dev/${com_port} ]]; then
   echo /dev/${com_port} NOT EXISTS!
   ExitCodeCheck 1
   exit 1
#elif [[ -n ${WasNotExists} ]]; then
fi

SAVECONF=N
if [[ -f ${OLDCONF} ]]
then
   #echo source ${OLDCONF}
   source ${OLDCONF}
else
   recv_port=${com_port}
   recv_speed=${com_speed}
   recv_position=
   recv_ant=
   recv_com=
   SAVECONF=Y
fi
#echo recv_port=${recv_port} recv_speed=${recv_speed} recv_position=${recv_position} recv_ant=${recv_ant} recv_com=${recv_com}

#echo ${BASEDIR}/tools/onoffELT0x33.sh ${com_port} ON
${BASEDIR}/tools/onoffELT0x33.sh ${com_port} ON

SETSPEED=Y
SETPOS=Y
SETANT=Y
TIMEPOS=N
BADPOS=
if [[ "${com_port}" == "${recv_port}" ]]
then
   if [[ "${com_speed}" == "${recv_speed}" ]]
   then
      SETSPEED=N
   fi
   if [[ "${position}" == "${recv_position}" ]]
   then
      SETPOS=N
   else
      if [[ "${position}" == "${ZEROPOS}" ]]
      then
         TIMEPOS=Y
         SETPOS=N
         BADPOS=N
      fi
   fi
   if [[ "${antenna_info}" == "${recv_ant}" ]]
   then
      SETANT=N
   fi
else
   recv_port=${com_port}
   recv_com=
   SETSPEED=N
   SAVECONF=Y
   if [[ "${position}" == "${ZEROPOS}" ]]; then
      TIMEPOS=Y
      SETPOS=N
      BADPOS=N
   fi
fi

OLDDEV=/dev/${com_port}:${recv_speed}
DEVICE=/dev/${com_port}:${com_speed}
#echo SETSPEED=${SETSPEED} SETPOS=${SETPOS} SETANT=${SETANT} TIMEPOS=${TIMEPOS} BADPOS=${BADPOS} OLDDEV=${OLDDEV} DEVICE=${DEVICE}

if [[ ${SETSPEED} == Y ]] && [[ "${recv_com}" == "" ]]
then
   if [[ "${receiver}" =~ Unicore ]]
   then
      recv_com=`${BASEDIR}/NmeaConf ${OLDDEV} RESET COM | grep COM`
      if [[ "${recv_com}" == "" ]]
      then
          recv_com=`${BASEDIR}/NmeaConf ${DEVICE} RESET COM | grep COM`
          if [[ "${recv_com}" != "" ]]
          then
             echo Receiver already on ${com_speed}
             #echo ${BASEDIR}/NmeaConf ${DEVICE} saveconfig QUIET
             ${BASEDIR}/NmeaConf ${DEVICE} saveconfig QUIET
             ExitCodeCheck $?
             recv_speed=${com_speed}
             SAVECONF=Y
             SETSPEED=N
          fi
      fi
   elif [[ "${receiver}" =~ Bynav ]]
   then
      recv_com=`${BASEDIR}/NmeaConf ${OLDDEV} TEST COM | grep COM`
      if [[ "${recv_com}" == "" ]]
      then
          recv_com=`${BASEDIR}/NmeaConf ${DEVICE} TEST COM | grep COM`
          if [[ "${recv_com}" != "" ]]
          then
             echo Receiver already on ${com_speed}
             #echo ${BASEDIR}/NmeaConf ${DEVICE} saveconfig QUIET
             ${BASEDIR}/NmeaConf ${DEVICE} saveconfig QUIET
             ExitCodeCheck $?
             recv_speed=${com_speed}
             SAVECONF=Y
             SETSPEED=N
          fi
      fi
   elif [[ "${receiver}" =~ Septentrio ]]; then
      SAVECONF=Y
      SETSPEED=N
   elif [[ "${receiver}" =~ u-blox ]]; then
      recv_com=NO
   fi
   if [[ "${recv_com}" != "" ]]; then
      SAVECONF=Y
   fi
fi

if [[ ${SETSPEED} == Y ]]
then
   #echo recv_com=${recv_com}
   if [[ "${recv_com}" == "" ]]
   then
      echo Unknown receiver port for change speed
      ExitCodeCheck 1
      exit 1
   fi
fi

if [[ ${SETSPEED} == Y ]]
then
   for i in `seq 1 5`
   do
      if [[ "${receiver}" =~ Unicore ]]
      then
         #echo ${BASEDIR}/NmeaConf ${OLDDEV} \"CONFIG ${recv_com} ${com_speed}\" QUIET
         ${BASEDIR}/NmeaConf ${OLDDEV} "CONFIG ${recv_com} ${com_speed}" QUIET
         lastcode=$?
      elif [[ "${receiver}" =~ Bynav ]]
      then
         #echo ${BASEDIR}/NmeaConf ${OLDDEV} \"SERIALCONFIG ${recv_com} ${com_speed}\" QUIET
         ${BASEDIR}/NmeaConf ${OLDDEV} "SERIALCONFIG ${recv_com} ${com_speed}" QUIET
         lastcode=$?
      elif [[ "${receiver}" =~ u-blox ]]; then
         #echo ${BASEDIR}/NmeaConf ${OLDDEV} "CFG-UART1-BAUDRATE,${com_speed}" QUIET
         ${BASEDIR}/NmeaConf ${OLDDEV} "CFG-UART1-BAUDRATE,${com_speed}" QUIET
         lastcode=$?
      fi
      #echo lastcode=${lastcode}
      if [[ ${lastcode} == 0 ]] || [[ ${lastcode} == 3 ]]; then
          if [[ "${receiver}" =~ u-blox ]]; then
             #echo ${BASEDIR}/NmeaConf ${DEVICE} UBX-MON-VER QUIET
             ${BASEDIR}/NmeaConf ${DEVICE} UBX-MON-VER QUIET
             lastcode=$?
          else
             #echo ${BASEDIR}/NmeaConf ${DEVICE} saveconfig QUIET
             ${BASEDIR}/NmeaConf ${DEVICE} saveconfig QUIET
             lastcode=$?
          fi
          #echo lastcode=${lastcode}
          if [[ ${lastcode} == 0 ]]
          then
             echo Speed changed on $i iteration from ${recv_speed} to ${com_speed}
             SPEEDCHANGED=Y
             recv_speed=${com_speed}
             SAVECONF=Y
             break
          fi
      else
         ExitCodeCheck ${lastcode}
         echo speed changed from ${recv_speed} to ${com_speed} incorrectly, not saved
         exit_code=1
         break
      fi
   done

   if [[ ${SPEEDCHANGED} != "Y" ]]
   then
      echo receiver not answer after changing speed from ${recv_speed} to ${com_speed}
      exit_code=2
   fi

   if [[ "${exit_code}" != "" ]]; then
      ExitCodeCheck ${exit_code}
      exit ${exit_code}
   fi
fi

CHECKPOS=N
SAVEPOS=N
if [[ ${SETPOS} == Y ]]
then
   if [[ "${receiver}" =~ Unicore ]]
   then
      NO_ANSWER_COUNT=0;
      for i in `seq 1 30`
      do
         #echo UNICORE_MODE=\`${BASEDIR}/NmeaConf ${DEVICE} MODE\`
         UNICORE_MODE=`${BASEDIR}/NmeaConf ${DEVICE} MODE`
         IS_FINE=`echo ${UNICORE_MODE} | grep -c "1005"`
         NO_ANSWER=`echo ${UNICORE_MODE} | grep -c "maxRead=0 "`
         #echo UNICORE_MODE=${UNICORE_MODE}
         #echo IS_FINE=${IS_FINE} NO_ANSWER=${NO_ANSWER} NO_ANSWER_COUNT=${NO_ANSWER_COUNT}
         if [[ ${IS_FINE} != "0" ]]; then
            echo 1005 found on $i iteration
            break
         fi
         if [[ ${NO_ANSWER} != "0" ]]; then
            let NO_ANSWER_COUNT++
            #echo NO_ANSWER_COUNT=${NO_ANSWER_COUNT}
            if [ ${NO_ANSWER_COUNT} -ge 5 ]; then
               echo receiver not answer ${NO_ANSWER_COUNT} times
               ExitCodeCheck 1
               exit 1
            fi
         fi
         sleep 1
      done
      #echo ${BASEDIR}/NmeaConf ${DEVICE} \"MODE BASE 1 ${position}\" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "MODE BASE 1 ${position}" QUIET
      lastcode=$?
      if [[ $lastcode == 0 ]]; then
         CHECKPOS=Y
         SAVEPOS=Y
      else
         BADPOS=Y
         TIMEPOS=Y
      fi
   elif [[ "${receiver}" =~ Bynav ]]
   then
      #echo ${BASEDIR}/NmeaConf ${DEVICE} \"FIX POSITION ${position}\" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "FIX POSITION ${position}" QUIET
      lastcode=$?
      if [[ $lastcode == 0 ]]
      then
         recv_position="${position}"
         #echo recv_position=${recv_position}
         SAVECONF=Y
         SAVEPOS=Y
         BADPOS=N
      else
         BADPOS=Y
         TIMEPOS=Y
      fi
   elif [[ "${receiver}" =~ Septentrio ]]
   then
      commapos=`echo ${position} | sed "s/ \{2,99\}/ /g" | sed "s/^ //" | sed "s/ $//" | sed "s/ /,/g"`
      #echo commapos=${commapos}
      #echo ${BASEDIR}/NmeaConf ${DEVICE} \"setPVTMode, , , Geodetic1, ${commapos}\" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "setStaticPosGeodetic , Geodetic1, ${commapos}" QUIET
      lastcode=$?
      if [[ $lastcode == 0 ]]
      then
         #echo ${BASEDIR}/NmeaConf ${DEVICE} \"setPVTMode, , , Geodetic1\" QUIET
         ${BASEDIR}/NmeaConf ${DEVICE} "setPVTMode, , , Geodetic1" QUIET
         ExitCodeCheck $?
         if [[ $lastcode == 0 ]]
         then
            recv_position="${position}"
            #echo recv_position=${recv_position}
            SAVECONF=Y
            SAVEPOS=Y
            BADPOS=N
         fi
      fi
      if [[ ${SAVEPOS} != Y ]]
      then
         BADPOS=Y
         TIMEPOS=Y
      fi
   elif [[ "${receiver}" =~ u-blox ]]; then
      #echo ${BASEDIR}/NmeaConf ${DEVICE} "UBX-FIXMODE,${position}" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "UBX-FIXMODE,${position}" QUIET
      lastcode=$?
      if [[ $lastcode == 0 ]]; then
         BADPOS=N
         SAVECONF=Y
         recv_position="${position}"
      else
         BADPOS=Y
         TIMEPOS=Y
      fi
   fi
fi

#echo CHECKPOS=${CHECKPOS} SAVEPOS=${SAVEPOS} SAVECONF=${SAVECONF} BADPOS=${BADPOS}
if [[ ${CHECKPOS} == Y ]]
then
   #echo UNICORE_ANSWER=\`${BASEDIR}/NmeaConf ${DEVICE} CONFIG\`
   UNICORE_ANSWER=`${BASEDIR}/NmeaConf ${DEVICE} CONFIG`
   ExitCodeCheck $?
   #echo UNICORE_ANSWER=${UNICORE_ANSWER}
   POSITION_INCORRECT=`echo ${UNICORE_ANSWER} | grep -c "not correct"`
   HAVE_RTCM3=`echo ${UNICORE_ANSWER} | grep -c "RTCM3:"`
   #echo POSITION_INCORRECT=${POSITION_INCORRECT} HAVE_RTCM3=${HAVE_RTCM3}
   if [[ ${POSITION_INCORRECT} == "0" ]] && [[ ${HAVE_RTCM3} != "0" ]]; then
      recv_position="${position}"
      #echo recv_position=${recv_position}
      BADPOS=N
   else
      BADPOS=Y
      TIMEPOS=Y
   fi
   SAVECONF=Y
fi

if [[ "${BADPOS}" == "" ]]
then
   if [[ -f ${BADPOSFILE} ]]
   then
      BADNOW=Y
      BADPOS=N
   else
      BADNOW=N
   fi
fi

if [[ "${BADPOS}" != "" ]]
then
   #echo BADPOS=${BADPOS} BADNOW=${BADNOW} BADPOSFILE=${BADPOSFILE}
   if [[ ${BADPOS} != ${BADNOW} ]]
   then
      if [[ ${BADPOS} == Y ]]
      then
         #echo \"Bad coordinates\" \>${BADPOSFILE}
         echo "Bad coordinates" >${BADPOSFILE}
      else
         #echo rm -f ${BADPOSFILE}
         rm -f ${BADPOSFILE}
      fi
   fi
   #echo ls -la ${BADPOSFILE}
   #ls -la ${BADPOSFILE}
fi

#echo TIMEPOS=${TIMEPOS}
if [[ ${TIMEPOS} == Y ]]
then
   if [[ "${receiver}" =~ Unicore ]]
   then
      #echo ${BASEDIR}/NmeaConf ${DEVICE} \"MODE BASE 1 TIME 60 1\" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "MODE BASE 1 TIME 60 1" QUIET
      ExitCodeCheck $?
   elif [[ "${receiver}" =~ Bynav ]]
   then
      #echo ${BASEDIR}/NmeaConf ${DEVICE} \"FIX NONE\" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "FIX NONE" QUIET
      ExitCodeCheck $?
   elif [[ "${receiver}" =~ Septentrio ]]
   then
      #echo ${BASEDIR}/NmeaConf ${DEVICE} \"setPVTMode, , , auto\" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "setPVTMode, , , auto" QUIET
      ExitCodeCheck $?
   elif [[ "${receiver}" =~ u-blox ]]; then
      #echo ${BASEDIR}/NmeaConf ${DEVICE} "UBX-SURVEY,60 15000" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "UBX-SURVEY,60 15000" QUIET
      ExitCodeCheck $?
   fi
   recv_position="${ZEROPOS}"
   #echo recv_position=${recv_position}
   SAVEPOS=Y
   SAVECONF=Y
fi

if [[ ${SETANT} == Y ]]; then
   if [[ "${antenna_info}" == "ELT0123" ]] || [[ "${antenna_info}" == "ELT0323" ]]; then
      if [[ "${receiver}" =~ Unicore ]]; then
         ANTINFO="HXCSX627A"
      else
         ANTINFO="HXCSX627A       NONE"
      fi
   else
      ANTINFO="${antenna_info}"
   fi
   ANTNAME=`echo "${ANTINFO}" | awk -F ',' '{print $1}'`
   ANTSERIAL=`echo "${ANTINFO}" | awk -F ',' '{print $2}'`
   ANTSETUP=`echo "${ANTINFO}" | awk -F ',' '{print $3}'`
   if [[ "${ANTSETUP}" == "" ]]; then
      ANTSETUP=0
   fi
   #echo ANTNAME=${ANTNAME} ANTSERIAL=${ANTSERIAL} ANTSETUP=${ANTSETUP} ANTINFO=${ANTINFO}
   if [[ "${receiver}" =~ Unicore ]]; then
      if [[ "${ANTSERIAL}" == "" ]]; then
         ANTSERIAL=0
      fi
      #ANTINFO="\"${ANTNAME}\" \"${ANTSERIAL}\" ${ANTSETUP}"
      ANTINFO="${ANTNAME} ${ANTSERIAL} ${ANTSETUP}"
      #echo ANTINFO=${ANTINFO}
      #echo ${BASEDIR}/NmeaConf ${DEVICE} \"CONFIG BASEANTENNAMODEL ${ANTINFO} USER\" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "CONFIG BASEANTENNAMODEL ${ANTINFO} USER" QUIET
      ExitCodeCheck $?
   elif [[ "${receiver}" =~ Septentrio_mosaic-H ]]; then
      ANTINFO="\"${ANTNAME}\", \"${ANTSERIAL}\""
      #echo ANTINFO=${ANTINFO}
      #echo ${BASEDIR}/NmeaConf ${DEVICE} \"setAntennaOffset, Main, , , , ${ANTINFO}\" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "setAntennaOffset, Main, , , , ${ANTINFO}" QUIET
      ExitCodeCheck $?
   elif [[ "${receiver}" =~ Septentrio ]]; then
      ANTINFO="\"${ANTNAME}\", \"${ANTSERIAL}\", ${ANTSETUP}"
      #echo ANTINFO=${ANTINFO}
      #echo ${BASEDIR}/NmeaConf ${DEVICE} \"setAntennaOffset, Main, , , , ${ANTINFO}\" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "setAntennaOffset, Main, , , , ${ANTINFO}" QUIET
      ExitCodeCheck $?
   else
      lastcode=0
   fi
   if [[ $lastcode == 0 ]]; then
      if [[ "${ANTINFO}" != "" ]]; then
         SAVEPOS=Y
      fi
      recv_ant="${antenna_info}"
      SAVECONF=Y
   fi
fi

if [[ ${SAVEPOS} == Y ]]
then
   if [[ "${receiver}" =~ Septentrio ]]
   then
      #echo ${BASEDIR}/NmeaConf ${DEVICE} \"exeCopyConfigFile, Current, Boot\" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "exeCopyConfigFile, Current, Boot" QUIET
      ExitCodeCheck $?
   elif [[ ! "${receiver}" =~ u-blox ]]; then
      #echo ${BASEDIR}/NmeaConf ${DEVICE} saveconfig QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} saveconfig QUIET
      ExitCodeCheck $?
      if [[ "${receiver}" =~ Bynav ]]
      then
         #echo ${BASEDIR}/NmeaConf ${DEVICE} REBOOT QUIET
         ${BASEDIR}/NmeaConf ${DEVICE} REBOOT QUIET
         ExitCodeCheck $?
      fi
   fi
fi

#echo SAVECONF=${SAVECONF}
if [[ ${SAVECONF} == Y ]]
then
   #echo SAVE OLDCONF=${OLDCONF} recv_port=${recv_port} recv_speed=${recv_speed} recv_position=${recv_position} recv_ant=${recv_ant} recv_com=${recv_com}
   echo recv_port=${recv_port}>${OLDCONF}
   echo recv_speed=${recv_speed}>>${OLDCONF}
   echo recv_position=\"${recv_position}\">>${OLDCONF}
   echo recv_ant=\"${recv_ant}\">>${OLDCONF}
   echo recv_com=${recv_com}>>${OLDCONF}
fi

#echo lastcode=${lastcode}
if [[ ${lastcode} == N ]]; then
   if [[ "${receiver}" =~ Unicore ]]
   then
      #echo ${BASEDIR}/NmeaConf ${DEVICE} MODE QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} MODE QUIET
      ExitCodeCheck $?
   elif [[ "${receiver}" =~ Bynav ]]; then
      #echo ${BASEDIR}/NmeaConf ${DEVICE} \"LOG REFSTATION\" QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} "LOG REFSTATION" QUIET
      ExitCodeCheck $?
   elif [[ "${receiver}" =~ Septentrio ]]; then
      for i in `seq 1 5`; do
         #echo ${BASEDIR}/NmeaConf ${DEVICE} getPVTMode QUIET
         ${BASEDIR}/NmeaConf ${DEVICE} getPVTMode QUIET
         lastcode=$?
         if [[ "${lastcode}" != "4" ]] || [[ -z ${WasNotExists} ]]; then
            break
         fi
         #sudo lsof /dev/${com_port}
      done
      ExitCodeCheck ${lastcode}
   elif [[ "${receiver}" =~ u-blox ]]; then
      #echo ${BASEDIR}/NmeaConf ${DEVICE} UBX-MON-VER QUIET
      ${BASEDIR}/NmeaConf ${DEVICE} UBX-MON-VER QUIET
      ExitCodeCheck $?
   fi
fi

#echo exit $0 with code ${exitcode} "("lastcode=${lastcode}")"
exit ${exitcode}
