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
export HOME

if test -f /boot/firmware/install.sh
then
  mv /boot/firmware/install.sh ${HOME}/update 2>&1 | tee -a ${HOME}/install.log >/dev/null
  LOG=Y
fi

if test -f ${HOME}/update/install.sh
then
  chmod +x ${HOME}/update/install.sh 2>&1 | tee -a ${HOME}/install.log >/dev/null
  LOG=Y
fi

if test -x ${HOME}/update/install.sh
then

  nm-online -s 2>&1 | tee -a ${HOME}/install.log >/dev/null
  nm-online 2>&1 | tee -a ${HOME}/install.log >/dev/null
  for i in `seq 1 10`
  do
     if sudo ntpdate -b -t 5 pool.ntp.org 2>&1 | tee -a ${HOME}/install.log >/dev/null
     then
        break
     fi
     sleep 3
  done

  if test -x ${HOME}/install.sh
  then
     ${HOME}/update/install.sh -1 2>&1 | tee -a ${HOME}/install.log >/dev/null
     status=$?
     echo status of \"${HOME}/update/install.sh -1\" is ${status} >>${HOME}/install.log
     if test "${status}" = "0"
     then
        mv ${HOME}/update/install.sh ${HOME}/install.sh 2>&1 | tee -a ${HOME}/install.log >/dev/null
     else
        NOSECOND=Y
     fi
  else
     ${HOME}/update/install.sh -u >>${HOME}/install.log 2>&1
     status=$?
     echo status of \"${HOME}/update/install.sh -u\" is ${status} >>${HOME}/install.log
  fi

  LOG=Y
fi

#echo NOSECOND=${NOSECOND} LOG=${LOG} >>${HOME}/install.log
if test -z "${NOSECOND}"
then
   if test -x ${HOME}/install.sh
   then
      ${HOME}/install.sh -2 2>&1 | tee -a ${HOME}/install.log >/dev/null
      LOG=Y
   fi
fi

if test -x ${HOME}/tune_power.sh
then
  if test "${LOG}" = "Y"
  then
     ${HOME}/tune_power.sh 2>&1 | tee -a ${HOME}/install.log >/dev/null
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
