#!/bin/bash
RTKBASE_USER=rtkbase
RTKBASE_PATH=/usr/local/${RTKBASE_USER}

WHOAMI=`whoami`
if [[ ${WHOAMI} != "root" ]]
then
   #echo use sudo
   sudo ${0} ${1}
   #echo exit after sudo
   exit
fi

SYSSERVICE=RtkbaseSystemConfigure.service
SYSSERVICE_enabled=`systemctl is-enabled ${SYSSERVICE} 2>/dev/null`
#echo SYSSERVICE_enabled=${SYSSERVICE_enabled}
[[ "${SYSSERVICE_enabled}" != "" ]] && systemctl is-active --quiet ${SYSSERVICE} && systemctl stop ${SYSSERVICE}
[[ "${SYSSERVICE_enabled}" != "disabled" ]] && [[ "${SYSSERVICE_enabled}" != "masked" ]] && [[ "${SYSSERVICE_enabled}" != "" ]] && systemctl disable  ${SYSSERVICE}
rm -f /etc/systemd/system/${SYSSERVICE}

CHECK_INTERNET_SERVICE=rtkbase_check_internet.service
CHECK_INTERNET_SERVICE_enabled=`systemctl is-enabled ${CHECK_INTERNET_SERVICE} 2>/dev/null`
#echo CHECK_INTERNET_SERVICE_enabled=${CHECK_INTERNET_SERVICE_enabled}
[[ "${CHECK_INTERNET_SERVICE_enabled}" != "" ]] && systemctl is-active --quiet ${CHECK_INTERNET_SERVICE} && systemctl stop ${CHECK_INTERNET_SERVICE}
[[ "${CHECK_INTERNET_SERVICE_enabled}" != "disabled" ]] && [[ "${CHECK_INTERNET_SERVICE_enabled}" != "masked" ]] && [[ "${CHECK_INTERNET_SERVICE_enabled}" != "" ]] && systemctl disable  ${CHECK_INTERNET_SERVICE}
rm -f /etc/systemd/system/${CHECK_INTERNET_SERVICE}

systemctl daemon-reload

RTKBASE_UNINSTALL=${RTKBASE_PATH}/rtkbase/tools/uninstall.sh
#echo RTKBASE_UNINSTAL=${RTKBASE_UNINSTALL}
if [[ -f "${RTKBASE_UNINSTALL}" ]]
then 
   ${RTKBASE_UNINSTALL}
fi

HAVEUSER=`cat /etc/passwd | grep ${RTKBASE_USER}`
#echo  HAVEUSER=${HAVEUSER}
if [[ ${HAVEUSER} != "" ]]
then 
  deluser ${RTKBASE_USER}
fi

rm -f /usr/lib/NetworkManager/dispatcher.d/rtkbase_network_event.sh
rm -rf ${RTKBASE_PATH}
rm -f /etc/sudoers.d/${RTKBASE_USER}

