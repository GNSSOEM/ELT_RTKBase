#!/bin/bash
#LOG=/usr/local/rtkbase/elt0x33.log
#DATE=$(date "+%D %T.%N")
#echo ${DATE} $1 $2 $3 $4 $5 $6 $7 $8 $9  >>${LOG}
FLAG_INIT=/usr/local/rtkbase/ledInited.flg
FLAG_TMP=${FLAG_INIT}.tmp
rm -f ${FLAG_INIT}

if [[ "$1" == "Septentrio04" ]]; then
   if [[ -c /dev/ttyGNSS_CTRL ]]; then
      #echo have /dev/ttyGNSS >>${LOG}
      MOSAIC=$(readlink -f /dev/ttyGNSS_CTRL)
   else
      #echo No /dev/ttyGNSS >>${LOG}
      MOSAIC=/dev/ttyACM1
   fi
   BASEDIR="$(dirname "$0")"
   NMEACONF=${BASEDIR}/rtkbase/NmeaConf
   stty -F ${MOSAIC} 115200
   for i in `seq 1 5`; do
       #echo RESULT=\`${NMEACONF} ${MOSAIC} \"setGPIOFunctionality,all,Output,none,LevelLow\" QLONG\`  >>${LOG}
       RESULT=`${NMEACONF} ${MOSAIC} "setGPIOFunctionality,all,Output,none,LevelLow" QLONG`
       if [[ "$?" != "0" ]]; then
          #echo ERROR $i:${RESULT}  >>${LOG}
          echo ERROR $i:${RESULT}
       else
          #echo OK $i:${RESULT} >>${LOG}
          break
       fi
   done
   for i in `seq 1 5`; do
       #echo RESULT=\`${NMEACONF} ${MOSAIC} \"setDataInOut,USB1,CMD,RTCMv3+SBF+NMEA\" QLONG\`  >>${LOG}
       RESULT=`${NMEACONF} ${MOSAIC} "setDataInOut,USB1,CMD,RTCMv3+SBF+NMEA" QLONG`
       if [[ "$?" != "0" ]]; then
          #echo ERROR $i:${RESULT}  >>${LOG}
          echo ERROR $i:${RESULT}
       else
          #echo OK $i:${RESULT} >>${LOG}
          break
       fi
   done
elif [[ "$1" == "ELT0x33" ]] && [[ "$2" =~ "gpiochip" ]]; then
   #echo CHIP=$2 >>${LOG}
   for i in `seq 0 2`; do
       #echo gpioset $2 $i=0 >>${LOG}
       gpioset $2 $i=0
       lastcode=$?
       if [[ "${lastcode}" != "0" ]]; then
          #echo BUG=${lastcode} in gpioset $2 $i=0 >>${LOG}
          echo BUG=${lastcode} in gpioset $2 $i=0
       fi
   done
fi
#echo finished >>${LOG}
echo >${FLAG_TMP}
chmod 666 ${FLAG_TMP}
mv ${FLAG_TMP} ${FLAG_INIT}
