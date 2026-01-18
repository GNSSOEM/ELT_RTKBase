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

data_path=${rtkbase_path}/data

if [[ ! -d ${data_path} ]]; then
  #echo sudo sudo -u rtkbase mkdir ${data_path}
  sudo sudo -u rtkbase mkdir ${data_path}
fi

date=`date +%Y-%m-%d_%H-%M-%S`
update_log_name="${date}_linux_upgrade.log"
update_log="${data_path}/${update_log_name}"

sudo apt -q -y update >>${update_log} 2>&1 && sudo apt -q -y upgrade >>${update_log} 2>&1 && sudo apt -q -y autoremove --purge >>${update_log} 2>&1 && sudo apt -q -u clean >>${update_log} 2>&1 && sync >>${update_log} 2>&1
