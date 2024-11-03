#!/bin/bash

WHOAMI=`whoami`
if [[ ${WHOAMI} != "root" ]]
then
   #echo sudo ${0} ${1}
   sudo ${0} ${1}
   #echo exit after sudo
   exit
fi

if [[ "${RTKBASE_USER}" = "" ]]
then
   RTKBASE_USER=rtkbase
fi

rtkbase_path=$(pwd)/rtkbase
settings="${rtkbase_path}"/settings.conf
#echo settings=${settings}
rtcm_msg="1005(10),1033(10),1077,1087,1097,1107,1117,1127,1137,1230"
rtcm_msg_onocoy="1005(30),1033(30),1077,1087,1097,1107,1117,1127,1137,1230"
rtcm_msg_full="1005,1006,1007,1013,1033,1019,1020,1042,1044,1045,1046,1048,1077,1087,1097,1107,1117,1127,1137,1230"
sed="sudo -u "${RTKBASE_USER}" sed -i"
#echo sed=${sed}

OLD_VERSION=${1}
if [[ ${OLD_VERSION} != "" ]]; then
   if [[ ${OLD_VERSION} < 172 ]]; then
      source <( grep -v '^#' "${settings}" | grep 'rtcm_msg_a=' )
      #echo rtcm_msg_a=${rtcm_msg_a}
      if [[ "${rtcm_msg_a}" == "${rtcm_msg}" ]]; then
         echo correct \"rtcm_msg_a\" field for version below 172
         ${sed} s/^rtcm_msg_a=.*/rtcm_msg_a=\'${rtcm_msg_onocoy}\'/ "${settings}"
      fi
   fi
   exit
fi

if ! ischroot; then
   #store service status before upgrade
   rtkbase_web_active=$(systemctl is-active rtkbase_web.service)
   str2str_active=$(systemctl is-active str2str_tcp)
   #echo rtkbase_web_active=${rtkbase_web_active} str2str_active=${str2str_active}

   # stop previously running services
   if [ "${str2str_active}" = "active" ] || [ "${str2str_active}" = "activating" ]
   then
      #echo systemctl stop str2str_tcp \&\& sleep 2
      systemctl stop str2str_tcp && sleep 2
   fi
   #[ "${rtkbase_web_active}" = "active" ] && echo systemctl stop rtkbase_web.service
   [ "${rtkbase_web_active}" = "active" ] && systemctl stop rtkbase_web.service
fi

${sed} s/^position=.*/position=\'0\.00\ 0\.00\ 0\.00\'/ "${settings}"
${sed} s/^com_port=.*/com_port=\'\'/ "${settings}"
${sed} s/^com_port_settings=.*/com_port_settings=\'115200:8:n:1\'/ "${settings}"
${sed} s/^receiver=.*/receiver=\'\'/ "${settings}"
${sed} s/^receiver_format=.*/receiver_format=\'rtcm3\'/ "${settings}"
${sed} s/^antenna_info=.*/antenna_info=\'ELT0123\'/ "${settings}"

${sed} s/^svr_addr_a=.*/svr_addr_a=\'servers.onocoy.com\'/ "${settings}"
${sed} s/^svr_addr_b=.*/svr_addr_b=\'ntrip.rtkdirect.com\'/ "${settings}"
#${sed} s/^svr_port_b=.*/svr_port_b=\'\'/ "${settings}"
#${sed} s/^svr_pwd_b=.*/svr_pwd_b=\'TCP\'/ "${settings}"
#${sed} s/^mnt_name_b=.*/mnt_name_b=\'TCP\'/ "${settings}"

${sed} s/^rtcm_msg_a=.*/rtcm_msg_a=\'${rtcm_msg_onocoy}\'/ "${settings}"
${sed} s/^rtcm_msg_b=.*/rtcm_msg_b=\'${rtcm_msg}\'/ "${settings}"
${sed} s/^local_ntripc_msg=.*/local_ntripc_msg=\'${rtcm_msg}\'/ "${settings}"
${sed} s/^rtcm_svr_msg=.*/rtcm_svr_msg=\'${rtcm_msg_full}\'/ "${settings}"
${sed} s/^rtcm_serial_msg=.*/rtcm_serial_msg=\'${rtcm_msg_full}\'/ "${settings}"

${sed} s/^archive_rotate=.*/archive_rotate=\'20\'/ "${settings}"

if ! ischroot
then
   # start previously running services
   #[ "${rtkbase_web_active}" = "active" ] && echo systemctl start rtkbase_web.service
   [ "${rtkbase_web_active}" = "active" ] && systemctl start rtkbase_web.service
   if [ "${str2str_active}" = "active" ] || [ "${str2str_active}" = "activating" ]
   then
      #echo systemctl start str2str_tcp.service
      systemctl start str2str_tcp.service
   fi
fi
exit 0
