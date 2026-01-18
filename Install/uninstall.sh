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

serviceList="RtkbaseSystemConfigure.service \
             rtkbase_system_configure.service \
             rtkbase_check_internet.service \
             rtkbase_check_satelites.service \
             rtkbase_septentrio_NAT.service \
             rtkbase_DHCP.service \
             rtkbase_modem_web_proxy.service"

for service_name in ${serviceList}; do
    enabled=`systemctl is-enabled ${service_name} 2>/dev/null`
    #[[ "${enabled}" != "" ]] && echo ${service_name} ${enabled}
    [[ "${enabled}" != "" ]] && systemctl is-active --quiet ${service_name} && systemctl stop ${service_name}
    [[ "${enabled}" != "disabled" ]] && [[ "${enabled}" != "masked" ]] && [[ "${enabled}" != "" ]] && systemctl disable ${service_name}
    rm -f /etc/systemd/system/${service_name}
done

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

rm -f /usr/lib/systemd/network/70-usb-net-septentrio.link
rm -f /lib/udev/rules.d/77-mm-septentio-port-types.rules
rm -f /usr/lib/NetworkManager/dispatcher.d/rtkbase_network_event.sh
rm -rf ${RTKBASE_PATH}
rm -f /etc/sudoers.d/${RTKBASE_USER}

