#!/bin/sh

echo "Installing RTKBase..."

mkdir -p /usr/local/rtkbase/

cp /tmp/install.sh /usr/local/rtkbase/
chown root:root /usr/local/rtkbase/install.sh
chmod 755 /usr/local/rtkbase/install.sh

cat <<"EOF" > /etc/systemd/system/rtkbase_setup.service
[Unit]
Description=RTKBase setup second stage
After=local-fs.target
After=network.target

[Service]
ExecStart=/usr/local/rtkbase/setup_2nd_stage.sh
RemainAfterExit=true
Type=oneshot

[Install]
WantedBy=multi-user.target
EOF

cat <<"EOF" > /usr/local/rtkbase/setup_2nd_stage.sh
#!/bin/sh

HOME=/usr/local/rtkbase
DATA=${HOME}/rtkbase/data
LOG=${DATA}/install.log
NEW_INSTALL=/boot/firmware/install.sh
UPDATE_INSTALL=${HOME}/update/install.sh
MAIN_INSTALL=${HOME}/install.sh
export HOME

if test ! -f ${DATA}
then
  sudo -u rtkbase mkdir -p ${DATA}
fi

if test -f ${NEW_INSTALL}
then
  mv ${NEW_INSTALL} ${UPDATE_INSTALL} 2>&1 | tee -a ${LOG} >/dev/null
  DOLOG=Y
fi

if test -f ${UPDATE_INSTALL}
then
  chmod +x ${UPDATE_INSTALL} 2>&1 | tee -a ${LOG} >/dev/null
  DOLOG=Y
fi

if test -x ${UPDATE_INSTALL}
then

  nm-online -s 2>&1 | tee -a ${LOG} >/dev/null
  nm-online 2>&1 | tee -a ${LOG} >/dev/null
  for i in `seq 1 10`
  do
     if sudo ntpdate -b -t 5 pool.ntp.org 2>&1 | tee -a ${LOG} >/dev/null
     then
        break
     fi
     sleep 3
  done

  if test -x ${MAIN_INSTALL}
  then
     ${UPDATE_INSTALL} -1 2>&1 | tee -a ${LOG} >/dev/null
     status=$?
     echo status of \"${UPDATE_INSTALL} -1\" is ${status} >>${LOG}
     if test "${status}" = "0"
     then
        mv ${UPDATE_INSTALL} ${MAIN_INSTALL} 2>&1 | tee -a ${LOG} >/dev/null
     else
        NOSECOND=Y
     fi
  else
     ${UPDATE_INSTALL} -u >>${LOG} 2>&1
     status=$?
     echo status of \"${UPDATE_INSTALL} -u\" is ${status} >>${LOG}
  fi

  DOLOG=Y
fi

#echo NOSECOND=${NOSECOND} LOG=${LOG} >>${LOG}
if test -z "${NOSECOND}"
then
   if test -x ${MAIN_INSTALL}
   then
      ${MAIN_INSTALL} -2 2>&1 | tee -a ${LOG} >/dev/null
      DOLOG=Y
   fi
fi

if test -x ${HOME}/tune_power.sh
then
  if test "${DOLOG}" = "Y"
  then
     ${HOME}/tune_power.sh 2>&1 | tee -a ${LOG} >/dev/null
  else
     ${HOME}/tune_power.sh
  fi
fi
EOF

chmod +x /usr/local/rtkbase/setup_2nd_stage.sh

hostname raspberrypi
rm -f /usr/local/rtkbase/version.txt
rm -f /usr/local/rtkbase/rtkbase/settings.conf
/usr/local/rtkbase/install.sh -1 2>&1

apt clean

systemctl enable rtkbase_setup.service
