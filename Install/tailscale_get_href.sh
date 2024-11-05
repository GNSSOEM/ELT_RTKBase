#!/bin/bash
#
# Logged out.
#
# Logged out. Log in at: https://login.tailscale.com/a/1518c60101f04c
#
# 100.67.209.61   rtkbase4-1           jef239@      linux   -
#
# Tailscale is stopped.
#

lastcode=N
exitcode=0

ExitCodeCheck(){
  lastcode=$1
  if [[ $lastcode > $exitcode ]]
  then
     exitcode=${lastcode}
     #echo exitcode=${exitcode}
  fi
}

link="https://login.tailscale.com/welcome"
status=`tailscale status`
#ExitCodeCheck $? # Down and logout exitstatus is 1
#echo status=${status} exitstatus=$?
if [[ "${status}" =~ "Logged out." ]]; then
   #echo sudo tailscale login --timeout=1s \>/dev/null 2\>\&1
   sudo tailscale login --timeout=1s >/dev/null 2>&1
   #ExitCodeCheck $? # exitstatus is 1
   status=`tailscale status`
   #ExitCodeCheck $? # Down and logout exitstatus is 1
   #echo status=${status} exitstatus=$?
   have_https=`echo ${status} | grep https`
   ExitCodeCheck $?
   #echo have_https=${have_https}
   if [[ "${have_https}" != "" ]]; then
      #echo echo ${status} \| sed s/^.*https/https/
      link=`echo ${status} | sed s/^.*https/https/`
      ExitCodeCheck $?
   fi
elif [[ "${status}" =~ "Tailscale is stopped." ]]; then
   #echo sudo tailscale up \>/dev/null 2\>\&1
   sudo tailscale up >/dev/null 2>&1
   ExitCodeCheck $?
fi

echo ${link}
#echo exitcode=${exitcode}
exit ${exitcode}


