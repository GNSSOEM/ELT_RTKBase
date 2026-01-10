#!/bin/bash
  if [[ -z ${rtkbase_path} ]]
  then
    if grep -q '^rtkbase_path=' /etc/environment
    then
      source /etc/environment
    else
      export rtkbase_path='rtkbase'
    fi
  fi

update_path=${rtkbase_path}/../update
data_path=${rtkbase_path}/data

if [[ ! -d ${data_path} ]]; then
  #echo sudo sudo -u rtkbase mkdir ${data_path}
  sudo sudo -u rtkbase mkdir ${data_path}
fi

cd ${update_path}
date=`date +%Y-%m-%d_%H-%M-%S`
update_log_name="${date}_update.log"
update_log="${data_path}/${update_log_name}"

#WHOAMI=`whoami`
#echo ${WHOAMI} >${update_log}

sudo ${update_path}/update.sh -U &>${update_log}
lastcode=$?
#lastcode=0

if [[ ${lastcode} == 0 ]]; then
   if grep -q "Please REBOOT" ${update_log}; then
      result=reboot
   else
      result=true
   fi
else
   result="${update_log_name}"
fi

SETTINGS=${rtkbase_path}/settings.conf
HAVE_UPDATE=`grep "updated=" ${SETTINGS}`
#echo HAVE_UPDATE=${HAVE_UPDATE}
if [[ "${HAVE_UPDATE}" == "" ]]; then
   #echo sudo sudo -u rtkbase sed -i "/^\[general\]/a updated=${result}" ${rtkbase_path}/settings.conf
   sudo sudo -u rtkbase sed -i "/^\[general\]/a updated=${result}" ${SETTINGS}
else
   #echo sudo sudo -u rtkbase sed -i "s/^updated=.*/updated=${result}/" ${SETTINGS}
   sudo sudo -u rtkbase sed -i "s/^updated=.*/updated=${result}/" ${SETTINGS}
fi

#echo sudo systemctl restart rtkbase_web.service
sudo systemctl restart rtkbase_web.service
