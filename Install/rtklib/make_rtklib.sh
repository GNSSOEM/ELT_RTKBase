#!/bin/bash

BASEDIR=`realpath $(dirname $(readlink -f "$0"))`
ORIGDIR=`pwd`

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

if [[ ${1} == "" ]]
then
   echo Usage: ${0} \<RTKLIB Git Directory\>
   exit 0
fi


cd ${BASEDIR}/$1/app/consapp/str2str/gcc
ExitCodeCheck $?
make -s clean all
ExitCodeCheck $?
sudo cp str2str ${BASEDIR}
ExitCodeCheck $?
cd ${BASEDIR}/$1/app/consapp/rtkrcv/gcc
ExitCodeCheck $?
make -s clean all
ExitCodeCheck $?
sudo cp rtkrcv ${BASEDIR}
ExitCodeCheck $?
cd ${BASEDIR}/$1/app/consapp/convbin/gcc
ExitCodeCheck $?
make -s clean all
ExitCodeCheck $?
sudo cp convbin ${BASEDIR}
ExitCodeCheck $?

cd ${ORIGDIR}
ExitCodeCheck $?

echo exit ${exitcode}
exit $exitcode

